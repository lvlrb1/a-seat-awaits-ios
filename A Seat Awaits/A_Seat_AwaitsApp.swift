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
                .task { await appState.bootstrap() }
                .onOpenURL { url in
                    Task { await appState.handleDeepLink(url) }
                }
        }
    }
}
