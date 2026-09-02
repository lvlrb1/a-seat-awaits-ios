//
//  AppState.swift
//  A Seat Awaits
//
//  Top-level app state: owns the Supabase client and tracks the auth phase that
//  drives the root navigation (onboarding vs. the main app). Also the single
//  home for cross-screen concerns: deep links (which wait for bootstrap), the
//  pending invitation token, a dead-session signal from the client, and the
//  root-level notice alert that surfaces all of the above.
//

import Foundation
import Observation

/// A short, root-level alert (title + message) shown over whatever screen is up.
nonisolated struct AppNotice: Equatable, Sendable {
    let title: String
    let message: String
}

@MainActor
@Observable
final class AppState {

    enum Phase: Equatable {
        case launching
        case misconfigured(String)
        case signedOut
        case signedIn(AuthUser)
    }

    private(set) var phase: Phase = .launching {
        didSet {
            // Every path into the signed-in state (fresh sign-in, restored
            // session, recovery/confirmation deep links, profile edits) flows
            // through here, so analytics identity stays in sync in one place.
            if case .signedIn(let user) = phase {
                Analytics.identify(user)
            }
        }
    }

    /// The Supabase client, available once configuration loads successfully.
    private(set) var supabase: SupabaseClient?

    /// StoreKit purchases + App Store entitlement sync. Created with the client;
    /// its transaction listener is started in `bootstrap()`.
    private(set) var subscriptionStore: SubscriptionStore?

    /// Public origin for guest-facing links (e.g. the event QR code's
    /// `/r/{token}` URL). Set from config; falls back to the production origin.
    private(set) var publicSiteURL = AppConfig.defaultPublicSiteURL

    var currentUser: AuthUser? {
        if case .signedIn(let user) = phase { return user }
        return nil
    }

    var currentUserId: String? { currentUser?.id }

    // MARK: - Root-level notices

    /// A message the root view renders as an alert: an expired deep link, a
    /// forced sign-out, an accepted invitation. Set to nil on dismiss.
    var notice: AppNotice?

    /// Bumped whenever something outside the dashboard changed the event list
    /// (an invitation accepted from a deep link), so the dashboard reloads.
    private(set) var eventsRefreshGeneration = 0

    /// True when the sign-up/sign-in call to `provision-sample-event` failed.
    /// The dashboard retries once on its first empty load, so a network blip at
    /// sign-up can't send a brand-new user straight into the paywall.
    var needsSampleEventRetry = false

    // MARK: - Deep links

    /// A pending `/invite/{token}` awaiting handling (e.g. accept-after-sign-in).
    var pendingInviteToken: String?
    /// Drives presentation of the password-reset sheet after a recovery link.
    var isPresentingPasswordReset = false

    private var isBootstrapped = false
    private var bootstrapWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var sessionEventsTask: Task<Void, Never>?

    /// Routes an incoming universal/custom-scheme URL. Tokens are never logged.
    /// Waits for `bootstrap()` to settle the auth phase first, so a link that
    /// launches the app is handled against the restored session rather than
    /// racing it.
    func handleDeepLink(_ url: URL) async {
        let link = DeepLinkRouter.parse(url)
        guard link != .unhandled else { return }
        await waitForBootstrap()

        switch link {
        case .inviteToken(let token):
            pendingInviteToken = token
            // Signed in: accept now. Signed out: held until `didAuthenticate`.
            await acceptPendingInviteIfSignedIn()

        case .recovery(let accessToken, let refreshToken):
            guard let supabase else { return }
            do {
                let user = try await supabase.applyRecoverySession(accessToken: accessToken,
                                                                   refreshToken: refreshToken)
                phase = .signedIn(user)
                isPresentingPasswordReset = true
            } catch {
                guard !FriendlyError.isCancellation(error) else { return }
                notice = Self.linkFailureNotice(for: error,
                                                expired: "This link has expired. Request a new one from the sign-in screen.")
            }

        case .emailConfirmed(let accessToken, let refreshToken):
            guard let supabase else { return }
            do {
                let user = try await supabase.applyRecoverySession(accessToken: accessToken,
                                                                   refreshToken: refreshToken)
                phase = .signedIn(user)
            } catch {
                guard !FriendlyError.isCancellation(error) else { return }
                notice = Self.linkFailureNotice(for: error,
                                                expired: "This confirmation link has expired or was already used. Sign in to continue.")
            }

        case .unhandled:
            break
        }
    }

    /// Offline gets the offline line; anything else means the tokens were
    /// rejected, which from the user's side is simply an expired link.
    private static func linkFailureNotice(for error: Error, expired: String) -> AppNotice {
        if FriendlyError.isOffline(error) {
            return AppNotice(title: "You're offline", message: FriendlyError.message(for: error))
        }
        return AppNotice(title: "Link expired", message: expired)
    }

    // MARK: - Pending invitation

