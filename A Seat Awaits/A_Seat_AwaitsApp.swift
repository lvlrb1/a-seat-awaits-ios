//
//  A_Seat_AwaitsApp.swift
//  A Seat Awaits
//
//  Created by Brice Foster on 6/19/26.
//

import SwiftUI

@main
struct A_Seat_AwaitsApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .tint(Brand.plum)
                // Dynamic Type: every label scales via `scaledFont`; the
                // layouts are tuned up to the first accessibility size.
                .dynamicTypeSize(...DynamicTypeSize.appMaximum)
                .task { await appState.bootstrap() }
                // Custom scheme (`aseatawaits://`) and universal links while
                // the app is running.
                .onOpenURL { url in
                    Task { await appState.handleDeepLink(url) }
                }
                // Universal links delivered as a browsing activity (a cold
                // launch from Safari/Mail hands the URL over this way).
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    Task { await appState.handleDeepLink(url) }
                }
        }
    }
}
