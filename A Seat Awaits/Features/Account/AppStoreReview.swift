//
//  AppStoreReview.swift
//  A Seat Awaits
//
//  App Store identity plus the once-per-version gate around the system rating
//  prompt. The prompt is only ever requested after a genuine success (a guest
//  import commits, a floor plan is exported), never on launch or after an
//  error, and at most once per app version.
//

import Foundation
import StoreKit
import SwiftUI

/// App Store Connect identifiers for this app.
nonisolated enum AppStoreIDs {
    /// The numeric Apple ID of the app (App Store Connect → App Information →
    /// Apple ID). Must be filled in from App Store Connect before the passive
    /// "Rate A Seat Awaits" row appears; the row stays hidden while empty.
    static let appleID = ""

    /// Deep link that opens the App Store review composer, or nil until
    /// `appleID` is filled in.
    static var writeReviewURL: URL? {
        guard !appleID.isEmpty else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(appleID)?action=write-review")
    }
}

/// Decides whether the system rating prompt may be shown, and records that it
/// was. Pure logic is `nonisolated` so it's unit-testable without UI.
nonisolated enum ReviewPromptGate {
    static let storageKey = "review.lastPromptedVersion"

    /// True when the prompt has not yet been shown for `currentVersion`.
    static func shouldPrompt(lastPromptedVersion: String?, currentVersion: String) -> Bool {
        guard !currentVersion.isEmpty else { return false }
        return lastPromptedVersion != currentVersion
    }

    /// The marketing version string (`CFBundleShortVersionString`).
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Requests the system rating prompt if it hasn't been requested for this
    /// app version, and marks the version as prompted. StoreKit itself decides
    /// whether the sheet actually appears.
    @MainActor
    static func requestIfEligible(_ requestReview: RequestReviewAction,
                                  defaults: UserDefaults = .standard) {
        let version = currentVersion
        guard shouldPrompt(lastPromptedVersion: defaults.string(forKey: storageKey),
                           currentVersion: version) else { return }
        defaults.set(version, forKey: storageKey)
        requestReview()
    }
}
