//
//  ScaledFont.swift
//  A Seat Awaits
//
//  Dynamic Type for the brand's point-sized system fonts.
//
//  The design system specifies exact point sizes (`.font(.system(size: 17,
//  weight: .bold))`), which SwiftUI never scales with the user's text size
//  setting. `scaledFont` keeps those sizes as the baseline (Large) and
//  multiplies them by the body text style's Dynamic Type ratio, so every label
//  grows and shrinks with the system setting while the visual hierarchy
//  between sizes is preserved.
//
//  The root view caps the range at `.accessibility1` (about 1.65x): fixed-
//  height controls and single-line rows still fit at that size, whereas the
//  larger accessibility sizes would need dedicated layouts.
//

import SwiftUI

struct ScaledSystemFont: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

extension View {
    /// A system font that follows Dynamic Type while keeping the brand's point
    /// size as its baseline. Drop-in replacement for
    /// `.font(.system(size:weight:design:))`.
    func scaledFont(size: CGFloat,
                    weight: Font.Weight = .regular,
                    design: Font.Design = .default) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, design: design))
    }
}

extension DynamicTypeSize {
    /// The largest text size the app's layouts are tuned for.
    static let appMaximum: DynamicTypeSize = .accessibility1
}
