//
//  CollaboratorsTests.swift
//  A Seat AwaitsTests
//
//  Unit tests for the native Collaborators management logic: plan policy,
//  aggregation of shares + invitations, per-event usage, mutation filter
//  scoping, and error mapping. All pure / off-network.
//

import Foundation
import Testing
@testable import A_Seat_Awaits

// MARK: - Fixtures

private func event(_ id: String, name: String = "Event") -> OwnedEventRow {
    OwnedEventRow(id: id, name: name, ownerId: "owner-1", createdAt: nil)
}

private func share(_ id: String, event: String, email: String, role: String = "viewer") -> EventShareRecord {
    EventShareRecord(id: id, eventId: event, email: email, role: role, createdAt: nil)
}

private func invite(_ id: String,
                    event: String,
                    email: String,
                    name: String? = nil,
                    role: String = "editor") -> PendingInvitationRecord {
    PendingInvitationRecord(id: id, eventId: event, inviterId: "owner-1",
                            inviteeName: name, inviteeEmail: email,
                            role: role, status: "pending", createdAt: nil)
}

// MARK: - Plan policy

@Suite("Collaboration plan policy")
struct CollaborationPlanPolicyTests {

    @Test("Tier strings normalize to canonical tiers")
    func normalization() {
        #expect(CollaborationTier.normalize("free") == .free)
        #expect(CollaborationTier.normalize("core") == .core)
        #expect(CollaborationTier.normalize("basic") == .essentials)
        #expect(CollaborationTier.normalize("essentials") == .essentials)
        #expect(CollaborationTier.normalize("pro") == .signature)
        #expect(CollaborationTier.normalize("signature") == .signature)
        #expect(CollaborationTier.normalize("elite") == .elite)
        #expect(CollaborationTier.normalize("ELITE ") == .elite)
        #expect(CollaborationTier.normalize(nil) == .free)
        #expect(CollaborationTier.normalize("mystery") == .free)
    }

    @Test("Display names match billing definitions")
    func displayNames() {
        #expect(CollaborationTier.normalize("basic").displayName == "Essentials")
        #expect(CollaborationTier.normalize("pro").displayName == "Signature")
    }

    @Test("Effective per-event limits per tier when active")
    func limitsWhenActive() {
        func limit(_ tier: String) -> Int {
            CollaborationPlanPolicy.resolve(subscriptionTier: tier, subscriptionStatus: "active")
                .maxCollaboratorsPerEvent
        }
        #expect(limit("free") == 0)
        #expect(limit("core") == 0)
        #expect(limit("essentials") == 0)
        #expect(limit("signature") == 2)
        #expect(limit("elite") == 5)
    }

    @Test("Collaboration enablement per tier when active")
    func enabledWhenActive() {
        func enabled(_ tier: String) -> Bool {
            CollaborationPlanPolicy.resolve(subscriptionTier: tier, subscriptionStatus: "active")
                .isCollaborationEnabled
        }
        #expect(enabled("free") == false)
        #expect(enabled("core") == false)
        #expect(enabled("essentials") == false)
        #expect(enabled("signature") == true)
        #expect(enabled("elite") == true)
    }

    @Test("Active and trialing are entitled; other statuses fall back to Free limits")
    func statusEntitlement() {
        let active = CollaborationPlanPolicy.resolve(subscriptionTier: "signature", subscriptionStatus: "active")
        let trialing = CollaborationPlanPolicy.resolve(subscriptionTier: "signature", subscriptionStatus: "trialing")
        let canceled = CollaborationPlanPolicy.resolve(subscriptionTier: "signature", subscriptionStatus: "canceled")
        let pastDue = CollaborationPlanPolicy.resolve(subscriptionTier: "elite", subscriptionStatus: "past_due")
        let missing = CollaborationPlanPolicy.resolve(subscriptionTier: "elite", subscriptionStatus: nil)

        #expect(active.maxCollaboratorsPerEvent == 2)
        #expect(trialing.maxCollaboratorsPerEvent == 2)
        #expect(active.isCollaborationEnabled)
        #expect(trialing.isCollaborationEnabled)

        // Not entitled -> Free limits, even though nominal tier is paid.
        #expect(canceled.maxCollaboratorsPerEvent == 0)
        #expect(canceled.isCollaborationEnabled == false)
        #expect(pastDue.maxCollaboratorsPerEvent == 0)
        #expect(missing.maxCollaboratorsPerEvent == 0)
        // Nominal plan name is still surfaced.
        #expect(canceled.planDisplayName == "Signature")
    }

