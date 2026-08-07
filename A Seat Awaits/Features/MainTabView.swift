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

    var body: some View {
        TabView {
            Tab("Events", systemImage: "calendar") {
                EventListView(supabase: supabase)
                    .tint(Brand.accent)
            }
            Tab("Find Table", systemImage: "magnifyingglass") {
                FindYourTableView(supabase: supabase)
                    .tint(Brand.accent)
            }
            Tab("Account", systemImage: "person.crop.circle") {
                AccountView()
                    .tint(Brand.accent)
            }
        }
        // Tab-bar tint. The floating glass bar renders the selected label in
        // this exact color on every screen — it does not adapt it to the
        // backdrop — so it must survive both the plum hero (dark glass, where
        // vibrancy washes out dark colors: plum turned invisible) and light
        // screens (light pill, where lilac turned invisible). Saturated violet
        // is the one brand color that reads on both. Content inside each tab
        // keeps the usual plum/lilac accent via the inner .tint above.
        .tint(Brand.purple)
    }
}