    /// Accepts a held `/invite/{token}` via the `accept_event_invitation` RPC
    /// once a user is signed in. The token is consumed either way (a rejected
    /// token is never retried); the dashboard is asked to reload so the shared
    /// event (or, on failure, the still-pending invite card) appears.
    func acceptPendingInviteIfSignedIn() async {
        guard case .signedIn = phase, let token = pendingInviteToken, let supabase else { return }
        pendingInviteToken = nil
        do {
            _ = try await supabase.rpc("accept_event_invitation",
                                       params: AcceptInviteParams(p_token: token),
                                       as: String.self)
            notice = AppNotice(title: "Invitation accepted",
                               message: "The shared event is now in your Events list.")
        } catch {
            if FriendlyError.isCancellation(error) {
                pendingInviteToken = token
                return
            }
            if FriendlyError.isOffline(error) {
                pendingInviteToken = token
                notice = AppNotice(title: "You're offline",
                                   message: "We'll accept the invitation once you're back online. Reopen the link if it doesn't appear.")
                return
            }
            notice = AppNotice(title: "Invitation not accepted",
                               message: "We couldn't accept that invitation. It may have expired or been sent to a different email address. Any pending invitations appear at the top of your Events list.")
        }
        eventsRefreshGeneration += 1
    }

    // MARK: - Lifecycle

    init() {
        Analytics.configure()
        do {
            let config = try AppConfig.load()
            let client = SupabaseClient(config: config)
            supabase = client
            subscriptionStore = SubscriptionStore(supabase: client, appState: self)
            publicSiteURL = config.publicSiteURL
        } catch {
            phase = .misconfigured(error.localizedDescription)
        }
    }

    /// Restores any persisted session on launch, then releases anything
    /// (deep links) waiting on the auth phase.
    func bootstrap() async {
        guard !isBootstrapped else { return }
        defer { finishBootstrap() }
        guard let supabase else { return }
        subscribeToSessionEvents(supabase)
        if let user = await supabase.restoreSession() {
            phase = .signedIn(user)
        } else {
            phase = .signedOut
        }
        subscriptionStore?.start()
    }

    private func finishBootstrap() {
        isBootstrapped = true
        let waiters = bootstrapWaiters
        bootstrapWaiters = []
        for waiter in waiters { waiter.resume() }
        if case .signedIn = phase, pendingInviteToken != nil {
            Task { await acceptPendingInviteIfSignedIn() }
        }
    }

    private func waitForBootstrap() async {
        guard !isBootstrapped else { return }
        await withCheckedContinuation { continuation in
            bootstrapWaiters.append(continuation)
        }
    }

    /// Listens for the client discovering a dead refresh token mid-session and
    /// flips the app to signed-out with a friendly explanation.
    private func subscribeToSessionEvents(_ supabase: SupabaseClient) {
        sessionEventsTask?.cancel()
        sessionEventsTask = Task { [weak self] in
            let stream = await supabase.sessionEvents()
            for await event in stream {
                guard let self else { return }
                self.handleSessionEvent(event)
            }
        }
    }

    private func handleSessionEvent(_ event: SupabaseSessionEvent) {
        switch event {
        case .sessionInvalidated:
            guard case .signedIn = phase else { return }
            Analytics.reset()
            isPresentingPasswordReset = false
            phase = .signedOut
            notice = AppNotice(title: "Signed out",
                               message: "You've been signed out. Please sign in again.")
        }
    }

    /// Called when a sign-in or sign-up completes. `sampleEventProvisioned` is
    /// false when the sample-event call failed; the dashboard then retries once.
    func didAuthenticate(_ user: AuthUser, sampleEventProvisioned: Bool = true) {
        needsSampleEventRetry = !sampleEventProvisioned
        phase = .signedIn(user)
        if pendingInviteToken != nil {
            Task { await acceptPendingInviteIfSignedIn() }
        }
    }

    func signOut() async {
        await supabase?.signOut()
        Analytics.reset()
        pendingInviteToken = nil
        phase = .signedOut
    }

    /// Finishes a successful server-side account deletion locally. The auth
    /// user no longer exists, so clear the Keychain directly instead of issuing
    /// a logout request with a token the server has already invalidated.
    func didDeleteAccount() async {
        await supabase?.clearDeletedAccountSession()
        Analytics.reset()
        pendingInviteToken = nil
        phase = .signedOut
    }

    /// Revokes every session for the user (sign out everywhere) and clears local
    /// state. The Supabase client clears the Keychain as part of `signOut`.
    func signOutEverywhere() async {
        await supabase?.signOut(scope: .global)
        pendingInviteToken = nil
        phase = .signedOut
    }

    /// Replaces the signed-in user when account details change (e.g. an edited
    /// full name or a confirmed email), so every screen reflects it at once.
    /// No-op unless currently signed in.
    func updateSignedInUser(_ user: AuthUser) {
        if case .signedIn = phase {
            phase = .signedIn(user)
        }
    }
}
