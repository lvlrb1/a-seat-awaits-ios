//
//  AccountView.swift
//  A Seat Awaits
//
//  Account & plans: profile, current subscription, upgrade entry point, and
//  sign out. Billing changes happen on the web (Stripe), so upgrade opens the
//  site; the app reflects the resulting tier.
//

import SwiftUI

struct AccountView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    @State private var profile: UserProfile?
    @State private var isLoading = false
    @State private var showingUpgrade = false

    private static let billingURL = URL(string: "https://aseatawaits.com/account")!

    private var displayName: String {
        profile?.fullName ?? appState.currentUser?.displayName ?? "Planner"
    }

    private var email: String? {
        appState.currentUser?.email
    }

    private var initials: String {
        Initials.from(displayName)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    VStack(spacing: 14) {
                        currentPlanCard
                        accountActionsGroup
                        supportGroup
                        footer
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
            }
            .background(Brand.canvas.ignoresSafeArea())
            .scrollIndicators(.hidden)
            .toolbar(.hidden, for: .navigationBar)
            .ignoresSafeArea(edges: .top)
            .task { await loadProfile() }
            .refreshable { await loadProfile() }
            .sheet(isPresented: $showingUpgrade) {
                UpgradeView(currentTier: profile?.subscriptionTier,
                            tierLabel: profile?.tierLabel ?? "Free")
            }
        }
    }

    // MARK: Header

    private var header: some View {
        ZStack(alignment: .top) {
            Brand.heroGradient(scheme)
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Brand.lilac.opacity(0.35), .clear],
                                center: .center, startRadius: 0, endRadius: 120)
                        )
                        .frame(width: 240, height: 240)
                        .offset(x: -50, y: -80)
                }
                .clipped()

            VStack(spacing: 0) {
                Text("Account")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 8)

                // White avatar with plum initials (inverted vs. pastel InitialsAvatar).
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 84, height: 84)
                        .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 12)
                    Text(initials)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Brand.plum)
                }
                .padding(.top, 18)

                Text(displayName)
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

    // MARK: Current plan card

    private var currentPlanCard: some View {
        Button {
            showingUpgrade = true
        } label: {
            HStack(spacing: 13) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Brand.plum, Brand.purple],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 46, height: 46)
                    .overlay(
                        Image(systemName: "flag.checkered")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("\(profile?.tierLabel ?? "Free") plan")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Brand.textPrimary)
                    }
                    Text("Up to 5 events · live collaboration")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.textSecondary)
                }

                Spacer(minLength: 8)

                Text("Manage")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Brand.accent)
            }
            .padding(16)
            .brandCard(radius: 18)
        }
        .buttonStyle(.plain)
        .offset(y: -36)
        .padding(.bottom, -36)
    }

    // MARK: Action groups

    private var accountActionsGroup: some View {
        CardGroup {
            AccountRow(icon: "creditcard", title: "Billing & invoices") {
                openURL(Self.billingURL)
            }
            Divider().overlay(Brand.hairline).padding(.leading, 49)
            AccountRow(icon: "person.2", title: "Collaborators") {
                openURL(Self.billingURL)
            }
            Divider().overlay(Brand.hairline).padding(.leading, 49)
            AccountRow(icon: "square.and.arrow.up", title: "Export guest lists") {
                openURL(Self.billingURL)
            }
        }
    }

    private var supportGroup: some View {
        CardGroup {
            AccountRow(icon: "questionmark.circle", title: "Help & support") {
                openURL(Self.billingURL)
            }
            Divider().overlay(Brand.hairline).padding(.leading, 49)
            AccountRow(icon: "rectangle.portrait.and.arrow.right",
                       title: "Log out",
                       tint: Brand.danger,
                       showsChevron: false) {
                Task { await appState.signOut() }
            }
        }
    }

    private var footer: some View {
        Text("Core & Essentials also available · Cancel anytime")
            .font(.system(size: 13))
            .foregroundStyle(Brand.slate400)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
    }

    // MARK: Data

    private func loadProfile() async {
        guard let supabase = appState.supabase,
              let userId = appState.currentUser?.id else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let rows = try await supabase.select(
                "users",
                query: [
                    URLQueryItem(name: "select", value: "id,full_name,subscription_tier,subscription_status"),
                    URLQueryItem(name: "id", value: "eq.\(userId)"),
                ],
                as: [UserProfile].self
            )
            profile = rows.first
        } catch {
            // Non-fatal: Account still shows session info.
        }
    }
}

// MARK: - Card group container

/// White rounded card grouping a vertical stack of rows (spec: 16px radius).
private struct CardGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .brandCard(radius: 16)
    }
}

// MARK: - Account settings row

private struct AccountRow: View {
    let icon: String
    let title: String
    var tint: Color = Brand.accent
    var showsChevron: Bool = true
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20)

                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint == Brand.danger ? Brand.danger : Brand.textPrimary)

                Spacer(minLength: 8)

                if let badge {
                    Text(badge)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Brand.warningText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Brand.warningFill, in: Capsule())
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
        .buttonStyle(.plain)
    }
}

// MARK: - Upgrade / plan comparison

