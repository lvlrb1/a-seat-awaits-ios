//
//  AppleProductsTests.swift
//  A Seat AwaitsTests
//
//  Unit tests for the App Store product catalog and the billing-provider
//  gating that decides who sees purchase UI. All pure / off-network.
//

import Foundation
import Testing
@testable import A_Seat_Awaits

// MARK: - Product catalog

@Test func catalogContainsAllPaidTiersAndPeriods() {
    #expect(AppleProducts.all.count == 8)
    #expect(Set(AppleProducts.allProductIDs).count == 8)
    for tier in [PlanTier.core, .essentials, .signature, .elite] {
        for period in AppleBillingPeriod.allCases {
            #expect(AppleProducts.all.contains(AppleProduct(tier: tier, period: period)))
        }
    }
    // Free is never sold.
    #expect(!AppleProducts.paidTiers.contains(.free))
}

@Test func productIDsFollowTheScheme() {
    #expect(AppleProduct(tier: .signature, period: .monthly).productID
            == "aseatawaits.sub.signature.monthly")
    #expect(AppleProduct(tier: .core, period: .annual).productID
            == "aseatawaits.sub.core.annual")
}

@Test func productIDParsingRoundTrips() {
    for product in AppleProducts.all {
        let parsed = AppleProducts.parse(product.productID)
        #expect(parsed == product)
    }
    #expect(AppleProducts.parse("aseatawaits.sub.unknown.monthly") == nil)
    #expect(AppleProducts.parse("") == nil)
}

@Test func paidTiersAreRankedHighestFirst() {
    #expect(AppleProducts.paidTiers == [.elite, .signature, .essentials, .core])
}

// MARK: - Billing provider derivation

@Test func billingProviderDefaultsToStripeForPaidPlans() {
    // Rows written before the provider column existed decode as nil → Stripe.
    #expect(BillingProvider(provider: nil, plan: "pro") == .stripe)
    #expect(BillingProvider(provider: "stripe", plan: "elite") == .stripe)
    #expect(BillingProvider(provider: "apple", plan: "elite") == .apple)
    #expect(BillingProvider(provider: " APPLE ", plan: "core") == .apple)
}

@Test func billingProviderIsNoneForFree() {
    #expect(BillingProvider(provider: nil, plan: nil) == .none)
    #expect(BillingProvider(provider: "stripe", plan: "free") == .none)
    #expect(BillingProvider(provider: "apple", plan: nil) == .none)
}

// MARK: - Stripe-active gating (who must NOT see purchase UI)

private func snapshot(provider: String?, plan: String?, status: String?) -> AccountSnapshot {
    var sub: SubscriptionRow? = nil
    if plan != nil || status != nil || provider != nil {
        sub = SubscriptionRow(plan: plan, status: status, provider: provider)
    }
    return AccountSnapshot(
        authUser: AuthUser(id: "user-1", email: "a@b.c", userMetadata: nil),
        profile: nil,
        subscription: sub)
}

@Test func stripeUsersWithLiveBillingAreGated() {
    for status in ["active", "trialing", "past_due", "unpaid", "incomplete", "paused"] {
        let snap = snapshot(provider: "stripe", plan: "pro", status: status)
        #expect(snap.hasActiveStripeBilling, "expected gating for stripe status \(status)")
    }
}

@Test func endedStripeSubscriptionsAreNotGated() {
    #expect(!snapshot(provider: "stripe", plan: "pro", status: "canceled").hasActiveStripeBilling)
    #expect(!snapshot(provider: "stripe", plan: "pro", status: "incomplete_expired").hasActiveStripeBilling)
}

@Test func appleAndFreeUsersAreNotGated() {
    #expect(!snapshot(provider: "apple", plan: "elite", status: "active").hasActiveStripeBilling)
    #expect(!snapshot(provider: nil, plan: nil, status: nil).hasActiveStripeBilling)
    #expect(!snapshot(provider: "stripe", plan: "free", status: "active").hasActiveStripeBilling)
}
