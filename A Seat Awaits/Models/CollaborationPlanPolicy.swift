//
//  CollaborationPlanPolicy.swift
//  A Seat Awaits
//
//  The subscription-driven collaboration entitlement. These constants mirror the
//  product's billing definitions (kept in one place so tier strings and per-event
//  limits never get scattered through SwiftUI):
//
//    Tier (normalized)   Collaboration   Max collaborators / event
//    Free                disabled        0
//    Core                disabled        0
//    Essentials (basic)  disabled        0
//    Signature (pro)     enabled         2
//    Elite               enabled         5
//
//  Only `active` or `trialing` subscriptions are entitled; any other status falls
//  back to Free collaboration limits regardless of the nominal tier.
//

import Foundation

/// A normalized subscription tier. The raw `subscription_tier` enum in
/// `public.users` uses a handful of historical spellings (`basic`, `pro`, …)
/// which we collapse to the customer-facing names.
nonisolated enum CollaborationTier: Sendable, Equatable, CaseIterable {
    case free
    case core
    case essentials
    case signature
    case elite

    /// Maps a raw `subscription_tier` string to a canonical tier. Unknown or
    /// missing values are treated as Free.
    static func normalize(_ raw: String?) -> CollaborationTier {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "core": return .core
        case "basic", "essentials": return .essentials
        case "pro", "signature": return .signature
        case "elite": return .elite
        case "free", "": return .free
        default: return .free
        }
    }

    /// Customer-facing plan name.
    var displayName: String {
        switch self {
        case .free: return "Free"
        case .core: return "Core"
        case .essentials: return "Essentials"
        case .signature: return "Signature"
        case .elite: return "Elite"
        }
    }

    /// Whether this tier's product definition includes collaboration at all.
    var collaborationEnabled: Bool {
        self == .signature || self == .elite
    }

    /// Max collaborators allowed per event for this tier's product definition.
    var maxCollaboratorsPerEvent: Int {
        switch self {
        case .signature: return 2
        case .elite: return 5
        case .free, .core, .essentials: return 0
        }
    }
}

/// The effective collaboration policy for the signed-in user, combining the
/// normalized tier with the subscription status entitlement check.
nonisolated struct CollaborationPlanPolicy: Equatable, Sendable {
    let tier: CollaborationTier
    /// True when the subscription status is `active` or `trialing`.
    let isEntitled: Bool

    /// Subscription statuses that grant the tier's entitlements.
    static let entitledStatuses: Set<String> = ["active", "trialing"]

    /// Resolves the policy from the raw `users` row fields.
    static func resolve(subscriptionTier: String?, subscriptionStatus: String?) -> CollaborationPlanPolicy {
        let tier = CollaborationTier.normalize(subscriptionTier)
        let status = (subscriptionStatus ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return CollaborationPlanPolicy(tier: tier, isEntitled: entitledStatuses.contains(status))
    }

    /// Free policy fallback (used when no profile could be loaded).
    static let free = CollaborationPlanPolicy(tier: .free, isEntitled: false)

    var planDisplayName: String { tier.displayName }

    /// True when already on the highest collaboration tier — there is nothing to
    /// upgrade to, so the CTA should read "Manage" rather than "Upgrade".
    var isTopTier: Bool { tier == .elite }

    /// Collaboration is only enabled when both the tier supports it *and* the
    /// subscription is in good standing. Otherwise we fall back to Free limits.
    var isCollaborationEnabled: Bool { isEntitled && tier.collaborationEnabled }

    /// Effective per-event collaborator limit (0 when collaboration is disabled).
    var maxCollaboratorsPerEvent: Int {
        isCollaborationEnabled ? tier.maxCollaboratorsPerEvent : 0
    }

    var availabilityMessage: String {
        isCollaborationEnabled
            ? "Collaboration is enabled on your plan."
            : "Your current plan doesn't include collaboration."
    }
}
