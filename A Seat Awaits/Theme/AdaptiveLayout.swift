//
//  AdaptiveLayout.swift
//  A Seat Awaits
//
//  iPad-adaptive layout helpers. The app is designed phone-first; on a compact
//  horizontal size class (iPhone, narrow split view) every helper here is a
//  no-op, so the existing phone layout is untouched. On a regular size class
//  (iPad, wide split view) they cap content to a readable measure and center
//  it, and expose column counts for card grids — so screens read as designed
//  for iPad instead of a phone layout stretched edge-to-edge.
//

import SwiftUI

// MARK: - Measures

enum Layout {
    /// Single-column forms and reading content (auth, account cards, sheets).
    static let formWidth: CGFloat = 480
    /// A single reading column of cards (detail "More" tab, summaries).
    static let contentWidth: CGFloat = 640
    /// Multi-column card surfaces (events dashboard, paywall).
    static let wideContentWidth: CGFloat = 940

    /// Column count for a card grid at the given size class, clamped so cards
    /// never get too narrow. Compact width always stays single-column.
    static func cardColumns(_ sizeClass: UserInterfaceSizeClass?) -> Int {
        sizeClass == .regular ? 2 : 1
    }
}

// MARK: - Readable width

extension View {
    /// Caps content to `width` and centers it horizontally when the size class
    /// is regular (iPad). No-op on compact width, preserving the phone layout.
    ///
    /// Apply to the content column *inside* a `ScrollView`/`List` row — not to
    /// full-bleed backgrounds or hero headers, which should stay edge-to-edge.
    func readableWidth(_ width: CGFloat = Layout.formWidth) -> some View {
        modifier(ReadableWidthModifier(width: width))
    }
}

private struct ReadableWidthModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let width: CGFloat

    func body(content: Content) -> some View {
        if sizeClass == .regular {
            content
                .frame(maxWidth: width)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}

// MARK: - Size-class convenience

extension EnvironmentValues {
    /// True when laid out at a regular horizontal size class (iPad / wide
    /// split view). A small readability shorthand over `horizontalSizeClass`.
    var isRegularWidth: Bool { horizontalSizeClass == .regular }
}
