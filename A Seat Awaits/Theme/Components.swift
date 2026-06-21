//
//  Components.swift
//  A Seat Awaits
//
//  Reusable design-system views shared across screens: progress ring & bar,
//  tag/status pills, filter chips, initials avatars, search field, labeled
//  inputs, custom segmented control, floating action button, sheet header and
//  the "LIVE" collaboration badge. All derived from the iOS design spec.
//

import SwiftUI

// MARK: - Initials

enum Initials {
    /// Up to two uppercase initials from a person's name.
    static func from(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "&" })
            .map(String.init)
            .filter { !$0.isEmpty }
        let letters = parts.prefix(2).compactMap { $0.first }
        let s = String(letters).uppercased()
        return s.isEmpty ? "?" : s
    }
}

/// Circular avatar with initials, tinted deterministically from a seed string.
struct InitialsAvatar: View {
    let name: String
    var size: CGFloat = 42
    /// Optional explicit seed (else the name is used) so partners can share a hue.
    var seed: String? = nil

    /// Pastel bg / saturated fg pairs from the design spec.
    static let palette: [(bg: String, fg: String)] = [
        ("#FCE7F3", "#BE185D"),
        ("#E0F2FE", "#0369A1"),
        ("#DCFCE7", "#15803D"),
        ("#FEF3C7", "#B45309"),
        ("#FAE8FF", "#A21CAF"),
        ("#F3E8FF", "#7C3AED"),
    ]

    private var pair: (bg: Color, fg: Color) {
        let key = seed ?? name
        var hash = 5381
        for byte in key.utf8 { hash = (hash &* 33) ^ Int(byte) }
        let idx = abs(hash) % Self.palette.count
        let p = Self.palette[idx]
        return (.hex(p.bg), .hex(p.fg))
    }

    var body: some View {
        Circle()
            .fill(pair.bg)
            .frame(width: size, height: size)
            .overlay(
                Text(Initials.from(name))
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(pair.fg)
            )
    }
}

/// Translucent avatar for use on plum surfaces (white initials).
struct GlassAvatar: View {
    let name: String
    var size: CGFloat = 38
    var body: some View {
        Circle()
            .fill(.white.opacity(0.18))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
            .overlay(
                Text(Initials.from(name))
                    .font(.system(size: size * 0.37, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}

// MARK: - Progress

/// Circular progress ring (60pt default) with optional centered % label.
struct ProgressRing: View {
    var progress: Double            // 0...1
    var size: CGFloat = 60
    var lineWidth: CGFloat = 7
    var showsPercent: Bool = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Circle().stroke(Brand.ringTrack, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(Brand.accent,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsPercent {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: size * 0.25, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Thin gradient progress bar (footer / seated progress).
struct ProgressBar: View {
    var progress: Double
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.ringTrack)
                Capsule()
                    .fill(LinearGradient(colors: [Brand.plum, Brand.purple],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Pills & chips

/// Small rounded status pill (e.g. "43 seated", "Vegetarian", "Table 5").
struct TagPill: View {
    let text: String
    var fg: Color
    var bg: Color
    var icon: String? = nil
    var dotColor: Color? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let dotColor {
                Circle().fill(dotColor).frame(width: 7, height: 7)
            }
            if let icon {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
            }
            Text(text).font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(bg, in: Capsule())
    }

    // Convenience styles
    static func seated(_ text: String) -> TagPill { TagPill(text: text, fg: Brand.successText, bg: Brand.successFill) }
    static func open(_ text: String) -> TagPill { TagPill(text: text, fg: Brand.warningText, bg: Brand.warningFill) }
    static func assigned(_ text: String) -> TagPill { TagPill(text: text, fg: Brand.plum, bg: Brand.plumChipFill) }
    static func unassigned() -> TagPill { TagPill(text: "Unassigned", fg: Brand.warningText, bg: Brand.warningFill) }
    static func household(_ text: String) -> TagPill { TagPill(text: text, fg: Brand.skyText, bg: Brand.skyFill) }
    static func dietary(_ text: String) -> TagPill { TagPill(text: text, fg: Brand.successText, bg: Brand.successFill) }
    static func neutral(_ text: String) -> TagPill { TagPill(text: text, fg: Brand.slate600, bg: Brand.control) }
}

/// Selectable filter chip with an optional count, e.g. "All · 47".
struct FilterChip: View {
    let title: String
    var count: Int? = nil
    var selected: Bool = false
    /// fg/bg when selected; unselected uses neutral control colors.
    var selectedFg: Color = .white
    var selectedBg: Color = Brand.plum

    var label: String { count.map { "\(title) · \($0)" } ?? title }

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(selected ? selectedFg : Brand.slate600)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(selected ? selectedBg : Brand.control, in: Capsule())
    }
}

// MARK: - Search field

struct SearchField: View {
    @Binding var text: String
    var placeholder: String
    /// `onPlum` renders translucent white for use over plum headers.
    var onPlum: Bool = false
    var height: CGFloat = 46

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(onPlum ? Color.white.opacity(0.7) : Brand.slate400)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(onPlum ? Color.white.opacity(0.6) : Brand.slate400)
                }
                TextField("", text: $text)
                    .foregroundStyle(onPlum ? .white : Brand.textPrimary)
                    .tint(onPlum ? .white : Brand.plum)
            }
            .font(.system(size: 15))
        }
        .padding(.horizontal, 14)
        .frame(height: height)
        .background(
            onPlum ? AnyShapeStyle(Color.white.opacity(0.16)) : AnyShapeStyle(Brand.control),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            onPlum
                ? RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                : nil
        )
    }
}

// MARK: - Labeled input field

/// A labeled, bordered input box (54pt, 14px radius) with a plum focus ring.
struct LabeledField<Content: View>: View {
    let title: String
    var isFocused: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.slate600)
            content()
                .font(.system(size: 16))
                .foregroundStyle(Brand.textPrimary)
                .tint(Brand.plum)
                .frame(height: 54)
                .padding(.horizontal, 16)
                .background(Brand.fieldFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isFocused ? Brand.plum : Brand.fieldBorder,
                                      lineWidth: 1.5)
                )
                .overlay(
                    isFocused
                        ? RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Brand.plum.opacity(0.08), lineWidth: 3)
                            .padding(-1.5)
                        : nil
                )
        }
    }
}

