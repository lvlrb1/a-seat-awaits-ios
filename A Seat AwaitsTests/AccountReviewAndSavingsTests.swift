//
//  AccountReviewAndSavingsTests.swift
//  A Seat AwaitsTests
//
//  Pure logic behind two account-adjacent touches: the once-per-version rating
//  prompt gate and the paywall's derived yearly-savings line.
//

import Foundation
import Testing
@testable import A_Seat_Awaits

@Suite("Rating prompt gate")
struct ReviewPromptGateTests {

    @Test("Prompts once per version, then never again for that version")
    func oncePerVersion() {
        #expect(ReviewPromptGate.shouldPrompt(lastPromptedVersion: nil, currentVersion: "1.2"))
        #expect(!ReviewPromptGate.shouldPrompt(lastPromptedVersion: "1.2", currentVersion: "1.2"))
        #expect(ReviewPromptGate.shouldPrompt(lastPromptedVersion: "1.1", currentVersion: "1.2"))
    }

    @Test("An unknown version never prompts")
    func unknownVersion() {
        #expect(!ReviewPromptGate.shouldPrompt(lastPromptedVersion: nil, currentVersion: ""))
    }

    @Test("Rate row hides until the App Store ID is filled in")
    func rateRowHiddenWhileEmpty() {
        if AppStoreIDs.appleID.isEmpty {
            #expect(AppStoreIDs.writeReviewURL == nil)
        } else {
            #expect(AppStoreIDs.writeReviewURL?.absoluteString
                    == "https://apps.apple.com/app/id\(AppStoreIDs.appleID)?action=write-review")
        }
    }
}

@Suite("Yearly savings line")
struct AnnualSavingsTests {

    @Test("Ten months' worth reads as two months free")
    func twoMonthsFree() {
        let savings = AnnualSavings.compute(monthly: 9.99, annual: 99.90)
        #expect(savings == .monthsFree(2))
        #expect(savings?.label == "2 months free with yearly billing")
    }

    @Test("A rounded yearly price still counts whole months when it's close")
    func roundedYearly() {
        // 99.99 vs 9.99 × 12 = 119.88 → 1.99 months free → "2 months free".
        #expect(AnnualSavings.compute(monthly: 9.99, annual: 99.99) == .monthsFree(2))
    }

    @Test("Non-whole savings read as a percentage")
    func percentage() {
        // 12 × 10 = 120; 105 saves 12.5% (1.5 months, not a whole number).
        let savings = AnnualSavings.compute(monthly: 10, annual: 105)
        #expect(savings == .percent(13))
        #expect(savings?.label == "Save 13% with yearly billing")
    }

    @Test("No line when prices are missing or yearly isn't cheaper")
    func hidden() {
        #expect(AnnualSavings.compute(monthly: nil, annual: 99) == nil)
        #expect(AnnualSavings.compute(monthly: 10, annual: nil) == nil)
        #expect(AnnualSavings.compute(monthly: 10, annual: 120) == nil)
        #expect(AnnualSavings.compute(monthly: 10, annual: 130) == nil)
        #expect(AnnualSavings.compute(monthly: 0, annual: 50) == nil)
    }

    @Test("A single month free is worded in the singular")
    func singular() {
        #expect(AnnualSavings.monthsFree(1).label == "1 month free with yearly billing")
    }
}
