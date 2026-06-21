//
//  AccountComponents.swift
//  A Seat Awaits
//
//  Reusable building blocks shared across the Manage Account screens: the grouped
//  settings card, settings rows (button & navigation), the subscription status
//  badge, section headers, and an inline success/error banner. All derived from
//  the existing Brand design system.
//

import SwiftUI

// MARK: - Grouped settings card

/// White rounded card grouping a vertical stack of rows.
struct AccountCardGroup<Content: View>: View {
    var radius: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .brandCard(radius: radius)
    }
}

/// Hairline divider inset to align under a row's text (past the leading icon).
struct AccountRowDivider: View {
    var inset: CGFloat = 49
    var body: some View {
        Divider().overlay(Brand.hairline).padding(.leading, inset)
    }
}

// MARK: - Section header

struct AccountSectionHeader: View {
    let title: String
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Brand.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }
}

// MARK: - Row label (shared visual)

/// The visual content of a settings row, shared by button rows and navigation
/// links. Supports an optional subtitle, trailing value text, a badge, and a
/// chevron.
struct AccountRowLabel: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var tint: Color = Brand.accent
    var titleColor: Color? = nil
    var showsChevron: Bool = true
    var badge: String? = nil
    var badgeTint: BadgeTint = .warning

    enum BadgeTint { case warning, success, danger }

    private var badgeColors: (fg: Color, bg: Color) {
        switch badgeTint {
        case .warning: return (Brand.warningText, Brand.warningFill)
        case .success: return (Brand.successText, Brand.successFill)
        case .danger: return (Brand.danger, Brand.danger.opacity(0.12))
        }
    }

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(titleColor ?? (tint == Brand.danger ? Brand.danger : Brand.textPrimary))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let value {
                Text(value)
                    .font(.system(size: 15))
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
            }

            if let badge {
                Text(badge)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(badgeColors.fg)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(badgeColors.bg, in: Capsule())
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Brand.slate300)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .contentShape(Rectangle())
    }
}

// MARK: - Button row

struct AccountButtonRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var tint: Color = Brand.accent
    var showsChevron: Bool = true
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AccountRowLabel(icon: icon, title: title, subtitle: subtitle, value: value,
                            tint: tint, showsChevron: showsChevron, badge: badge)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Status badge

struct StatusBadge: View {
    let status: SubscriptionStatus

    private var colors: (fg: Color, bg: Color) {
        switch status.semantic {
        case .good: return (Brand.successText, Brand.successFill)
        case .warning: return (Brand.warningText, Brand.warningFill)
        case .bad: return (Brand.danger, Brand.danger.opacity(0.12))
        case .neutral: return (Brand.textSecondary, Brand.control)
        }
    }

    var body: some View {
        Text(status.displayName.uppercased())
            .font(.system(size: 11, weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(colors.fg)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(colors.bg, in: Capsule())
            .accessibilityLabel("Subscription status: \(status.displayName)")
    }
}

// MARK: - Inline feedback banner

/// A transient success/error banner used inside the account sub-screens.
struct FeedbackBanner: View {
    enum Kind { case success, error, info }
    let kind: Kind
    let message: String

    private var colors: (fg: Color, bg: Color, icon: String) {
        switch kind {
        case .success: return (Brand.successText, Brand.successFill, "checkmark.circle.fill")
        case .error: return (Brand.danger, Brand.danger.opacity(0.12), "exclamationmark.triangle.fill")
        case .info: return (Brand.accent, Brand.accent.opacity(0.10), "info.circle.fill")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: colors.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(colors.fg)
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(colors.fg)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Hero header

/// The plum hero used at the top of the Account tab: title, white avatar with
/// plum initials, name and email.
struct AccountHeroHeader: View {
    let name: String
    let email: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .top) {
            Brand.heroGradient(scheme)
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(RadialGradient(colors: [Brand.lilac.opacity(0.35), .clear],
                                             center: .center, startRadius: 0, endRadius: 120))
                        .frame(width: 240, height: 240)
                        .offset(x: -50, y: -80)
                }
                .clipped()

            VStack(spacing: 0) {
                Text("Account")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 8)

                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 84, height: 84)
                        .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 12)
                    Text(Initials.from(name))
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Brand.plum)
                }
                .padding(.top, 18)

                Text(name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 12)

                if let email {
                    Text(email)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 2)
                }
            }
            .padding(.top, 56)
            .padding(.bottom, 64)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
