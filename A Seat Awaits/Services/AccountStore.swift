//
//  AccountStore.swift
//  A Seat Awaits
//
//  Owns all data access and mutation for the native Manage Account experience.
//  Everything flows through the authenticated `SupabaseClient` (GoTrue Auth +
//  PostgREST, RLS-enforced) — no Nuxt/web API, no service-role key, no Stripe
//  secret. Privileged operations that can't run with a user JWT (Stripe billing,
//  deleting `auth.users`) are not performed here; the views open a secure
//  external page for those.
//
//  SwiftUI screens call these async methods and render `snapshot`; no database,
//  auth, aggregation or mutation logic lives in view bodies.
//

import Foundation
import Observation

/// PATCH body for `public.users.full_name`. `nonisolated` so its `Encodable`
/// conformance can cross into the Supabase `actor` (the project defaults types
/// to `MainActor` isolation).
private nonisolated struct FullNamePatch: Encodable, Sendable { let full_name: String }

@MainActor
@Observable
final class AccountStore {

    private let supabase: SupabaseClient
    private let appState: AppState

    /// The aggregated account state the screens render. Nil until first load.
    private(set) var snapshot: AccountSnapshot?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// A non-fatal load error (the screen still shows whatever session info exists).
    var loadErrorMessage: String?

    // In-flight guards so a double-tap can't submit twice.
    private(set) var isSavingName = false
    private(set) var isChangingEmail = false
    private(set) var isChangingPassword = false
    private(set) var isExporting = false

    init(supabase: SupabaseClient, appState: AppState) {
        self.supabase = supabase
        self.appState = appState
    }

    var userId: String? { appState.currentUserId }

    // MARK: - Load

    /// Loads the authenticated user, profile and subscription. Existing content
    /// is preserved while reloading so a refresh never flashes empty.
    func load() async {
        isLoading = true
        loadErrorMessage = nil
        defer { isLoading = false; hasLoaded = true }

        // The auth user is the backbone of the screen; without it we can't render.
        let authUser: AuthUser
        do {
            authUser = try await supabase.fetchCurrentUser()
        } catch {
            // Fall back to the cached session user so the screen isn't empty,
            // but surface that fresh details couldn't load.
            if let cached = appState.currentUser {
                authUser = cached
                loadErrorMessage = Self.message(for: error)
            } else {
                loadErrorMessage = Self.message(for: error)
                return
            }
        }

        async let profileTask = fetchProfile(userId: authUser.id)
        async let subscriptionTask = fetchSubscription(userId: authUser.id)
        async let passesTask = fetchPasses(userId: authUser.id)
        let (profile, subscription, passes) = await (profileTask, subscriptionTask, passesTask)

        snapshot = AccountSnapshot(authUser: authUser,
                                   profile: profile,
                                   subscription: subscription,
                                   passes: passes)
    }

    /// A lightweight refresh used when returning to the foreground: re-reads the
    /// subscription, profile and passes (the most likely to have changed after a
    /// billing action) without disrupting the screen on failure.
    func refreshBillingState() async {
        guard let authUser = snapshot?.authUser ?? appState.currentUser else { return }
        async let profileTask = fetchProfile(userId: authUser.id)
        async let subscriptionTask = fetchSubscription(userId: authUser.id)
        async let passesTask = fetchPasses(userId: authUser.id)
        let (profile, subscription, passes) = await (profileTask, subscriptionTask, passesTask)
        if var current = snapshot {
            if let profile { current.profile = profile }
            current.subscription = subscription
            current.passes = passes
            snapshot = current
        }
    }

    private func fetchProfile(userId: String) async -> UserProfile? {
        do {
            let rows = try await supabase.select(
                "users",
                query: [
                    URLQueryItem(name: "select",
                                 value: "id,full_name,subscription_tier,subscription_status,legacy_free,created_at,updated_at"),
                    URLQueryItem(name: "id", value: "eq.\(userId)"),
                ],
                as: [UserProfile].self)
            return rows.first
        } catch {
            loadErrorMessage = loadErrorMessage ?? Self.message(for: error)
            return nil
        }
    }

