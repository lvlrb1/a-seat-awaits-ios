//
//  SubscriptionSummaryView.swift
//  A Seat Awaits
//
//  A native billing summary built entirely from locally available Supabase
//  subscription state. The app never calls Stripe's secret API, mutates
//  subscriptions, fabricates invoices, or claims a cancellation succeeded before
//  the billing provider confirms it. App Store subscriptions are managed through
//  the native manage-subscriptions sheet; Stripe subscriptions show neutral,
//  non-tappable text (no external purchase links — App Review guideline 3.1.1).
//  Upgrades and new subscriptions go through the native StoreKit paywall.
//
//  Three account shapes, mirroring the web /subscription page:
//  - Paid subscriber: plan card + status + dates + plan features.
//  - Legacy Free (users.legacy_free): grandfathered early members who keep the
//    old Free plan (1 event, 25 guests) — shown with a thank-you note.
//  - Everyone else: there is no free plan. They buy one-time Event Passes per
//    event (or go Pro) and always have collaborator access to shared events.
//

import StoreKit
import SwiftUI

struct SubscriptionSummaryView: View {
    @Bindable var store: AccountStore
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase

    @State private var isPresentingManageSheet = false
    @State private var isPresentingPaywall = false

    private var snapshot: AccountSnapshot? { store.snapshot }
    private var policy: PlanPolicy { snapshot?.policy ?? .free }
    private var subscription: SubscriptionRow? { snapshot?.subscription }
    private var provider: BillingProvider { snapshot?.billingProvider ?? .none }

    /// Which of the three account shapes this screen is describing.
    private enum Presentation { case paid, legacyFree, payPerEvent }

    private var presentation: Presentation {
        if !policy.isFree { return .paid }
        return snapshot?.isLegacyFree == true ? .legacyFree : .payPerEvent
    }

