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

    /// Customer-facing plan name (`elite` is sold as "Pro" — see `PlanTier`).
    var displayName: String {
        switch self {
        case .free: return "Free"
        case .core: return "Core"
        case .essentials: return "Essentials"
        case .signature: return "Signature"
        case .elite: return "Pro"
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

/// The effective collaboration policy for one event: the owner's subscription
/// entitlement combined with the event's Event Pass, whichever grants more.
/// A Premium pass grants 2 collaborators; the Pro subscription (internal
/// `elite`) grants 5; legacy Signature (internal `pro`) grants 2.
nonisolated struct CollaborationPlanPolicy: Equatable, Sendable {
    let tier: CollaborationTier
    /// True when the subscription status is `active` or `trialing`.
    let isEntitled: Bool
    /// The event's active pass tier, if the event has one.
    let passTier: PassTier?

    /// Subscription statuses that grant the tier's entitlements.
    static let entitledStatuses: Set<String> = ["active", "trialing"]

    /// Resolves the policy from the raw `users` row fields plus the event's pass.
    static func resolve(subscriptionTier: String?, subscriptionStatus: String?,
                        pass: EventPass? = nil) -> CollaborationPlanPolicy {
        let tier = CollaborationTier.normalize(subscriptionTier)
        let status = (subscriptionStatus ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return CollaborationPlanPolicy(tier: tier,
                                       isEntitled: entitledStatuses.contains(status),
                                       passTier: (pass?.isActive == true) ? pass?.passTier : nil)
    }

    /// Free policy fallback (used when no profile could be loaded).
    static let free = CollaborationPlanPolicy(tier: .free, isEntitled: false, passTier: nil)

    /// What to name the entitlement in copy: the pass when it's what grants
    /// collaboration, otherwise the subscription plan.
    var planDisplayName: String {
        if let passTier, passTier.collaboration, subscriptionCollaboratorLimit == 0 {
            return passTier.displayName
        }
        return tier.displayName
    }

    /// True when nothing higher exists for this event: the Pro subscription is
    /// the ceiling, so the CTA reads "Manage" rather than "Upgrade".
    var isTopTier: Bool { isEntitled && tier == .elite }

    private var subscriptionCollaboratorLimit: Int {
        (isEntitled && tier.collaborationEnabled) ? tier.maxCollaboratorsPerEvent : 0
    }

    private var passCollaboratorLimit: Int {
        passTier?.maxCollaboratorsPerEvent ?? 0
    }

    /// Collaboration is enabled by an entitled collaborative subscription OR
    /// the event's Premium pass. Otherwise Free limits apply.
    var isCollaborationEnabled: Bool { maxCollaboratorsPerEvent > 0 }

    /// Effective per-event collaborator limit — the more generous of the
    /// subscription's and the pass's (0 when collaboration is disabled).
    var maxCollaboratorsPerEvent: Int {
        max(subscriptionCollaboratorLimit, passCollaboratorLimit)
    }

    var availabilityMessage: String {
        isCollaborationEnabled
            ? "Collaboration is enabled on your plan."
            : "Collaboration is included with a Premium Pass or the Pro subscription."
    }
}
