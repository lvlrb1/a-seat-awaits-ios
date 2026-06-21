//
//  AccountLogicTests.swift
//  A Seat AwaitsTests
//
//  Unit tests for the pure Account business logic: plan tier normalization,
//  per-tier limits, status entitlement, input validation, and CSV escaping.
//  No network or UI is exercised.
//

import Testing
import Foundation
@testable import A_Seat_Awaits

// MARK: - Tier normalization

@Test func planTierNormalizesHistoricalSpellings() {
    #expect(PlanTier.normalize("free") == .free)
    #expect(PlanTier.normalize("core") == .core)
    #expect(PlanTier.normalize("basic") == .essentials)
    #expect(PlanTier.normalize("essentials") == .essentials)
    #expect(PlanTier.normalize("pro") == .signature)
    #expect(PlanTier.normalize("signature") == .signature)
    #expect(PlanTier.normalize("elite") == .elite)
    // Case/whitespace tolerant, unknown → free.
    #expect(PlanTier.normalize("  PRO ") == .signature)
    #expect(PlanTier.normalize(nil) == .free)
    #expect(PlanTier.normalize("nonsense") == .free)
}

@Test func planTierDisplayNames() {
    #expect(PlanTier.free.displayName == "Free")
    #expect(PlanTier.core.displayName == "Core")
    #expect(PlanTier.essentials.displayName == "Essentials")
    #expect(PlanTier.signature.displayName == "Signature")
    #expect(PlanTier.elite.displayName == "Elite")
}

// MARK: - Limits

@Test func tierLimitsMatchProductDefinition() {
    #expect(PlanTier.free.limits.maxEvents == 1)
    #expect(PlanTier.free.limits.maxGuestsPerEvent == 25)
    #expect(PlanTier.free.limits.aiImport == false)
    #expect(PlanTier.free.limits.collaboration == false)

    #expect(PlanTier.core.limits.maxEvents == 1)
    #expect(PlanTier.core.limits.maxGuestsPerEvent == 50)
    #expect(PlanTier.core.limits.exportAndPrint == false)

    #expect(PlanTier.essentials.limits.maxEvents == 3)
    #expect(PlanTier.essentials.limits.maxGuestsPerEvent == 150)
    #expect(PlanTier.essentials.limits.aiImport == true)
    #expect(PlanTier.essentials.limits.exportAndPrint == true)
    #expect(PlanTier.essentials.limits.collaboration == false)
    #expect(PlanTier.essentials.limits.publicSharing == false)

    #expect(PlanTier.signature.limits.maxEvents == 10)
    #expect(PlanTier.signature.limits.maxGuestsPerEvent == 500)
    #expect(PlanTier.signature.limits.publicSharing == true)
    #expect(PlanTier.signature.limits.collaboration == true)
    #expect(PlanTier.signature.limits.maxCollaboratorsPerEvent == 2)

    #expect(PlanTier.elite.limits.maxEvents == 100)
    #expect(PlanTier.elite.limits.maxGuestsPerEvent == 1000)
    #expect(PlanTier.elite.limits.maxCollaboratorsPerEvent == 5)
}

// MARK: - Status entitlement

@Test func onlyActiveOrTrialingAreEntitled() {
    #expect(SubscriptionStatus.active.isEntitled)
    #expect(SubscriptionStatus.trialing.isEntitled)
    for status: SubscriptionStatus in [.pastDue, .canceled, .incomplete, .incompleteExpired, .unpaid, .paused, .unknown] {
        #expect(!status.isEntitled, "\(status) should not be entitled")
    }
}

@Test func statusFromParsesBackendValues() {
    #expect(SubscriptionStatus.from("active") == .active)
    #expect(SubscriptionStatus.from("past_due") == .pastDue)
    #expect(SubscriptionStatus.from("incomplete_expired") == .incompleteExpired)
    #expect(SubscriptionStatus.from(nil) == .unknown)
    #expect(SubscriptionStatus.from("garbage") == .unknown)
}

@Test func paymentIssueStatuses() {
    #expect(SubscriptionStatus.pastDue.hasPaymentIssue)
    #expect(SubscriptionStatus.unpaid.hasPaymentIssue)
    #expect(SubscriptionStatus.incomplete.hasPaymentIssue)
    #expect(!SubscriptionStatus.active.hasPaymentIssue)
    #expect(!SubscriptionStatus.canceled.hasPaymentIssue)
}