/// Plan comparison + upgrade entry point. Checkout itself is handled on the web.
struct UpgradeView: View {
    let currentTier: String?
    var tierLabel: String = "Free"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    /// 0 = Monthly, 1 = Yearly.
    @State private var billingPeriod = 0

    private static let checkoutURL = URL(string: "https://aseatawaits.com/account")!

    private struct Plan {
        let name: String
        let tagline: String
        /// Representative monthly price; yearly is derived at ~20% off.
        let monthly: Int
        let features: [String]
    }

    // Tier identities preserved: Essentials / Core / Elite.
    private let plans: [Plan] = [
        Plan(name: "Essentials", tagline: "For a single celebration",
             monthly: 9,
             features: ["1 event · up to 100 guests", "Floor plan + list view"]),
        Plan(name: "Core", tagline: "For planners with a few events",
             monthly: 24,
             features: ["Up to 5 events · 1,000 guests",
                        "Live collaboration",
                        "AI import & QR lookup"]),
        Plan(name: "Elite", tagline: "Agencies & unlimited events",
             monthly: 59,
             features: ["Unlimited events & seats",
                        "Team roles & priority support"]),
    ]

    private func isCurrent(_ plan: Plan) -> Bool {
        guard let currentTier else { return false }
        return plan.name.lowercased() == currentTier.lowercased()
    }

    /// Displayed monthly-equivalent price (yearly = ~20% off, rounded).
    private func price(_ plan: Plan) -> Int {
        billingPeriod == 0 ? plan.monthly : Int((Double(plan.monthly) * 0.8).rounded())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(plans, id: \.name) { plan in
                        if isCurrent(plan) {
                            currentCard(plan)
                        } else {
                            otherCard(plan)
                        }
                    }

                    Text("Core & Essentials also available · Cancel anytime")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.slate400)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                .padding(18)
            }
            .background(Brand.canvas.ignoresSafeArea())
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) { stickyHeader }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: Sticky header + toggle

    private var stickyHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Brand.accent)
                }
                Spacer()
                Text("Choose your plan")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                Spacer()
                // Balance the leading chevron.
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .bold)).opacity(0)
            }
            .frame(height: 40)

            periodToggle
                .frame(width: 230)
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .background(Brand.card)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Brand.hairline).frame(height: 1)
        }
    }

    private var periodToggle: some View {
        HStack(spacing: 0) {
            toggleSegment(title: "Monthly", index: 0, showBadge: false)
            toggleSegment(title: "Yearly", index: 1, showBadge: true)
        }
        .padding(3)
        .frame(height: 38)
        .background(Brand.control, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func toggleSegment(title: String, index: Int, showBadge: Bool) -> some View {
        let selected = billingPeriod == index
        return Button {
            withAnimation(.snappy(duration: 0.2)) { billingPeriod = index }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: selected ? .bold : .semibold))
                    .foregroundStyle(selected ? Brand.textPrimary : Brand.textSecondary)
                if showBadge {
                    Text("-20%")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Brand.successText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Brand.successFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Brand.card)
                        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.12), radius: 3, y: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Plan cards

    private func currentCard(_ plan: Plan) -> some View {
        ZStack(alignment: .topTrailing) {
            // Lavender orb glow.
            Circle()
                .fill(
                    RadialGradient(colors: [Brand.lilac.opacity(0.35), .clear],
                                   center: .center, startRadius: 0, endRadius: 80)
                )
                .frame(width: 160, height: 160)
                .offset(x: 40, y: -50)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(plan.name)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                            Text("CURRENT")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(Brand.plum)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Brand.lilac, in: Capsule())
                        }
                        Text(plan.tagline)
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.lilac)
                    }
                    Spacer()
                    priceLabel(plan, light: true)
                }

                VStack(alignment: .leading, spacing: 9) {
                    ForEach(plan.features, id: \.self) { feature in
                        featureRow(feature, checkColor: Brand.lilac, textColor: .white)
                    }
                }
                .padding(.top, 14)
            }
            .padding(18)
        }
        .background(Brand.plum, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Brand.plum.opacity(scheme == .dark ? 0 : 0.45), radius: 24, x: 0, y: 14)
    }

    private func otherCard(_ plan: Plan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(plan.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    Text(plan.tagline)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.textSecondary)
                }
                Spacer()
                priceLabel(plan, light: false)
            }

            VStack(alignment: .leading, spacing: 9) {
                ForEach(plan.features, id: \.self) { feature in
                    featureRow(feature, checkColor: Brand.success, textColor: Brand.textPrimary)
                }
            }
            .padding(.top, 14)

            Button {
                openURL(Self.checkoutURL)
            } label: {
                Text("Upgrade to \(plan.name)")
            }
            .buttonStyle(.secondaryOutline)
            .padding(.top, 14)
        }
        .padding(18)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Brand.separator, lineWidth: 1.5)
        )
    }

    private func priceLabel(_ plan: Plan, light: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("$\(price(plan))")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(light ? .white : Brand.textPrimary)
            Text("/mo")
                .font(.system(size: 13))
                .foregroundStyle(light ? Color.white.opacity(0.7) : Brand.slate400)
        }
    }

    private func featureRow(_ text: String, checkColor: Color, textColor: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(checkColor)
                .frame(width: 17)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(textColor)
            Spacer(minLength: 0)
        }
    }
}
