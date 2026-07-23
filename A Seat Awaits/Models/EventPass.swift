//
//  EventPass.swift
//  A Seat Awaits
//
//  Mirrors the `event_passes` table (RLS lets a user select their own rows).
//  A pass never expires — only a refund revokes it (`refunded_at` set). A row
//  with `event_id == nil` is an unattached pass, bought before the event
//  exists; the database attaches it automatically when the buyer creates
//  their next event.
//

import Foundation

nonisolated struct EventPass: Codable, Identifiable, Equatable, Sendable {
    let id: String
    /// Nil for an unattached pass (auto-attaches at event creation).
    var eventId: String?
    let userId: String
    /// Raw tier string from the DB enum; use `passTier` for typed access.
    var tier: String
    var guestCap: Int
    var amountPaidCents: Int
    var currency: String?
    var provider: String?
    var purchasedAt: String?
    var refundedAt: String?
    var aiImportsUsed: Int

    enum CodingKeys: String, CodingKey {
        case id, tier, currency, provider
        case eventId = "event_id"
        case userId = "user_id"
        case guestCap = "guest_cap"
        case amountPaidCents = "amount_paid_cents"
        case purchasedAt = "purchased_at"
        case refundedAt = "refunded_at"
        case aiImportsUsed = "ai_imports_used"
    }

    /// PostgREST `select` list for this row.
    static let selectColumns =
        "id,event_id,user_id,tier,guest_cap,amount_paid_cents,currency,provider,purchased_at,refunded_at,ai_imports_used"

    /// Passes never expire; only a refund revokes one.
    var isActive: Bool { refundedAt == nil }

    var isAttached: Bool { eventId != nil }

    var passTier: PassTier? { PassTier.normalize(tier) }

    var tierDisplayName: String { passTier?.displayName ?? tier.capitalized }

    /// Lifetime AI-import cap for this pass's tier (0 = tier has no AI import).
    var aiImportCap: Int { passTier?.aiImportLifetimeCap ?? 0 }
}

// MARK: - Per-event entitlement

/// What entitles a single event: an active pass attached to it, the account's
/// entitled subscription, or nothing. Where both a pass and a subscription
/// apply, each feature resolves to whichever grants more. This is display/UX
/// only — the database trigger and edge functions are the real enforcement.
nonisolated struct EventEntitlement: Sendable, Equatable {
    /// The event's active (non-refunded) pass, if any.
    let pass: EventPass?
    /// The account-wide plan policy (entitled subscription or Free).
    let policy: PlanPolicy

    static func resolve(pass: EventPass?, policy: PlanPolicy) -> EventEntitlement {
        EventEntitlement(pass: (pass?.isActive == true) ? pass : nil, policy: policy)
    }

    private var passTier: PassTier? { pass?.passTier }
    private var subscriptionLimits: PlanLimits { policy.limits }

    var hasAnyEntitlement: Bool { pass != nil || policy.effectiveTier != .free }

    var guestCap: Int {
        max(pass?.guestCap ?? 0, subscriptionLimits.maxGuestsPerEvent)
    }

    var aiImport: Bool {
        (passTier?.aiImport ?? false) || subscriptionLimits.aiImport
    }

    var exportAndPrint: Bool {
        (passTier?.exportAndPrint ?? false) || subscriptionLimits.exportAndPrint
    }

    var eventSharing: Bool {
        (passTier?.eventSharing ?? false) || subscriptionLimits.publicSharing
    }

    var collaboration: Bool {
        (passTier?.collaboration ?? false) || subscriptionLimits.collaboration
    }

    var maxCollaboratorsPerEvent: Int {
        max(passTier?.maxCollaboratorsPerEvent ?? 0, subscriptionLimits.maxCollaboratorsPerEvent)
    }
}