    @Test("Only Elite is the top tier (Manage vs Upgrade CTA)")
    func topTier() {
        func top(_ tier: String) -> Bool {
            CollaborationPlanPolicy.resolve(subscriptionTier: tier, subscriptionStatus: "active").isTopTier
        }
        #expect(top("elite") == true)
        #expect(top("signature") == false)
        #expect(top("free") == false)
    }

    @Test("Availability message reflects enablement")
    func availabilityMessage() {
        let on = CollaborationPlanPolicy.resolve(subscriptionTier: "signature", subscriptionStatus: "active")
        let off = CollaborationPlanPolicy.resolve(subscriptionTier: "free", subscriptionStatus: "active")
        #expect(on.availabilityMessage == "Collaboration is enabled on your plan.")
        #expect(off.availabilityMessage == "Collaboration is included with a Premium Pass or the Pro subscription.")
    }

    @Test("A Premium pass grants collaboration to an otherwise-free account")
    func premiumPassGrantsCollaboration() {
        let premium = EventPass(id: "p1", eventId: "e1", userId: "u1", tier: "premium",
                                guestCap: 500, amountPaidCents: 3999, currency: "usd",
                                provider: "apple", purchasedAt: nil, refundedAt: nil,
                                aiImportsUsed: 0)
        let policy = CollaborationPlanPolicy.resolve(subscriptionTier: "free",
                                                     subscriptionStatus: nil,
                                                     pass: premium)
        #expect(policy.isCollaborationEnabled)
        #expect(policy.maxCollaboratorsPerEvent == 2)
        #expect(policy.planDisplayName == "Premium Pass")

        // A refunded pass grants nothing.
        var refunded = premium
        refunded.refundedAt = "2026-07-01T00:00:00Z"
        let revoked = CollaborationPlanPolicy.resolve(subscriptionTier: "free",
                                                      subscriptionStatus: nil,
                                                      pass: refunded)
        #expect(revoked.isCollaborationEnabled == false)

        // Standard/Starter passes don't include collaboration.
        var standard = premium
        standard.tier = "standard"
        let noCollab = CollaborationPlanPolicy.resolve(subscriptionTier: "free",
                                                       subscriptionStatus: nil,
                                                       pass: standard)
        #expect(noCollab.maxCollaboratorsPerEvent == 0)
    }

    @Test("Pass and subscription combine to whichever grants more")
    func passAndSubscriptionCombine() {
        let premium = EventPass(id: "p1", eventId: "e1", userId: "u1", tier: "premium",
                                guestCap: 500, amountPaidCents: 3999, currency: "usd",
                                provider: "apple", purchasedAt: nil, refundedAt: nil,
                                aiImportsUsed: 0)
        // Entitled Pro subscription (5) beats the Premium pass (2).
        let elite = CollaborationPlanPolicy.resolve(subscriptionTier: "elite",
                                                    subscriptionStatus: "active",
                                                    pass: premium)
        #expect(elite.maxCollaboratorsPerEvent == 5)
        // A lapsed subscription contributes nothing; the pass still grants 2.
        let lapsed = CollaborationPlanPolicy.resolve(subscriptionTier: "elite",
                                                     subscriptionStatus: "canceled",
                                                     pass: premium)
        #expect(lapsed.maxCollaboratorsPerEvent == 2)
    }
}

// MARK: - Aggregation

@Suite("Collaborators overview aggregation")
struct CollaboratorsOverviewTests {

    private let policy = CollaborationPlanPolicy.resolve(subscriptionTier: "signature", subscriptionStatus: "active")

    @Test("Counts active shares and pending invitations separately")
    func basicCounts() {
        let overview = CollaboratorsOverview.build(
            policy: policy,
            ownedEvents: [event("e1", name: "Wedding")],
            shares: [share("s1", event: "e1", email: "a@x.com", role: "editor")],
            invitations: [invite("i1", event: "e1", email: "b@x.com")],
            resolvedNames: [:])

        #expect(overview.activeCollaboratorCount == 1)
        #expect(overview.pendingInvitationCount == 1)
        #expect(overview.uniquePeopleCount == 2)
        #expect(overview.isEmpty == false)

        let summary = overview.events.first
        #expect(summary?.currentCount == 2)
        #expect(summary?.activeCount == 1)
        #expect(summary?.pendingCount == 1)
    }

    @Test("Duplicate email casing collapses to one person")
    func duplicateCasing() {
        let overview = CollaboratorsOverview.build(
            policy: policy,
            ownedEvents: [event("e1"), event("e2")],
            shares: [
                share("s1", event: "e1", email: "Sam@Example.com"),
                share("s2", event: "e2", email: "sam@example.com  "),
            ],
            invitations: [],
            resolvedNames: [:])

        #expect(overview.activeCollaboratorCount == 2)   // two grants
        #expect(overview.uniquePeopleCount == 1)         // one person
    }

