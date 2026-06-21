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
        @Bindable var appState = appState
        Group {
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
        // Password-recovery deep link: present the new-password sheet over the app.
        .sheet(isPresented: $appState.isPresentingPasswordReset) {
            if let supabase = appState.supabase {
                ResetPasswordView(supabase: supabase) {
                    appState.isPresentingPasswordReset = false
                }
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
                // Brand chair mark (matches onboarding & lookup), not a generic
                // SF Symbol, for a consistent first impression (F13).
                Image("BrandChair")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
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