// MARK: - Segmented control

/// Custom pill segmented control matching the spec (slate track, white selected
/// segment with shadow). Generic over a `CaseIterable` enum of segment titles.
struct BrandSegmentedControl: View {
    let titles: [String]
    @Binding var selection: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let segW = geo.size.width / CGFloat(max(1, titles.count))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Brand.card)
                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.12), radius: 3, y: 1)
                    .padding(3)
                    .frame(width: segW)
                    .offset(x: segW * CGFloat(selection))
                    .animation(.snappy(duration: 0.2), value: selection)
                HStack(spacing: 0) {
                    ForEach(Array(titles.enumerated()), id: \.offset) { idx, title in
                        Text(title)
                            .font(.system(size: 14, weight: selection == idx ? .bold : .semibold))
                            .foregroundStyle(selection == idx ? Brand.textPrimary : Brand.textSecondary)
                            .frame(width: segW, height: 38)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = idx }
                    }
                }
            }
        }
        .frame(height: 38)
        .background(Brand.control, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

// MARK: - Floating action button

struct FloatingButton: View {
    var icon: String = "plus"
    var title: String
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 17, weight: .heavy))
                Text(title).font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 52)
            .background(Brand.primaryFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Brand.plum.opacity(scheme == .dark ? 0.4 : 0.6), radius: 15, x: 0, y: 12)
        }
    }
}

// MARK: - Sheet header

/// Bottom-sheet header: leading "Cancel", centered title, trailing action.
struct SheetHeader: View {
    let title: String
    var cancelTitle: String = "Cancel"
    var actionTitle: String?
    var actionEnabled: Bool = true
    var onCancel: () -> Void
    var onAction: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
            HStack {
                Button(cancelTitle, action: onCancel)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                Spacer()
                if let actionTitle, let onAction {
                    Button(actionTitle, action: onAction)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(actionEnabled ? Brand.accent : Brand.slate300)
                        .disabled(!actionEnabled)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Sheet grabber handle.
struct Grabber: View {
    var body: some View {
        Capsule().fill(Brand.slate300).frame(width: 40, height: 5)
    }
}

// MARK: - Live collaboration badge

struct LiveBadge: View {
    var name: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Brand.success).frame(width: 7, height: 7)
            Text("LIVE · \(name.uppercased())")
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(Brand.successText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Brand.successFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.successBorder, lineWidth: 1))
    }
}

// MARK: - View-only (read-only collaborator) badge

/// Shown in place of the live/sort affordances when the signed-in user only has
/// viewer access to an event — a calm, unmistakable "you can't edit this" cue.
struct ViewOnlyBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye")
                .font(.system(size: 11, weight: .heavy))
            Text("VIEW ONLY")
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.6)
        }
        .foregroundStyle(Brand.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Brand.control, in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
        .accessibilityLabel("View only — you don't have permission to edit this event")
    }
}

// MARK: - Offline banner

/// A calm "you're offline" strip shown when a store can't reach the server, so a
/// dropped save reads as a connection issue rather than "the app is broken" (F10).
struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 13, weight: .bold))
            Text("You're offline — changes will sync when you reconnect.")
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Brand.warningText)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.warningFill)
        .overlay(Brand.warningBorder.frame(height: 1), alignment: .bottom)
        .accessibilityLabel("You're offline. Changes will sync when you reconnect.")
    }
}

// MARK: - Overlapping avatar stack

struct AvatarStack: View {
    let names: [String]
    var size: CGFloat = 28
    var body: some View {
        HStack(spacing: -8) {
            ForEach(Array(names.prefix(3).enumerated()), id: \.offset) { _, n in
                InitialsAvatar(name: n, size: size)
                    .overlay(Circle().strokeBorder(Brand.card, lineWidth: 2))
            }
        }
    }
}