    /// The user's Event Passes (RLS scopes rows to the purchaser), newest first.
    private func fetchPasses(userId: String) async -> [EventPass] {
        do {
            return try await supabase.select(
                "event_passes",
                query: [
                    URLQueryItem(name: "select", value: EventPass.selectColumns),
                    URLQueryItem(name: "user_id", value: "eq.\(userId)"),
                    URLQueryItem(name: "order", value: "purchased_at.desc.nullslast"),
                ],
                as: [EventPass].self)
        } catch {
            // A user with no passes (or an older backend) is not an error.
            return []
        }
    }

    private func fetchSubscription(userId: String) async -> SubscriptionRow? {
        do {
            let rows = try await supabase.select(
                "subscriptions",
                query: [
                    URLQueryItem(name: "select", value: SubscriptionRow.selectColumns),
                    URLQueryItem(name: "user_id", value: "eq.\(userId)"),
                    URLQueryItem(name: "order", value: "created_at.desc.nullslast"),
                    URLQueryItem(name: "limit", value: "1"),
                ],
                as: [SubscriptionRow].self)
            return rows.first
        } catch {
            // Free users have no subscription row; treat as non-fatal.
            return nil
        }
    }

    // MARK: - Edit full name

    /// Updates the user's full name in `public.users` and Auth metadata, then
    /// pushes the change into `AppState`. Applies local state only after success;
    /// if the Auth metadata update fails after the profile row was written, the
    /// row is reverted so the two never diverge.
    func updateFullName(_ raw: String) async -> Result<Void, Error> {
        switch AccountValidation.validateName(raw) {
        case .failure(let error): return .failure(error)
        case .success(let name):
            guard !isSavingName, let userId else { return .failure(SupabaseError.notAuthenticated) }
            isSavingName = true
            defer { isSavingName = false }

            let previousName = snapshot?.profile?.fullName

            do {
                // 1. Canonical name in public.users.
                _ = try await supabase.update(
                    "users",
                    values: FullNamePatch(full_name: name),
                    query: [URLQueryItem(name: "id", value: "eq.\(userId)")],
                    returning: [UserProfile].self)

                // 2. Auth metadata, so AppState.displayName stays in sync.
                let updatedUser: AuthUser
                do {
                    updatedUser = try await supabase.updateAuthUser(fullName: name)
                } catch {
                    // Revert the profile row (best effort) to avoid divergence.
                    _ = try? await supabase.update(
                        "users",
                        values: FullNamePatch(full_name: previousName ?? ""),
                        query: [URLQueryItem(name: "id", value: "eq.\(userId)")],
                        returning: [UserProfile].self)
                    throw error
                }

                // 3. Apply locally + propagate to the rest of the app.
                applyLocalName(name, authUser: updatedUser)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
    }

    private func applyLocalName(_ name: String, authUser: AuthUser) {
        if var current = snapshot {
            current.profile?.fullName = name
            current.authUser = authUser
            snapshot = current
        }
        appState.updateSignedInUser(authUser)
    }

    // MARK: - Change email

    /// Requests an email change through GoTrue. The new address is NOT treated as
    /// canonical: Supabase keeps the old email until the user confirms the new
    /// one, and the returned user exposes the pending address as `new_email`.
    func changeEmail(_ raw: String) async -> Result<EmailChangeOutcome, Error> {
        switch AccountValidation.validateEmail(raw, current: snapshot?.email) {
        case .failure(let error): return .failure(error)
        case .success(let email):
            guard !isChangingEmail else { return .failure(SupabaseError.notAuthenticated) }
            isChangingEmail = true
            defer { isChangingEmail = false }
            do {
                let updated = try await supabase.updateAuthUser(email: email)
                if var current = snapshot {
                    current.authUser = updated
                    snapshot = current
                }
                appState.updateSignedInUser(updated)
                // Confirmation pending unless the server already swapped the email.
                let confirmed = updated.email?.lowercased() == email
                return .success(confirmed ? .changed : .confirmationRequired(email))
            } catch {
                return .failure(EmailChangeError.map(error))
            }
        }
    }

    enum EmailChangeOutcome: Equatable {
        case changed
        case confirmationRequired(String)
    }

    // MARK: - Change password

    /// Reauthenticates with the current password, then updates to the new one.
    /// Performs no local logging or persistence of any password.
    func changePassword(current: String, new: String, confirm: String) async -> Result<Void, Error> {
        switch AccountValidation.validatePassword(current: current, new: new, confirm: confirm) {
        case .failure(let error): return .failure(error)
        case .success:
            guard let email = snapshot?.email ?? appState.currentUser?.email else {
                return .failure(PasswordChangeError.noEmail)
            }
            guard !isChangingPassword else { return .failure(SupabaseError.notAuthenticated) }
            isChangingPassword = true
            defer { isChangingPassword = false }
            do {
                try await supabase.reauthenticate(email: email, password: current)
            } catch {
                return .failure(PasswordChangeError.incorrectCurrent)
            }
            do {
                _ = try await supabase.updateAuthUser(password: new)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
    }

    /// Sends a password-reset email (the existing recovery flow).
    func sendPasswordReset() async -> Result<Void, Error> {
        guard let email = snapshot?.email ?? appState.currentUser?.email else {
            return .failure(PasswordChangeError.noEmail)
        }
        do {
            try await supabase.sendPasswordReset(email: email)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Personal-data export

    /// Assembles the versioned JSON export locally and returns the file plus any
    /// partial-failure report. Prevents duplicate concurrent exports.
    func exportPersonalData() async -> Result<DataExportResult, Error> {
        guard let snapshot else { return .failure(SupabaseError.notAuthenticated) }
        guard !isExporting else { return .failure(SupabaseError.notAuthenticated) }
        isExporting = true
        defer { isExporting = false }
        let exporter = AccountDataExporter(supabase: supabase,
                                           authUser: snapshot.authUser,
                                           profile: snapshot.profile,
                                           subscription: snapshot.subscription)
        do { return .success(try await exporter.run(now: Date())) }
        catch { return .failure(error) }
    }

    // MARK: - Guest-list export

    /// The signed-in user's owned events, for the guest-list export picker.
    func fetchOwnedEvents() async throws -> [Event] {
        guard let userId else { throw SupabaseError.notAuthenticated }
        return try await supabase.select(
            "events",
            query: [
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "owner_id", value: "eq.\(userId)"),
                URLQueryItem(name: "order", value: "created_at.desc.nullslast"),
            ],
            as: [Event].self)
    }

    /// Exports one event's guest list as CSV for the share sheet.
    func exportGuestList(for event: Event) async -> Result<URL, Error> {
        let exporter = GuestListExporter(supabase: supabase)
        do { return .success(try await exporter.run(event: event, now: Date())) }
        catch { return .failure(error) }
    }

    // MARK: - Errors

    enum PasswordChangeError: LocalizedError {
        case incorrectCurrent
        case noEmail
        var errorDescription: String? {
            switch self {
            case .incorrectCurrent: return "Your current password is incorrect."
            case .noEmail: return "This account doesn't have a password to change."
            }
        }
    }

    enum EmailChangeError {
        /// Maps GoTrue errors to friendly, actionable messages.
        static func map(_ error: Error) -> Error {
            guard let supa = error as? SupabaseError else { return error }
            if case .http(let status, let message) = supa {
                let lower = message.lowercased()
                if lower.contains("already") || lower.contains("exists") || status == 422 {
                    return Friendly("That email address is already in use by another account.")
                }
                if status == 401 {
                    return Friendly("Your session has expired. Please sign in again to change your email.")
                }
            }
            return error
        }
    }

    /// A simple wrapper to surface a friendly message through `LocalizedError`.
    struct Friendly: LocalizedError { let message: String; init(_ m: String) { message = m }
        var errorDescription: String? { message } }

    /// Maps a thrown error to a user-facing message.
    static func message(for error: Error) -> String {
        if let supa = error as? SupabaseError {
            switch supa {
            case .notAuthenticated:
                return "You're signed out. Please sign in again."
            case .http(let status, let message):
                switch status {
                case 401: return "You're signed out. Please sign in again."
                case 403: return "You don't have permission to do that."
                default: return message.isEmpty ? "Something went wrong (HTTP \(status))." : message
                }
            case .transport:
                return "Network problem. Check your connection and try again."
            case .offline:
                return "You're offline. Check your connection and try again."
            case .decoding(let m):
                return "Couldn't read the server response. \(m)"
            case .notConfigured(let m):
                return m
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
