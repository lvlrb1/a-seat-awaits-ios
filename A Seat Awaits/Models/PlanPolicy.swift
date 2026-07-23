//
//  PlanPolicy.swift
//  A Seat Awaits
//
//  The single source of truth for subscription tiers, statuses and the per-tier
//  feature limits surfaced across the Account experience. Tier strings (`basic`,
//  `pro`, …) and limit numbers live here and nowhere else, so SwiftUI never
//  hard-codes a plan name, a guest cap, or an entitlement claim.
//
//  Entitlement rule (mirrors the web billing definitions): only `active` or
//  `trialing` subscriptions receive their paid tier's entitlements. Any other
//  status falls back to Free access regardless of the nominal plan, so a lapsed
//  Signature subscriber is shown the Free limits plus a payment-issue warning.
//
//  This is intentionally distinct from `CollaborationPlanPolicy`, which the
//  Collaborators screen depends on; the collaboration numbers are kept in sync
//  here so the Account summary and the Collaborators screen agree.
//

import Foundation

// MARK: - Tier

/// A normalized, customer-facing plan tier. The raw `subscription_tier` /
/// `billing_plan` enums use historical spellings (`basic`, `pro`) which collapse
/// to the display names below.
///
/// July 2026 pricing model: `elite` is the ONLY subscription still sold, and it
/// is marketed as "Pro". Core/Essentials/Signature are legacy (grandfathered)
/// subscriptions — existing subscribers keep them with full entitlements, but
/// they are never purchasable again. Never confuse the internal id `pro`
/// (legacy Signature) with the marketed "Pro" (internal `elite`). Consumers now
/// buy one-time Event Passes instead — see `PassTier` / `EventEntitlement`.
nonisolated enum PlanTier: String, Sendable, Equatable, CaseIterable {
    case free
    case core
    case essentials
    case signature
    case elite

    /// Maps a raw tier/plan string to a canonical tier. Unknown/missing → Free.
    static func normalize(_ raw: String?) -> PlanTier {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "core": return .core
        case "basic", "essentials": return .essentials
        case "pro", "signature": return .signature
        case "elite": return .elite
        case "free", "": return .free
        default: return .free
        }
    }

    /// The one customer-facing name mapping (mirrors `PLAN_DISPLAY_NAMES` in
    /// the web repo): `basic` → "Essentials", `pro` → "Signature", and `elite`
    /// → "Pro", the single subscription still sold.
    var displayName: String {
        switch self {
        case .free: return "Free"
        case .core: return "Core"
        case .essentials: return "Essentials"
        case .signature: return "Signature"
        case .elite: return "Pro"
        }
    }

    /// A one-line tagline for the plan, used in the subscription summary.
    var tagline: String {
        switch self {
        case .free: return "Get started with a single celebration"
        case .core: return "A little more room for one event"
        case .essentials: return "AI import, export & print for a few events"
        case .signature: return "Collaboration & public sharing for serious planners"
        case .elite: return "One subscription for professional planners and venues"
        }
    }

    /// The product-definition limits for this tier (before the entitlement check).
    var limits: PlanLimits {
        switch self {
        case .free:
            return PlanLimits(maxEvents: 1, maxGuestsPerEvent: 25,
                              aiImport: false, exportAndPrint: false,
                              publicSharing: false, collaboration: false,
                              maxCollaboratorsPerEvent: 0)
        case .core:
            return PlanLimits(maxEvents: 1, maxGuestsPerEvent: 50,
                              aiImport: false, exportAndPrint: false,
                              publicSharing: false, collaboration: false,
                              maxCollaboratorsPerEvent: 0)
        case .essentials:
            return PlanLimits(maxEvents: 3, maxGuestsPerEvent: 150,
                              aiImport: true, exportAndPrint: true,
                              publicSharing: false, collaboration: false,
                              maxCollaboratorsPerEvent: 0)
        case .signature:
            return PlanLimits(maxEvents: 10, maxGuestsPerEvent: 500,
                              aiImport: true, exportAndPrint: true,
                              publicSharing: true, collaboration: true,
                              maxCollaboratorsPerEvent: 2)
        case .elite:
            return PlanLimits(maxEvents: 100, maxGuestsPerEvent: 1000,
                              aiImport: true, exportAndPrint: true,
                              publicSharing: true, collaboration: true,
                              maxCollaboratorsPerEvent: 5)
        }
    }
}

// MARK: - Limits

