//
//  PassProductsTests.swift
//  A Seat AwaitsTests
//
//  Unit tests for the Event Pass catalog (July 2026 pricing model), the
//  per-event entitlement resolution, and the create-event gate. All pure /
//  off-network.
//

import Foundation
import Testing
@testable import A_Seat_Awaits

// MARK: - Catalog

@Test func passCatalogContainsAllTiersAndUpgrades() {
    #expect(PassProducts.allPasses.count == 3)
    #expect(PassProducts.allUpgrades.count == 3)
    #expect(Set(PassProducts.allProductIDs).count == 6)
}

@Test func passProductIDsFollowTheScheme() {
    #expect(PassProduct(tier: .starter).productID == "aseatawaits.pass.starter")
    #expect(PassProduct(tier: .standard).productID == "aseatawaits.pass.standard")
    #expect(PassProduct(tier: .premium).productID == "aseatawaits.pass.premium")
    #expect(PassUpgradeProduct(from: .starter, to: .standard).productID
            == "aseatawaits.pass.upgrade.starter_standard")
    #expect(PassUpgradeProduct(from: .standard, to: .premium).productID
            == "aseatawaits.pass.upgrade.standard_premium")
    #expect(PassUpgradeProduct(from: .starter, to: .premium).productID
            == "aseatawaits.pass.upgrade.starter_premium")
}

@Test func passProductParsingRoundTrips() {
    for product in PassProducts.allPasses {
        #expect(PassProducts.parsePass(product.productID) == product)
        #expect(PassProducts.parseUpgrade(product.productID) == nil)
        #expect(PassProducts.isPassProduct(product.productID))
    }
    for upgrade in PassProducts.allUpgrades {
        #expect(PassProducts.parseUpgrade(upgrade.productID) == upgrade)
        #expect(PassProducts.parsePass(upgrade.productID) == nil)
        #expect(PassProducts.isPassProduct(upgrade.productID))
    }
    #expect(!PassProducts.isPassProduct("aseatawaits.sub.elite.monthly"))
    #expect(!PassProducts.isPassProduct(""))
}

@Test func upgradesOnlyGoUp() {
    // No downgrade or same-tier products exist.
    for upgrade in PassProducts.allUpgrades {
        #expect(upgrade.to > upgrade.from)
    }
    #expect(PassProducts.upgradeProduct(from: .premium, to: .starter) == nil)
    #expect(PassProducts.upgradeProduct(from: .standard, to: .standard) == nil)
    #expect(PassTier.premium.upgradeTargets.isEmpty)
    #expect(PassTier.starter.upgradeTargets == [.standard, .premium])
}

// MARK: - Tier definitions (mirror shared/billing/plans.ts EVENT_PASSES)

