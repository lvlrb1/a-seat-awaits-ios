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

/// How much the yearly subscription saves versus twelve monthly renewals,
/// derived from the App Store prices so the paywall never hard-codes a claim.
nonisolated enum AnnualSavings: Equatable, Sendable {
    /// The yearly price equals (within rounding) a whole number of monthly
    /// payments left off, e.g. "2 months free".
    case monthsFree(Int)
    /// Anything else, as a whole-percent saving, e.g. "Save 17%".
    case percent(Int)

    /// Nil when there is no saving to advertise (missing prices, or yearly
    /// costs as much as or more than monthly × 12).
    static func compute(monthly: Decimal?, annual: Decimal?) -> AnnualSavings? {
        guard let monthly, let annual, monthly > 0, annual > 0 else { return nil }
        let yearAtMonthly = monthly * 12
        guard annual < yearAtMonthly else { return nil }
        let monthsFreeExact = (yearAtMonthly - annual) / monthly
        let monthsFreeDouble = NSDecimalNumber(decimal: monthsFreeExact).doubleValue
        let roundedMonths = Int(monthsFreeDouble.rounded())
        if roundedMonths >= 1, abs(monthsFreeDouble - Double(roundedMonths)) < 0.1 {
            return .monthsFree(roundedMonths)
        }
        let fraction = NSDecimalNumber(decimal: (yearAtMonthly - annual) / yearAtMonthly).doubleValue
        let percent = Int((fraction * 100).rounded())
        return percent >= 1 ? .percent(percent) : nil
    }

    /// Short marketing line for the paywall.
    var label: String {
        switch self {
        case .monthsFree(let n):
            return n == 1 ? "1 month free with yearly billing" : "\(n) months free with yearly billing"
        case .percent(let p):
            return "Save \(p)% with yearly billing"
        }
    }
}
