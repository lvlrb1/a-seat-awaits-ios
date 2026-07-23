//
//  PassProducts.swift
//  A Seat Awaits
//
//  The Event Pass product catalog (July 2026 pricing model): three one-time
//  consumable passes, plus three pay-the-difference upgrade consumables.
//  Mirrors `EVENT_PASSES` / `passUpgradePrice()` in the web repo's
//  `shared/billing/plans.ts` and the TS map in
//  `supabase/functions/_shared/apple.ts` — the three must stay in sync.
//  Product IDs are immutable once created in App Store Connect, so they live
//  here and nowhere else. Pure data — StoreKit calls live in
//  `SubscriptionStore`. Prices shown to users always come from
//  `Product.displayPrice`, never from this file.
//

import Foundation

// MARK: - Pass tier

/// One Event Pass tier. One pass = one event, and a pass never expires —
/// only a refund revokes it. Raw values match the DB `event_pass_tier` enum.
nonisolated enum PassTier: String, Sendable, Equatable, CaseIterable, Comparable {
    case starter
    case standard
    case premium

    /// Maps a raw tier string to a tier. Unknown/missing → nil.
    static func normalize(_ raw: String?) -> PassTier? {
        PassTier(rawValue: (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    var displayName: String {
        switch self {
        case .starter: return "Starter Pass"
        case .standard: return "Standard Pass"
        case .premium: return "Premium Pass"
        }
    }

    /// Short name without the "Pass" suffix, for compact badges.
    var shortName: String {
        switch self {
        case .starter: return "Starter"
        case .standard: return "Standard"
        case .premium: return "Premium"
        }
    }

    var tagline: String {
        switch self {
        case .starter: return "Everything you need for an intimate event"
        case .standard: return "The right size for most weddings"
        case .premium: return "Big guest lists, planned together"
        }
    }

    /// Hard guest cap for the event this pass is attached to.
    var guestCap: Int {
        switch self {
        case .starter: return 50
        case .standard: return 150
        case .premium: return 500
        }
    }

    var aiImport: Bool { self != .starter }

    /// Lifetime AI-import cap per event (the one metered cost a pass carries).
    /// Enforced server-side; surfaced here for display only.
    var aiImportLifetimeCap: Int {
        switch self {
        case .starter: return 0
        case .standard: return 20
        case .premium: return 50
        }
    }

    var maxCollaboratorsPerEvent: Int { self == .premium ? 2 : 0 }
    var collaboration: Bool { self == .premium }
    var exportAndPrint: Bool { true }
    var eventSharing: Bool { self == .premium }

    private var rank: Int {
        switch self {
        case .starter: return 0
        case .standard: return 1
        case .premium: return 2
        }
    }

    static func < (lhs: PassTier, rhs: PassTier) -> Bool { lhs.rank < rhs.rank }

    /// Tiers strictly above this one (upgrade targets), lowest first.
    var upgradeTargets: [PassTier] { PassTier.allCases.filter { $0 > self } }
}

// MARK: - Products

/// A purchasable pass consumable: a fresh pass at a tier.
nonisolated struct PassProduct: Sendable, Equatable, Identifiable {
    let tier: PassTier

    var id: String { productID }

    /// The App Store Connect product identifier, e.g. `aseatawaits.pass.standard`.
    var productID: String { "aseatawaits.pass.\(tier.rawValue)" }
}

/// A purchasable upgrade consumable: pays the difference to move an existing
/// pass from one tier up to another, in place (StoreKit cannot charge an
/// arbitrary delta like Stripe does, so each from→to pair is its own product).
nonisolated struct PassUpgradeProduct: Sendable, Equatable, Identifiable {
    let from: PassTier
    let to: PassTier

    var id: String { productID }

    /// e.g. `aseatawaits.pass.upgrade.starter_standard`. Underscore separator —
    /// App Store Connect product IDs only allow alphanumerics, periods, and underscores.
    var productID: String { "aseatawaits.pass.upgrade.\(from.rawValue)_\(to.rawValue)" }
}

nonisolated enum PassProducts {
    /// The three pass tiers, cheapest first (paywall display order).
    static let allPasses: [PassProduct] = PassTier.allCases.map(PassProduct.init)

    /// Every valid upgrade pair (from < to).
    static let allUpgrades: [PassUpgradeProduct] = PassTier.allCases.flatMap { from in
        from.upgradeTargets.map { PassUpgradeProduct(from: from, to: $0) }
    }

    /// All consumable product identifiers, for `Product.products(for:)`.
    static let allProductIDs: [String] =
        allPasses.map(\.productID) + allUpgrades.map(\.productID)

    static func passProduct(for tier: PassTier) -> PassProduct { PassProduct(tier: tier) }

    static func upgradeProduct(from: PassTier, to: PassTier) -> PassUpgradeProduct? {
        allUpgrades.first { $0.from == from && $0.to == to }
    }

    /// Parses a product identifier back to a pass purchase, if it is one.
    static func parsePass(_ productID: String) -> PassProduct? {
        allPasses.first { $0.productID == productID }
    }

    /// Parses a product identifier back to an upgrade, if it is one.
    static func parseUpgrade(_ productID: String) -> PassUpgradeProduct? {
        allUpgrades.first { $0.productID == productID }
    }

    /// True for any pass-related consumable (base pass or upgrade).
    static func isPassProduct(_ productID: String) -> Bool {
        parsePass(productID) != nil || parseUpgrade(productID) != nil
    }
}