// MARK: - Policy effective tier

@Test func lapsedPaidPlanFallsBackToFreeAccess() {
    let policy = PlanPolicy(nominalTier: .signature, status: .pastDue)
    #expect(policy.planDisplayName == "Signature")   // nominal name preserved
    #expect(policy.effectiveTier == .free)            // access reduced
    #expect(policy.limits.maxEvents == 1)
    #expect(policy.isAccessReducedByStatus)
    #expect(!policy.canExportAndPrint)
}

@Test func activePaidPlanGetsItsEntitlements() {
    let policy = PlanPolicy(nominalTier: .elite, status: .active)
    #expect(policy.effectiveTier == .elite)
    #expect(policy.limits.maxEvents == 100)
    #expect(!policy.isAccessReducedByStatus)
    #expect(policy.canExportAndPrint)
}

@Test func resolvePrefersSubscriptionOverUsersFallback() {
    let sub = SubscriptionRow(plan: "pro", status: "active", stripePriceId: nil,
                              currentPeriodStart: nil, currentPeriodEnd: nil,
                              cancelAtPeriodEnd: false, canceledAt: nil, trialEnd: nil,
                              createdAt: nil, updatedAt: nil)
    let policy = PlanPolicy.resolve(subscription: sub, fallbackTier: "free", fallbackStatus: "canceled")
    #expect(policy.nominalTier == .signature)
    #expect(policy.status == .active)

    let fallback = PlanPolicy.resolve(subscription: nil, fallbackTier: "elite", fallbackStatus: "trialing")
    #expect(fallback.nominalTier == .elite)
    #expect(fallback.status == .trialing)
}

// MARK: - Validation

@Test func nameValidationTrimsAndRejects() {
    #expect(AccountValidation.validateName("  Bri Foster ") == .success("Bri Foster"))
    #expect(AccountValidation.validateName("   ") == .failure(.empty))
    let long = String(repeating: "a", count: AccountValidation.maxNameLength + 1)
    #expect(AccountValidation.validateName(long) == .failure(.tooLong(AccountValidation.maxNameLength)))
}

@Test func emailValidationNormalizesAndChecks() {
    #expect(AccountValidation.validateEmail(" New@Example.com ", current: "old@example.com") == .success("new@example.com"))
    #expect(AccountValidation.validateEmail("not-an-email", current: nil) == .failure(.invalid))
    #expect(AccountValidation.validateEmail("", current: nil) == .failure(.empty))
    #expect(AccountValidation.validateEmail("me@x.com", current: "ME@X.COM") == .failure(.unchanged))
}

@Test func passwordValidationEnforcesRules() {
    // Result<Void, _> isn't Equatable (Void isn't), so match the cases.
    func failure(_ r: Result<Void, AccountValidation.PasswordError>) -> AccountValidation.PasswordError? {
        if case .failure(let e) = r { return e }
        return nil
    }
    func isSuccess(_ r: Result<Void, AccountValidation.PasswordError>) -> Bool {
        if case .success = r { return true }
        return false
    }
    #expect(failure(AccountValidation.validatePassword(current: "", new: "abcdefgh", confirm: "abcdefgh")) == .missingCurrent)
    #expect(failure(AccountValidation.validatePassword(current: "old", new: "short", confirm: "short")) == .tooShort(AccountValidation.minPasswordLength))
    #expect(failure(AccountValidation.validatePassword(current: "old", new: "abcdefgh", confirm: "different")) == .mismatch)
    #expect(isSuccess(AccountValidation.validatePassword(current: "old", new: "abcdefgh", confirm: "abcdefgh")))
}

// MARK: - CSV escaping

@Test func csvEscapingQuotesWhenNeeded() {
    #expect(GuestListExporter.csvEscape("Alice") == "Alice")
    #expect(GuestListExporter.csvEscape("Smith, Jr.") == "\"Smith, Jr.\"")
    #expect(GuestListExporter.csvEscape("She said \"hi\"") == "\"She said \"\"hi\"\"\"")
    #expect(GuestListExporter.csvEscape("line1\nline2") == "\"line1\nline2\"")
}

@Test func sanitizeProducesSafeFilenames() {
    #expect(GuestListExporter.sanitize("Anna & Ben's Wedding!") == "Anna___Ben_s_Wedding_")
    #expect(GuestListExporter.sanitize("") == "event")
}
