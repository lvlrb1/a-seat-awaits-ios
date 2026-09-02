//
//  ThemeContrastTests.swift
//  A Seat AwaitsTests
//
//  WCAG 2.x contrast checks for every palette pair the design system puts text
//  on. Guards the accessibility pass: a future "just a shade lighter" tweak
//  that drops below AA fails here instead of in App Review.
//

import Foundation
import Testing
@testable import A_Seat_Awaits

@Suite("Theme contrast (WCAG AA)")
struct ThemeContrastTests {

    private let aaText = 4.5
    private let aaLarge = 3.0

    @Test("Contrast helper matches the WCAG reference values")
    func helperReference() {
        #expect(abs(ContrastRatio.between("#000000", "#FFFFFF") - 21) < 0.01)
        #expect(abs(ContrastRatio.between("#FFFFFF", "#FFFFFF") - 1) < 0.001)
        // Symmetric.
        #expect(ContrastRatio.between("#64748B", "#FFFFFF") == ContrastRatio.between("#FFFFFF", "#64748B"))
        // Blending white text at 50% over black lands mid-grey.
        #expect(ContrastRatio.blend("#FFFFFF", over: "#000000", alpha: 0.5) == "#808080")
    }

    @Test("Tertiary text clears AA in both schemes")
    func tertiaryText() {
        // Light: slate-500 on white and on the slate-50 canvas.
        #expect(ContrastRatio.between(BrandHex.slate500, BrandHex.white) >= aaText)
        #expect(ContrastRatio.between(BrandHex.slate500, BrandHex.slate50) >= aaText)
        // Dark: slate-400 on the card and canvas.
        #expect(ContrastRatio.between(BrandHex.slate400, BrandHex.cardDark) >= aaText)
        #expect(ContrastRatio.between(BrandHex.slate400, BrandHex.canvasDark) >= aaText)
    }

    @Test("slate-400 is not a body-text color on light surfaces")
    func slate400IsDecorativeOnly() {
        // Documents why views use Brand.textSecondary instead.
        #expect(ContrastRatio.between(BrandHex.slate400, BrandHex.white) < aaLarge)
    }

    @Test("Status chip text clears AA on its fill")
    func statusChips() {
        #expect(ContrastRatio.between(BrandHex.warningTextLight, BrandHex.warningFillLight) >= aaText)
        #expect(ContrastRatio.between(BrandHex.warningTextDark, BrandHex.warningFillDark) >= aaText)
        #expect(ContrastRatio.between(BrandHex.successTextLight, BrandHex.successFillLight) >= aaText)
        #expect(ContrastRatio.between(BrandHex.successTextDark, BrandHex.successFillDark) >= aaText)
        #expect(ContrastRatio.between(BrandHex.skyText, BrandHex.skyFill) >= aaText)
        #expect(ContrastRatio.between(BrandHex.inviteSubtitleLight, BrandHex.inviteBgLight) >= aaText)
        #expect(ContrastRatio.between(BrandHex.plum, BrandHex.plumChipFill) >= aaText)
    }

    @Test("Every initials-avatar pair clears AA")
    func avatarPalette() {
        for pair in InitialsAvatar.palette {
            #expect(ContrastRatio.between(pair.fg, pair.bg) >= aaText, "\(pair.fg) on \(pair.bg)")
        }
    }

    @Test("Disabled sheet-header action stays at least 3:1")
    func disabledSheetAction() {
        // SheetHeader dims Brand.textSecondary to 80% for the disabled action.
        let light = ContrastRatio.blend(BrandHex.slate500, over: BrandHex.white, alpha: 0.8)
        let dark = ContrastRatio.blend(BrandHex.slate400, over: BrandHex.cardDark, alpha: 0.8)
        #expect(ContrastRatio.between(light, BrandHex.white) >= aaLarge)
        #expect(ContrastRatio.between(dark, BrandHex.cardDark) >= aaLarge)
    }
}
