//
//  AppleProducts.swift
//  A Seat Awaits
//
//  The App Store product catalog: the eight auto-renewable subscription
//  product identifiers and their mapping to `PlanTier`. Product IDs are
//  immutable once created in App Store Connect, so they live here and
//  nowhere else. Pure data — StoreKit calls live in `SubscriptionStore`.
//

import Foundation

/// Billing period for an App Store subscription product.
nonisolated enum AppleBillingPeriod: String, Sendable, Equatable, CaseIterable {
    case monthly
    case annual
}

/// One purchasable App Store product: a paid tier at a billing period.
nonisolated struct AppleProduct: Sendable, Equatable, Identifiable {
    let tier: PlanTier
    let period: AppleBillingPeriod

    var id: String { productID }

    /// The App Store Connect product identifier, e.g.
    /// `aseatawaits.sub.signature.monthly`.
    var productID: String { "aseatawaits.sub.\(tier.rawValue).\(period.rawValue)" }
}

nonisolated enum AppleProducts {
    /// The subscription group every product belongs to (reference name in
    /// App Store Connect: "A Seat Awaits Plans").
    static let subscriptionGroupName = "A Seat Awaits Plans"

    /// Every paid tier with App Store products, highest first (matches the
    /// subscription group's ranking in App Store Connect: Elite is level 1).
    /// Legacy tiers stay here forever — restores and webhook mapping depend on
    /// their product IDs — but only `purchasableTiers` may be offered for sale.
    static let paidTiers: [PlanTier] = [.elite, .signature, .essentials, .core]

    /// The only subscription still sold (July 2026 model): `elite`, marketed
    /// as "Pro". Core/Essentials/Signature are grandfathered — never shown as
    /// purchase options again.
    static let purchasableTiers: [PlanTier] = [.elite]

    /// Every purchasable product, all tiers × both periods.
    static let all: [AppleProduct] = paidTiers.flatMap { tier in
        AppleBillingPeriod.allCases.map { AppleProduct(tier: tier, period: $0) }
    }

    /// All product identifiers, for `Product.products(for:)`.
    static let allProductIDs: [String] = all.map(\.productID)

    /// Parses a product identifier back to its tier and period. Returns nil
    /// for unknown identifiers (e.g. a product added server-side before the
    /// app knows about it).
    static func parse(_ productID: String) -> AppleProduct? {
        all.first { $0.productID == productID }
    }
}
