//
//  Theme.swift
//  A Seat Awaits
//
//  Central design system, derived 1:1 from the "A Seat Awaits — iOS" design
//  spec. Brand purple #43204f, SF Pro Display (the system default — NOT
//  rounded), 20px cards, green = seated, amber = open. First-class dark mode
//  built on a slate-navy palette (#020617 / #0f172a) with a lavender accent.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Color helpers

extension Color {
    /// Non-failable hex convenience (falls back to gray for malformed input).
    static func hex(_ s: String) -> Color { Color(hex: s) ?? .gray }

    /// Resolves to `light` in light appearance and `dark` in dark appearance.
    static func dynamic(_ light: Color, _ dark: Color) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #else
        light
        #endif
    }
}

// MARK: - Cross-platform semantic backgrounds (legacy helpers, still used in a
// few places). New code should prefer the `Surface` tokens below.
extension Color {
    static var appBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
    static var appSecondaryBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .underPageBackgroundColor)
        #endif
    }
    static var appGroupedBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
    static var appSecondaryGroupedBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}

// MARK: - Brand palette

enum Brand {
    // Identity
    /// Primary deep-plum brand color (`#43204f`).
    static let plum = Color.hex("#43204f")
    /// Lighter plum used as the primary/FAB fill in dark mode (`#6A3180`).
    static let plumDark = Color.hex("#6A3180")
    /// Gradient companion to `plum` on hero surfaces (`#5B2A6B`).
    static let plumGradientEnd = Color.hex("#5B2A6B")
    /// Lavender accent — the brand line carried into dark mode (`#CDA8E6`).
    static let lilac = Color.hex("#CDA8E6")
    /// Bright violet used for avatar initials & sparkles (`#7C3AED`).
    static let purple = Color.hex("#7C3AED")

    // Status — light-mode base hex (wrapped by the scheme-resolving tokens below;
    // do not reference these directly outside this file — use Brand.successText etc).
    static let success = Color.hex("#16A34A")     // seated / assigned (dot, ring)
    private static let successTextLight = Color.hex("#15803D")  // seated text on tint
    private static let successFillLight = Color.hex("#DCFCE7")  // seated chip fill
    private static let successBorderLight = Color.hex("#BBF7D0")
    static let warning = Color.hex("#F59E0B")      // open / unassigned
    private static let warningTextLight = Color.hex("#B45309")  // amber text on tint
    private static let warningFillLight = Color.hex("#FEF3C7")  // amber chip fill
    private static let warningBorderLight = Color.hex("#FDE68A")
    private static let inviteBgLight = Color.hex("#FFFBEB")
    private static let inviteSubtitleLight = Color.hex("#92400E")
    static let danger = Color.hex("#DC2626")

    // Status — dark-mode fills/borders (chip backgrounds need a dark tint here;
    // the light hex values above are pale creams/pastels that read as
    // near-white-on-near-white once text switches to `textPrimary`'s white in
    // dark mode).
    private static let successFillDark = Color.hex("#052E16")
    private static let successBorderDark = Color.hex("#166534")
    private static let warningFillDark = Color.hex("#451A03")
    private static let warningBorderDark = Color.hex("#92400E")

    /// Muted mauve used for floor-plan seat rings (open seats / chair outlines).
    static let seatRing = Color.hex("#8C7A9C")
    /// Brighter mauve seat ring for dark-mode floor plans.
    static let seatRingDark = Color.hex("#B6A4C6")

    // Accent chip families
    static let plumChipFill = Color.hex("#F3E8FF")   // assigned-to-table chip
    static let plumChipFillSoft = Color.hex("#FAF5FF")
    static let skyText = Color.hex("#0369A1")        // household badge
    static let skyFill = Color.hex("#E0F2FE")
    static let teal = Color.hex("#0EA5A4")           // group/household icon

    // Status — dark variants (brighter for contrast on navy)
    static let successDark = Color.hex("#4ADE80")
    static let warningDark = Color.hex("#FBBF24")

    // Neutral slate ramp (light surfaces & text)
    static let ink = Color.hex("#0F172A")        // primary text (slate-900)
    static let slate600 = Color.hex("#475569")   // field labels
    static let slate500 = Color.hex("#64748B")   // body / subtitle
    static let slate400 = Color.hex("#94A3B8")   // placeholder / fine print
    static let slate300 = Color.hex("#CBD5E1")   // grabbers / disabled
    static let slate200 = Color.hex("#E2E8F0")   // borders / dividers
    static let slate100 = Color.hex("#F1F5F9")   // hairlines / track
    static let slate50 = Color.hex("#F8FAFC")    // app background (light)

    // Dark slate-navy surfaces
    static let canvasDark = Color.hex("#020617")     // root background
    static let cardDark = Color.hex("#0F172A")       // card / panel
    static let elevatedDark = Color.hex("#334155")   // selected segment / borders
    static let hairlineDark = Color.hex("#1E293B")   // borders / dividers (dark)

    // MARK: Scheme-resolving tokens (use these in views)

