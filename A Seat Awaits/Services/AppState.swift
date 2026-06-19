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

    var currentUser: AuthUser? {
        if case .signedIn(let user) = phase { return user }
        return nil
    }

    init() {
        do {
            let config = try AppConfig.load()
            supabase = SupabaseClient(config: config)
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
}