@Test func passTierLimitsMatchProductDefinition() {
    #expect(PassTier.starter.guestCap == 50)
    #expect(PassTier.standard.guestCap == 150)
    #expect(PassTier.premium.guestCap == 500)

    #expect(!PassTier.starter.aiImport)
    #expect(PassTier.standard.aiImport)
    #expect(PassTier.premium.aiImport)

    // Lifetime AI-import caps: 20 Standard / 50 Premium.
    #expect(PassTier.starter.aiImportLifetimeCap == 0)
    #expect(PassTier.standard.aiImportLifetimeCap == 20)
    #expect(PassTier.premium.aiImportLifetimeCap == 50)

    #expect(PassTier.starter.maxCollaboratorsPerEvent == 0)
    #expect(PassTier.standard.maxCollaboratorsPerEvent == 0)
    #expect(PassTier.premium.maxCollaboratorsPerEvent == 2)

    // Every pass exports & prints; only Premium shares/collaborates.
    for tier in PassTier.allCases { #expect(tier.exportAndPrint) }
    #expect(PassTier.premium.eventSharing)
    #expect(!PassTier.standard.eventSharing)
}

@Test func passTierNormalization() {
    #expect(PassTier.normalize("starter") == .starter)
    #expect(PassTier.normalize(" PREMIUM ") == .premium)
    #expect(PassTier.normalize("unknown") == nil)
    #expect(PassTier.normalize(nil) == nil)
}

// MARK: - Pass activity (passes never expire)

private func pass(tier: String = "standard", eventId: String? = "e1",
                  refundedAt: String? = nil, aiImportsUsed: Int = 0) -> EventPass {
    EventPass(id: "p-\(tier)-\(eventId ?? "nil")", eventId: eventId, userId: "u1",
              tier: tier, guestCap: PassTier.normalize(tier)?.guestCap ?? 0,
              amountPaidCents: 1999, currency: "usd", provider: "apple",
              purchasedAt: "2020-01-01T00:00:00Z", refundedAt: refundedAt,
              aiImportsUsed: aiImportsUsed)
}

@Test func onlyARefundRevokesAPass() {
    // A six-year-old pass is still active: passes never expire.
    #expect(pass().isActive)
    #expect(!pass(refundedAt: "2026-01-01T00:00:00Z").isActive)
}

// MARK: - Per-event entitlement

@Test func passEntitlesItsEvent() {
    let entitlement = EventEntitlement.resolve(pass: pass(tier: "premium"), policy: .free)
    #expect(entitlement.hasAnyEntitlement)
    #expect(entitlement.guestCap == 500)
    #expect(entitlement.aiImport)
    #expect(entitlement.exportAndPrint)
    #expect(entitlement.eventSharing)
    #expect(entitlement.maxCollaboratorsPerEvent == 2)
}

@Test func refundedPassEntitlesNothing() {
    let entitlement = EventEntitlement.resolve(pass: pass(refundedAt: "2026-01-01T00:00:00Z"),
                                               policy: .free)
    #expect(!entitlement.hasAnyEntitlement)
    #expect(entitlement.guestCap == 25) // Free fallback
}

@Test func passAndSubscriptionResolveToWhicheverGrantsMore() {
    let elitePolicy = PlanPolicy(nominalTier: .elite, status: .active)
    // Pro subscription (1000 guests, 5 collaborators) beats a Starter pass.
    let viaSub = EventEntitlement.resolve(pass: pass(tier: "starter"), policy: elitePolicy)
    #expect(viaSub.guestCap == 1000)
    #expect(viaSub.maxCollaboratorsPerEvent == 5)
    // A Premium pass beats a lapsed subscription.
    let lapsed = PlanPolicy(nominalTier: .elite, status: .canceled)
    let viaPass = EventEntitlement.resolve(pass: pass(tier: "premium"), policy: lapsed)
    #expect(viaPass.guestCap == 500)
    #expect(viaPass.maxCollaboratorsPerEvent == 2)
    #expect(viaPass.aiImport)
}

// MARK: - Create-event gate (mirrors the DB trigger's order)

private func snapshot(passes: [EventPass] = [],
                      plan: String? = nil, status: String? = nil,
                      legacyFree: Bool? = nil) -> AccountSnapshot {
    var sub: SubscriptionRow? = nil
    if plan != nil || status != nil {
        sub = SubscriptionRow(plan: plan, status: status, provider: "apple")
    }
    let profile = UserProfile(id: "u1", fullName: nil, subscriptionTier: nil,
                              subscriptionStatus: nil, legacyFree: legacyFree,
                              createdAt: nil, updatedAt: nil)
    return AccountSnapshot(
        authUser: AuthUser(id: "u1", email: "a@b.c", userMetadata: nil),
        profile: profile,
        subscription: sub,
        passes: passes)
}

@Test func createGateHonorsUnattachedPass() {
    #expect(snapshot(passes: [pass(eventId: nil)]).canCreateEvent)
    // Attached and refunded passes don't unlock creation.
    #expect(!snapshot(passes: [pass(eventId: "e1")]).canCreateEvent)
    #expect(!snapshot(passes: [pass(eventId: nil, refundedAt: "2026-01-01T00:00:00Z")]).canCreateEvent)
}

@Test func createGateHonorsSubscriptionAndLegacyFree() {
    #expect(snapshot(plan: "elite", status: "active").canCreateEvent)
    #expect(snapshot(plan: "basic", status: "trialing").canCreateEvent)
    #expect(!snapshot(plan: "elite", status: "canceled").canCreateEvent)
    #expect(snapshot(legacyFree: true).canCreateEvent)
    #expect(!snapshot(legacyFree: false).canCreateEvent)
    #expect(!snapshot().canCreateEvent)
}

@Test func snapshotPassLookups() {
    let attached = pass(tier: "standard", eventId: "e9")
    let unattached = pass(tier: "starter", eventId: nil)
    let refunded = pass(tier: "premium", eventId: "e2", refundedAt: "2026-01-01T00:00:00Z")
    let snap = snapshot(passes: [attached, unattached, refunded])
    #expect(snap.activePasses.count == 2)
    #expect(snap.unattachedActivePasses == [unattached])
    #expect(snap.activePass(forEvent: "e9") == attached)
    #expect(snap.activePass(forEvent: "e2") == nil)
}

// MARK: - Only Pro remains purchasable

@Test func onlyEliteIsPurchasable() {
    #expect(AppleProducts.purchasableTiers == [.elite])
    // Legacy product IDs must never be removed — restores depend on them.
    #expect(AppleProducts.all.count == 8)
}