    /// App canvas background — slate-50 light, slate-950 dark.
    static var canvas: Color { .dynamic(slate50, canvasDark) }
    /// Card / panel surface — white light, slate-900 dark.
    static var card: Color { .dynamic(.white, cardDark) }
    /// Hairline border on cards & dividers.
    static var hairline: Color { .dynamic(slate100, hairlineDark) }
    /// Stronger separator (e.g. footer top border).
    static var separator: Color { .dynamic(slate200, hairlineDark) }
    /// Primary text.
    static var textPrimary: Color { .dynamic(ink, .white) }
    /// Secondary text.
    static var textSecondary: Color { .dynamic(slate500, slate400) }
    /// Tertiary text.
    static var textTertiary: Color { .dynamic(slate400, Color.hex("#475569")) }
    /// Field box fill.
    static var fieldFill: Color { .dynamic(.white, cardDark) }
    /// Field border.
    static var fieldBorder: Color { .dynamic(slate200, elevatedDark) }
    /// Subtle filled control (search, segment track).
    static var control: Color { .dynamic(slate100, hairlineDark) }
    /// Brand accent that flips to lavender in dark mode.
    static var accent: Color { .dynamic(plum, lilac) }
    /// Primary action fill (plum → lighter plum in dark).
    static var primaryFill: Color { .dynamic(plum, plumDark) }
    /// Progress-ring track.
    static var ringTrack: Color { .dynamic(slate100, hairlineDark) }
    /// Floor-plan smart-alignment guide line (pink, mirrors the web canvas).
    static var alignmentGuide: Color { .dynamic(Color.hex("#DB2777"), Color.hex("#F472B6")) }
    /// Floor-plan collision/overlap warning outline (red).
    static var collisionStroke: Color { .dynamic(Color.hex("#DC2626"), Color.hex("#F87171")) }
    /// Seated/success chip text — brightens for contrast in dark mode.
    static var successText: Color { .dynamic(successTextLight, successDark) }
    /// Seated/success chip fill.
    static var successFill: Color { .dynamic(successFillLight, successFillDark) }
    /// Seated/success chip border.
    static var successBorder: Color { .dynamic(successBorderLight, successBorderDark) }
    /// Open/warning chip text — brightens for contrast in dark mode.
    static var warningText: Color { .dynamic(warningTextLight, warningDark) }
    /// Open/warning chip fill.
    static var warningFill: Color { .dynamic(warningFillLight, warningFillDark) }
    /// Open/warning chip border.
    static var warningBorder: Color { .dynamic(warningBorderLight, warningBorderDark) }
    /// Highlighted/"review" row background (invite banners, AI-import flags).
    static var inviteBg: Color { .dynamic(inviteBgLight, warningFillDark) }
    /// Text on `inviteBg`.
    static var inviteSubtitle: Color { .dynamic(inviteSubtitleLight, warningDark) }

    // Gradients
    /// Back-compat light-mode hero gradient.
    static var heroGradient: LinearGradient { heroGradient(.light) }
    static func heroGradient(_ scheme: ColorScheme = .light) -> LinearGradient {
        let stops: [Color] = scheme == .dark
            ? [Color.hex("#2A1333"), Color.hex("#3D1C49")]
            : [plum, plumGradientEnd]
        // 165° ≈ from top to bottom-trailing.
        return LinearGradient(colors: stops,
                              startPoint: .top,
                              endPoint: .bottomTrailing)
    }
}

// MARK: - Hero background (plum surface + restrained orbs)

/// Plum hero surface with restrained lavender + pink orb glows. Used on splash,
/// auth and the guest-facing Find Your Table search.
struct HeroBackground: View {
    var body: some View {
        ZStack {
            Brand.plum
            Circle()
                .fill(Brand.lilac.opacity(0.45))
                .frame(width: 340, height: 340)
                .blur(radius: 80)
                .offset(x: -120, y: -200)
            Circle()
                .fill(Color.hex("#EC4899").opacity(0.28))
                .frame(width: 320, height: 320)
                .blur(radius: 90)
                .offset(x: 130, y: 180)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Card surface

/// Card surface: 20px radius, white/slate-900 fill, a hairline border (needed in
/// dark mode where shadows vanish) and a soft shadow in light mode.
struct BrandCard: ViewModifier {
    var radius: CGFloat = 20
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background(Brand.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Brand.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06),
                    radius: 12, x: 0, y: 4)
    }
}

extension View {
    func brandCard(radius: CGFloat = 20) -> some View { modifier(BrandCard(radius: radius)) }
}

// MARK: - Button styles

/// Filled primary CTA — 56pt tall, 16px radius, plum (lighter in dark), shadow.
struct PrimaryButtonStyle: ButtonStyle {
    var isLoading: Bool = false
    var height: CGFloat = 56
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Brand.primaryFill)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Brand.plum.opacity(scheme == .dark ? 0 : 0.5),
                    radius: 13, x: 0, y: 12)
            .opacity(configuration.isPressed || isLoading ? 0.8 : 1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primaryBrand: PrimaryButtonStyle { PrimaryButtonStyle() }
}

/// Outlined secondary button — white/clear fill, 1.5px plum border, plum text.
struct SecondaryOutlineButtonStyle: ButtonStyle {
    var height: CGFloat = 52
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Brand.accent, lineWidth: 1.5))
            .foregroundStyle(Brand.accent)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

extension ButtonStyle where Self == SecondaryOutlineButtonStyle {
    static var secondaryOutline: SecondaryOutlineButtonStyle { SecondaryOutlineButtonStyle() }
}

/// White pill button used on plum hero surfaces.
struct WhiteButtonStyle: ButtonStyle {
    var height: CGFloat = 56
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(Brand.plum)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 15, x: 0, y: 10)
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

extension ButtonStyle where Self == WhiteButtonStyle {
    static var whiteHero: WhiteButtonStyle { WhiteButtonStyle() }
}