/// The feature limits for a plan tier. Pure data — formatting lives in the view.
nonisolated struct PlanLimits: Sendable, Equatable {
    let maxEvents: Int
    let maxGuestsPerEvent: Int
    let aiImport: Bool
    let exportAndPrint: Bool
    let publicSharing: Bool
    let collaboration: Bool
    let maxCollaboratorsPerEvent: Int

    var eventsText: String { maxEvents == 1 ? "1 event" : "\(maxEvents.formatted()) events" }
    var guestsText: String { "\(maxGuestsPerEvent.formatted()) guests per event" }
    var collaboratorsText: String {
        guard collaboration else { return "No collaboration" }
        return "Up to \(maxCollaboratorsPerEvent) collaborator\(maxCollaboratorsPerEvent == 1 ? "" : "s") per event"
    }
}

// MARK: - Status

/// A subscription status. Covers every value of the backend
/// `stripe_subscription_status` enum plus an `unknown` fallback.
nonisolated enum SubscriptionStatus: String, Sendable, Equatable, CaseIterable {
    case active
    case trialing
    case pastDue = "past_due"
    case canceled
    case incomplete
    case incompleteExpired = "incomplete_expired"
    case unpaid
    case paused
    case unknown

    static func from(_ raw: String?) -> SubscriptionStatus {
        let key = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SubscriptionStatus(rawValue: key) ?? .unknown
    }

    /// Grants the nominal tier's paid entitlements.
    var isEntitled: Bool { self == .active || self == .trialing }

    /// The customer needs to take a billing action to keep/restore access.
    var hasPaymentIssue: Bool {
        switch self {
        case .pastDue, .unpaid, .incomplete: return true
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .active: return "Active"
        case .trialing: return "Trial"
        case .pastDue: return "Past due"
        case .canceled: return "Canceled"
        case .incomplete: return "Incomplete"
        case .incompleteExpired: return "Expired"
        case .unpaid: return "Unpaid"
        case .paused: return "Paused"
        case .unknown: return "—"
        }
    }

    /// Visual treatment for the status badge.
    enum Semantic: Sendable { case good, warning, bad, neutral }

    var semantic: Semantic {
        switch self {
        case .active, .trialing: return .good
        case .pastDue, .unpaid, .incomplete: return .warning
        case .canceled, .incompleteExpired: return .bad
        case .paused, .unknown: return .neutral
        }
    }
}

// MARK: - Policy

/// The effective plan policy for the signed-in user: the nominal tier, the real
/// status, and the entitlement-adjusted limits.
nonisolated struct PlanPolicy: Sendable, Equatable {
    /// The plan the user nominally holds (from `subscriptions.plan`, falling back
    /// to `users.subscription_tier`).
    let nominalTier: PlanTier
    let status: SubscriptionStatus

    /// Free fallback used before any data loads.
    static let free = PlanPolicy(nominalTier: .free, status: .active)

    /// Resolves from the authoritative subscription row when present, else from
    /// the `users` fallback fields.
    static func resolve(subscription: SubscriptionRow?,
                        fallbackTier: String?,
                        fallbackStatus: String?) -> PlanPolicy {
        if let sub = subscription {
            return PlanPolicy(nominalTier: PlanTier.normalize(sub.plan),
                              status: SubscriptionStatus.from(sub.status))
        }
        return PlanPolicy(nominalTier: PlanTier.normalize(fallbackTier),
                          status: SubscriptionStatus.from(fallbackStatus))
    }

    /// True when the status grants the nominal tier's entitlements.
    var isEntitled: Bool { status.isEntitled }

    /// The tier whose limits actually apply right now (Free unless entitled).
    var effectiveTier: PlanTier { isEntitled ? nominalTier : .free }

    /// Limits in force right now.
    var limits: PlanLimits { effectiveTier.limits }

    /// What the nominal plan *includes* when in good standing (for the plan card).
    var nominalLimits: PlanLimits { nominalTier.limits }

    var planDisplayName: String { nominalTier.displayName }
    var isTopTier: Bool { nominalTier == .elite }
    var isFree: Bool { nominalTier == .free }

    /// True when a paid plan's access is currently reduced to Free by its status.
    var isAccessReducedByStatus: Bool { nominalTier != .free && !isEntitled }

    /// Whether the user can use export/print right now.
    var canExportAndPrint: Bool { limits.exportAndPrint }

    /// A feature checklist for the nominal plan, for the subscription summary.
    var nominalFeatures: [PlanFeature] {
        let l = nominalLimits
        return [
            PlanFeature(label: l.eventsText, included: true),
            PlanFeature(label: l.guestsText, included: true),
            PlanFeature(label: "AI guest import", included: l.aiImport),
            PlanFeature(label: "Export & print floor plans", included: l.exportAndPrint),
            PlanFeature(label: "Public event sharing", included: l.publicSharing),
            PlanFeature(label: l.collaboration ? l.collaboratorsText : "Collaboration", included: l.collaboration),
        ]
    }
}

/// One row in a plan's feature checklist.
nonisolated struct PlanFeature: Sendable, Equatable, Identifiable {
    let label: String
    let included: Bool
    var id: String { label }
}
