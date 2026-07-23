//
//  Analytics.swift
//  A Seat Awaits
//
//  Thin wrapper around the PostHog SDK so call sites never touch PostHogSDK
//  directly. The API key is PostHog's *public* project key (safe to ship in the
//  binary — it can only ingest events, never read them), so it lives here
//  rather than in the Secrets plists. Debug builds tag every event with
//  environment=development so dev/TestFlight noise is filterable in PostHog.
//

import Foundation
import PostHog

enum Analytics {

    private static let apiKey = "phc_usrCXybjuGFzXpTP32xTMSoroAFv5ehxNmrt5m5UobjA"
    /// PostHog US Cloud ingestion host. Change to https://eu.i.posthog.com if
    /// the PostHog project ever moves to the EU region.
    private static let host = "https://us.i.posthog.com"

    #if DEBUG
    private static let environment = "development"
    #else
    private static let environment = "production"
    #endif

    /// Sets up the SDK. Call once, before any capture/identify.
    static func configure() {
        // The unit-test target launches the real app as its host; don't send
        // analytics from test runs. Without setup, later identify/capture
        // calls are no-ops.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let config = PostHogConfig(apiKey: apiKey, host: host)
        // "Application Opened" / "Application Backgrounded" etc. for free.
        config.captureApplicationLifecycleEvents = true
        PostHogSDK.shared.setup(config)
        // Stamped on every event so dev builds are filterable.
        PostHogSDK.shared.register(["environment": environment])
    }

    /// Ties events to the signed-in account. Safe to call repeatedly with the
    /// same user (e.g. on session restore or profile edits).
    static func identify(_ user: AuthUser) {
        var properties: [String: Any] = [:]
        if let email = user.email { properties["email"] = email }
        if let name = user.userMetadata?.fullName { properties["name"] = name }
        PostHogSDK.shared.identify(user.id, userProperties: properties)
    }

    /// Clears the identified user on sign-out so the next session starts anonymous.
    static func reset() {
        PostHogSDK.shared.reset()
    }

    /// Captures a custom event, e.g. `Analytics.capture("event_created")`.
    static func capture(_ event: String, properties: [String: Any]? = nil) {
        PostHogSDK.shared.capture(event, properties: properties)
    }
}