    var body: some View {
        ScrollView {
            if snapshot == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else {
                VStack(spacing: 16) {
                    switch presentation {
                    case .paid:
                        paidPlanCard
                        if policy.isAccessReducedByStatus || policy.status.hasPaymentIssue {
                            paymentWarning
                        }
                        datesCard
                        passesCard
                        featuresCard
                        billingActionsCard
                        if !policy.isTopTier && snapshot?.hasActiveStripeBilling != true {
                            upgradeCard
                        }
                        disclaimer
                    case .legacyFree:
                        legacyFreeCard
                        passesCard
                        featuresCard
                        upgradeCard
                    case .payPerEvent:
                        payPerEventCard
                        passesCard
                        howPassesWorkCard
                    }
                }
                .padding(18)
                .readableWidth(Layout.contentWidth)
            }
        }
        .background(Brand.canvas.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .navigationTitle("Plan & Billing")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refreshBillingState() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await appState.subscriptionStore?
                        .syncCurrentEntitlements(serverRow: subscription)
                    await store.refreshBillingState()
                }
            }
        }
        .onChange(of: appState.subscriptionStore?.entitlementVersion ?? 0) {
            Task { await store.refreshBillingState() }
        }
        .manageSubscriptionsSheet(isPresented: $isPresentingManageSheet)
        .sheet(isPresented: $isPresentingPaywall, onDismiss: {
            Task { await store.refreshBillingState() }
        }) {
            if let supabase = appState.supabase {
                PaywallView(supabase: supabase, appState: appState)
            }
        }
    }

    // MARK: - Plan header (paid subscriber)

    private var paidPlanCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(policy.planDisplayName) plan")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    Text(policy.nominalTier.tagline)
                        .font(.system(size: 14))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                StatusBadge(status: policy.status)
            }

            if subscription?.isCanceling == true {
                Label("Cancels at the end of the current period", systemImage: "calendar.badge.exclamationmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.warningText)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    // MARK: - Plan header (legacy Free)

    /// Grandfathered early members keep the old Free plan. This is the only
    /// account shape that still has a "Free plan" — say so warmly and clearly.
    private var legacyFreeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text("Free plan")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                Spacer()
                pill("EARLY MEMBER")
            }
            Text("As a thank-you for being an early member, your Free plan is yours to keep at no cost — 1 event with up to 25 guests.")
                .font(.system(size: 14))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    // MARK: - Plan header (pay per event)

    /// No subscription and not grandfathered: the account has no plan of its
    /// own. Events are paid for one at a time with Event Passes.
    private var payPerEventCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text("Pay as you go")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                Spacer()
            }
            Text("No subscription needed. Buy a one-time Event Pass for each event you plan — or go Pro if you plan events for a living.")
                .font(.system(size: 14))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("View Passes & Pro") { isPresentingPaywall = true }
                .buttonStyle(.secondaryOutline)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    private var paymentWarning: some View {
        FeedbackBanner(kind: .error, message: warningMessage)
    }

    private var warningMessage: String {
        if policy.status.hasPaymentIssue {
            return "There's a problem with your payment (\(policy.status.displayName.lowercased())). Resolve it to keep your plan's features."
        }
        return "Your \(policy.planDisplayName) plan isn't active right now, so its features are paused."
    }

    // MARK: - Dates

    @ViewBuilder
    private var datesCard: some View {
        let rows = dateRows
        if !rows.isEmpty {
            AccountCardGroup {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { AccountRowDivider(inset: 16) }
                    HStack {
                        Text(row.label)
                            .font(.system(size: 15))
                            .foregroundStyle(Brand.textSecondary)
                        Spacer()
                        Text(row.value)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Brand.textPrimary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
        }
    }

    private var dateRows: [(label: String, value: String)] {
        guard let sub = subscription else { return [] }
        var rows: [(String, String)] = []
        if policy.status == .trialing, let trial = AccountDate.medium(sub.trialEnd) {
            rows.append(("Trial ends", trial))
        }
        if let end = AccountDate.medium(sub.currentPeriodEnd) {
            if sub.isCanceling {
                rows.append(("Access until", end))
            } else if policy.status == .active || policy.status == .trialing {
                rows.append(("Renews on", end))
            }
        }
        if policy.status == .canceled, let canceled = AccountDate.medium(sub.canceledAt) {
            rows.append(("Canceled on", canceled))
        }
        return rows
    }

    // MARK: - Event Passes

    /// One row per owned pass, each telling its own story: which event it
    /// covers, or that it's waiting for the next event the user creates.
    @ViewBuilder
    private var passesCard: some View {
        if let passes = snapshot?.passes, !passes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your passes")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(passes.enumerated()), id: \.element.id) { index, pass in
                        if index > 0 {
                            Divider().padding(.vertical, 10)
                        }
                        passRow(pass)
                    }
                }

                Text("A pass never expires — it covers one event for good.")
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.slate400)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .brandCard()
        }
    }

    private func passRow(_ pass: EventPass) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "ticket")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(pass.isActive ? Brand.accent : Brand.slate300)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(pass.tierDisplayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
                Text(passStatusLine(pass))
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(passDetailLine(pass))
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.slate400)
            }
            Spacer(minLength: 8)
            passBadge(pass)
        }
    }

    /// The one sentence that explains this pass's state in plain words.
    private func passStatusLine(_ pass: EventPass) -> String {
        guard pass.isActive else {
            return "Refunded — no longer covers an event."
        }
        if pass.isAttached {
            if let name = pass.attachedEventName {
                return "Covering “\(name)”."
            }
            return "Covering one of your events."
        }
        return "Attaches automatically to the next event you create."
    }

    private func passDetailLine(_ pass: EventPass) -> String {
        var parts: [String] = ["Up to \(pass.guestCap.formatted()) guests"]
        if let purchased = AccountDate.medium(pass.purchasedAt) {
            parts.append("purchased \(purchased)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func passBadge(_ pass: EventPass) -> some View {
        if pass.isActive {
            if pass.isAttached {
                pill("IN USE", fg: Brand.accent, bg: Brand.accent.opacity(0.12))
            } else {
                pill("READY", fg: Brand.successText, bg: Brand.successFill)
            }
        } else {
            pill("REFUNDED")
        }
    }

    private func pill(_ text: String,
                      fg: Color = Brand.textSecondary,
                      bg: Color = Brand.control) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(fg)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(bg, in: Capsule())
    }

    // MARK: - Features / limits (paid + legacy Free)

    private var featuresCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Your plan includes")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(policy.nominalFeatures) { feature in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: feature.included ? "checkmark.circle.fill" : "minus.circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(feature.included ? Brand.success : Brand.slate300)
                            .frame(width: 18)
                        Text(feature.label)
                            .font(.system(size: 14))
                            .foregroundStyle(feature.included ? Brand.textPrimary : Brand.textSecondary)
                        Spacer(minLength: 0)
                    }
                }
            }

            if presentation == .paid || presentation == .legacyFree,
               !(snapshot?.activePasses.isEmpty ?? true) {
                Text("Events covered by an Event Pass get that pass's limits on top of your plan.")
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.slate400)
            }

            if policy.isAccessReducedByStatus {
                Text("Free limits apply until your subscription is active again.")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.warningText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    // MARK: - How passes work (pay per event)

    /// Replaces the plan-features checklist for accounts that have no plan:
    /// three plain sentences that explain the whole model.
    private var howPassesWorkCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How it works")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)

            VStack(alignment: .leading, spacing: 12) {
                howItWorksRow(icon: "ticket",
                              text: "One pass covers one event, from an intimate dinner to a 500-guest wedding. It never expires.")
                howItWorksRow(icon: "calendar.badge.plus",
                              text: "A Ready pass attaches automatically to the next event you create — no extra step.")
                howItWorksRow(icon: "person.2",
                              text: "Events shared with you are always free to join as a collaborator.")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    private func howItWorksRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Brand.accent)
                .frame(width: 20)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Brand.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Billing actions

    /// App Store subscribers manage everything through the native sheet; Stripe
    /// subscribers see neutral text only (no link out); Free users see nothing.
    @ViewBuilder
    private var billingActionsCard: some View {
        switch provider {
        case .apple:
            VStack(spacing: 0) {
                Button {
                    isPresentingManageSheet = true
                } label: {
                    AccountRowLabel(icon: "creditcard", title: "Manage Subscription",
                                    tint: Brand.accent, showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens your App Store subscription settings")
            }
            .brandCard(radius: 16)
        case .stripe:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.slate400)
                    Text("Billed through our website")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                }
                Text("Your subscription is managed where you subscribed. Plan and billing changes made there are reflected here automatically.")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .brandCard(radius: 16)
        case .none:
            EmptyView()
        }
    }

    // MARK: - Upgrade

    private var upgradeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(policy.isFree ? "Plan a bigger event" : "Compare options")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
            Text(policy.isFree
                 ? "Want more guests, AI import, or collaboration? Pick up a one-time Event Pass, or go Pro if you plan events for a living."
                 : "Buy a one-time Event Pass, or go Pro if you plan events for a living.")
                .font(.system(size: 13))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("View Passes & Pro") { isPresentingPaywall = true }
                .buttonStyle(.secondaryOutline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    @ViewBuilder
    private var disclaimer: some View {
        switch provider {
        case .apple:
            Text("Billing is securely managed by Apple. Changes you make in your App Store settings are reflected here automatically.")
                .font(.system(size: 12))
                .foregroundStyle(Brand.slate400)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .padding(.top, 4)
        case .stripe:
            Text("Billing changes are reflected here automatically.")
                .font(.system(size: 12))
                .foregroundStyle(Brand.slate400)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .padding(.top, 4)
        case .none:
            EmptyView()
        }
    }
}