    @Test("One person across multiple events counts as multiple grants, one person")
    func onePersonMultipleEvents() {
        let overview = CollaboratorsOverview.build(
            policy: policy,
            ownedEvents: [event("e1"), event("e2"), event("e3")],
            shares: [
                share("s1", event: "e1", email: "j@x.com"),
                share("s2", event: "e2", email: "j@x.com"),
                share("s3", event: "e3", email: "j@x.com"),
            ],
            invitations: [],
            resolvedNames: ["j@x.com": "Jamie"])

        #expect(overview.activeCollaboratorCount == 3)
        #expect(overview.uniquePeopleCount == 1)

        let person = overview.people.first
        #expect(person?.eventCount == 3)
        #expect(person?.displayName == "Jamie")
    }

    @Test("Mixed roles across events is reported globally; exact role per event")
    func mixedRoles() {
        let overview = CollaboratorsOverview.build(
            policy: policy,
            ownedEvents: [event("e1"), event("e2")],
            shares: [
                share("s1", event: "e1", email: "k@x.com", role: "viewer"),
                share("s2", event: "e2", email: "k@x.com", role: "editor"),
            ],
            invitations: [],
            resolvedNames: [:])

        let person = try! #require(overview.people.first)
        #expect(person.globalRoleLabel == "Mixed roles")

        // Exact role within each event.
        let e1 = overview.events.first { $0.eventId == "e1" }
        let e2 = overview.events.first { $0.eventId == "e2" }
        #expect(e1?.collaborators.first?.role == .viewer)
        #expect(e2?.collaborators.first?.role == .editor)
    }

    @Test("Consistent role reports that role globally")
    func consistentRole() {
        let overview = CollaboratorsOverview.build(
            policy: policy,
            ownedEvents: [event("e1"), event("e2")],
            shares: [
                share("s1", event: "e1", email: "k@x.com", role: "editor"),
                share("s2", event: "e2", email: "k@x.com", role: "editor"),
            ],
            invitations: [],
            resolvedNames: [:])
        #expect(overview.people.first?.globalRoleLabel == "Editor")
    }

    @Test("Per-event usage = active shares + pending invitations, with limit status")
    func usageAndLimit() {
        // Signature = 2 per event.
        let atLimit = CollaboratorsOverview.build(
            policy: policy,
            ownedEvents: [event("e1")],
            shares: [share("s1", event: "e1", email: "a@x.com")],
            invitations: [invite("i1", event: "e1", email: "b@x.com")],
            resolvedNames: [:]).events.first

        #expect(atLimit?.currentCount == 2)
        #expect(atLimit?.isAtLimit == true)
        #expect(atLimit?.usageLevel == .limitReached)

        let warning = CollaboratorsOverview.build(
            policy: policy,
            ownedEvents: [event("e1")],
            shares: [share("s1", event: "e1", email: "a@x.com")],
            invitations: [],
            resolvedNames: [:]).events.first
        #expect(warning?.usageLevel == .warning)   // 1 of 2
    }

    @Test("Pending invitation prefers invitee_name then resolved name then email")
    func pendingNameResolution() {
        let overview = CollaboratorsOverview.build(
            policy: policy,
            ownedEvents: [event("e1")],
            shares: [],
            invitations: [
                invite("i1", event: "e1", email: "named@x.com", name: "Pat"),
                invite("i2", event: "e1", email: "resolved@x.com"),
                invite("i3", event: "e1", email: "bare@x.com"),
            ],
            resolvedNames: ["resolved@x.com": "Robin"])

        func name(_ email: String) -> String? {
            overview.events.first?.collaborators.first { $0.email == email }?.displayName
        }
        #expect(name("named@x.com") == "Pat")
        #expect(name("resolved@x.com") == "Robin")
        #expect(name("bare@x.com") == "bare@x.com")
    }

    @Test("Empty owned event still appears with zero collaborators")
    func emptyEvent() {
        let overview = CollaboratorsOverview.build(
            policy: policy,
            ownedEvents: [event("e1", name: "Empty")],
            shares: [],
            invitations: [],
            resolvedNames: [:])
        #expect(overview.events.count == 1)
        #expect(overview.events.first?.collaborators.isEmpty == true)
        #expect(overview.isEmpty == true)
    }

