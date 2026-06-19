//
//  ContentView.swift
//  A Seat Awaits
//
//  RootView switches between onboarding and the main app based on the auth
//  phase. (File kept as ContentView.swift to preserve the original target file.)
//

import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.phase {
        case .launching:
            LaunchView()
        case .misconfigured(let message):
            ConfigErrorView(message: message)
        case .signedOut:
            OnboardingView()
        case .signedIn:
            if let supabase = appState.supabase {
                MainTabView(supabase: supabase)
            } else {
                ConfigErrorView(message: "Supabase client unavailable.")
            }
        }
    }
}

/// Branded splash shown while the persisted session is restored.
struct LaunchView: View {
    var body: some View {
        ZStack {
            Brand.heroGradient.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "chair.lounge.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white)
                ProgressView()
                    .tint(.white)
            }
        }
    }
}

/// Shown when Secrets.plist is missing or invalid, with actionable guidance.
struct ConfigErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(Brand.warning)
            Text("Configuration needed")
                .font(.title2.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Copy Secrets.example.plist to Secrets.plist and fill in your Supabase URL and anon key.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.canvas.ignoresSafeArea())
    }
}

#Preview {
    LaunchView()
}
