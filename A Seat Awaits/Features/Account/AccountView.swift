//
//  AccountView.swift
//  A Seat Awaits
//
//  The Account tab entry point. Wires the authenticated `SupabaseClient` and
//  `AppState` into an `AccountStore` and presents the native Manage Account
//  experience (`ManageAccountView`). All account functionality runs through the
//  authenticated Supabase client (Auth + PostgREST, RLS-enforced) — never a
//  Nuxt/web API — and ships no server secrets.
//

import SwiftUI

struct AccountView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let supabase = appState.supabase {
            ManageAccountView(supabase: supabase, appState: appState)
        } else {
            ConfigErrorView(message: "Supabase client unavailable.")
        }
    }
}