    @Test("Shares for non-owned events are ignored")
    func ignoresForeignEvents() {
        let overview = CollaboratorsOverview.build(
            policy: policy,
            ownedEvents: [event("e1")],
            shares: [
                share("s1", event: "e1", email: "a@x.com"),
                share("s2", event: "OTHER", email: "intruder@x.com"),
            ],
            invitations: [],
            resolvedNames: [:])
        #expect(overview.activeCollaboratorCount == 1)
        #expect(overview.uniquePeopleCount == 1)
    }

    @Test("Removing a person's only share drops them from the global list (reconcile)")
    func reconcileAfterRemoval() {
        var shares = [
            share("s1", event: "e1", email: "a@x.com"),
            share("s2", event: "e1", email: "b@x.com"),
        ]
        let events = [event("e1")]

        let before = CollaboratorsOverview.build(policy: policy, ownedEvents: events,
                                                 shares: shares, invitations: [], resolvedNames: [:])
        #expect(before.uniquePeopleCount == 2)

        // Simulate the store removing share s2 on success and rebuilding.
        shares.removeAll { $0.id == "s2" }
        let after = CollaboratorsOverview.build(policy: policy, ownedEvents: events,
                                                shares: shares, invitations: [], resolvedNames: [:])
        #expect(after.uniquePeopleCount == 1)
        #expect(after.activeCollaboratorCount == 1)
        #expect(after.events.first?.currentCount == 1)
    }

    @Test("Remove-from-all gathers scoped share and invitation ids for one person")
    func removeFromAllScope() {
        let overview = CollaboratorsOverview.build(
            policy: policy,
            ownedEvents: [event("e1"), event("e2")],
            shares: [share("s1", event: "e1", email: "p@x.com")],
            invitations: [invite("i1", event: "e2", email: "p@x.com")],
            resolvedNames: [:])

        let person = try! #require(overview.people.first { $0.normalizedEmail == "p@x.com" })
        #expect(person.activeEntries.map(\.id) == ["s1"])
        #expect(person.pendingEntries.map(\.id) == ["i1"])
        // Each entry carries its own event id for scoped deletion.
        #expect(person.activeEntries.first?.eventId == "e1")
        #expect(person.pendingEntries.first?.eventId == "e2")
    }
}

// MARK: - Mutation filters

@Suite("Collaborator mutation filters")
struct CollaboratorMutationQueryTests {

    private func value(_ items: [URLQueryItem], _ name: String) -> String? {
        items.first { $0.name == name }?.value
    }

    @Test("Scoped filter includes both row id and event id")
    func scopedFilter() {
        let items = CollaboratorMutationQuery.scoped(rowID: "share-9", eventID: "event-3")
        #expect(value(items, "id") == "eq.share-9")
        #expect(value(items, "event_id") == "eq.event-3")
        #expect(items.count == 2)
    }

    @Test("Role update, per-event removal, and revocation all scope by both ids")
    func allMutationsScoped() {
        // Same helper backs role update (event_shares), per-event removal
        // (event_shares), and invitation revocation (event_invitations).
        for (rowID, eventID) in [("r1", "e1"), ("r2", "e2")] {
            let items = CollaboratorMutationQuery.scoped(rowID: rowID, eventID: eventID)
            #expect(value(items, "id") == "eq.\(rowID)")
            #expect(value(items, "event_id") == "eq.\(eventID)")
        }
    }
}

// MARK: - Error mapping

@Suite("Collaborator error mapping")
struct CollaboratorErrorMappingTests {

    @Test("Authentication failures ask the user to sign in again")
    func authError() {
        #expect(CollaboratorsStore.message(for: SupabaseError.notAuthenticated)
            .localizedCaseInsensitiveContains("sign in"))
        #expect(CollaboratorsStore.message(for: SupabaseError.http(status: 401, message: ""))
            .localizedCaseInsensitiveContains("sign in"))
    }

    @Test("RLS/permission failures explain owner-only access")
    func permissionError() {
        let message = CollaboratorsStore.message(for: SupabaseError.http(status: 403, message: "denied"))
        #expect(message.localizedCaseInsensitiveContains("owner"))
    }

    @Test("Missing record suggests refreshing")
    func missingRecord() {
        let message = CollaboratorsStore.message(for: SupabaseError.http(status: 404, message: ""))
        #expect(message.localizedCaseInsensitiveContains("refresh"))
    }

    @Test("Network failures map to a connection message")
    func networkError() {
        let message = CollaboratorsStore.message(for: SupabaseError.transport("offline"))
        #expect(message.localizedCaseInsensitiveContains("network")
            || message.localizedCaseInsensitiveContains("connection"))
    }
}
