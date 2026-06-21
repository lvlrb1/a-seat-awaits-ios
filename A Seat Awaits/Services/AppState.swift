//
//  AppState.swift
//  A Seat Awaits
//
//  Top-level app state: owns the Supabase client and tracks the auth phase that
//  drives the root navigation (onboarding vs. the main app).
//

import Foundation
import Observation

@MainActor
@Observable
final class AppState {

    enum Phase: Equatable {
        case launching
        case misconfigured(String)
        case signedOut
        case signedIn(AuthUser)
    }

    private(set) var phase: Phase = .launching

    /// The Supabase client, available once configuration loads successfully.
    private(set) var supabase: SupabaseClient?

    /// Public origin for guest-facing links (e.g. the event QR code's
    /// `/r/{token}` URL). Set from config; falls back to the production origin.
    private(set) var publicSiteURL = AppConfig.defaultPublicSiteURL

    var currentUser: AuthUser? {
        if case .signedIn(let user) = phase { return user }
        return nil
    }

    var currentUserId: String? { currentUser?.id }

    // MARK: - Deep links

    /// A pending `/invite/{token}` awaiting handling (e.g. accept-after-sign-in).
    var pendingInviteToken: String?
    /// Drives presentation of the password-reset sheet after a recovery link.
    var isPresentingPasswordReset = false

    /// Routes an incoming universal/custom-scheme URL. Tokens are never logged.
    func handleDeepLink(_ url: URL) async {
        switch DeepLinkRouter.parse(url) {
        case .inviteToken(let token):
            pendingInviteToken = token
        case .recovery(let accessToken, let refreshToken):
            guard let supabase else { return }
            if let user = try? await supabase.applyRecoverySession(accessToken: accessToken,
                                                                   refreshToken: refreshToken) {
                phase = .signedIn(user)
                isPresentingPasswordReset = true
            }
        case .emailConfirmed(let accessToken, let refreshToken):
            guard let supabase else { return }
            if let user = try? await supabase.applyRecoverySession(accessToken: accessToken,
                                                                   refreshToken: refreshToken) {
                phase = .signedIn(user)
            }
        case .unhandled:
            break
        }
    }

    init() {
        do {
            let config = try AppConfig.load()
            supabase = SupabaseClient(config: config)
            publicSiteURL = config.publicSiteURL
        } catch {
            phase = .misconfigured(error.localizedDescription)
        }
    }

    /// Restores any persisted session on launch.
    func bootstrap() async {
        guard let supabase else { return }
        if let user = await supabase.restoreSession() {
            phase = .signedIn(user)
        } else {
            phase = .signedOut
        }
    }

    func didAuthenticate(_ user: AuthUser) {
        phase = .signedIn(user)
    }

    func signOut() async {
        await supabase?.signOut()
        phase = .signedOut
    }

    /// Revokes every session for the user (sign out everywhere) and clears local
    /// state. The Supabase client clears the Keychain as part of `signOut`.
    func signOutEverywhere() async {
        await supabase?.signOut(scope: .global)
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
