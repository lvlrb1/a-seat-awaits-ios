//
//  MainTabView.swift
//  A Seat Awaits
//
//  The signed-in shell: Events, the guest-facing Find Your Table lookup, and
//  Account — a native iOS tab bar per the design.
//

import SwiftUI

struct MainTabView: View {
    let supabase: SupabaseClient

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TabView {
            Tab("Events", systemImage: "calendar") {
                EventListView(supabase: supabase)
            }
            Tab("Find Table", systemImage: "magnifyingglass") {
                FindYourTableView(supabase: supabase)
            }
            Tab("Account", systemImage: "person.crop.circle") {
                AccountView()
            }
        }
        // Lavender carries the brand into dark mode; plum in light.
        // The bar itself stays native/translucent material.
        .tint(scheme == .dark ? Brand.lilac : Brand.plum)
    }
}
