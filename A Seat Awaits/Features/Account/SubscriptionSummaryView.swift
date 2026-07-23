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

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                planCard
                if policy.isAccessReducedByStatus || policy.status.hasPaymentIssue {
                    paymentWarning
                }
                datesCard
                if !(snapshot?.passes.isEmpty ?? true) {
                    passesCard
                }
                featuresCard
                billingActionsCard
                if !policy.isTopTier && snapshot?.hasActiveStripeBilling != true {
                    upgradeCard
                }
                disclaimer
            }
            .padding(18)
            .readableWidth(Layout.contentWidth)
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

    // MARK: - Plan header

    private var planCard: some View {
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
                if subscription != nil || !policy.isFree {
                    StatusBadge(status: policy.status)
                }
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

    private var paymentWarning: some View {
        FeedbackBanner(kind: .error, message: warningMessage)
    }

    private var warningMessage: String {
        if policy.status.hasPaymentIssue {
            return "There's a problem with your payment (\(policy.status.displayName.lowercased())). Resolve it to keep your plan's features."
        }
        return "Your \(policy.planDisplayName) plan isn't active right now, so Free limits apply."
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

    /// The user's Event Passes: attached passes cover their event for life;
    /// unattached ones are spent automatically on the next event created.
    private var passesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Event Passes")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(snapshot?.passes ?? []) { pass in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "ticket")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(pass.isActive ? Brand.accent : Brand.slate300)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pass.tierDisplayName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Brand.textPrimary)
                            Text(passSubtitle(pass))
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.textSecondary)
                        }
                        Spacer(minLength: 0)
                        Text(pass.isActive ? (pass.isAttached ? "In use" : "Ready") : "Refunded")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(pass.isActive ? Brand.success : Brand.danger)
                    }
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

    private func passSubtitle(_ pass: EventPass) -> String {
        var parts: [String] = ["Up to \(pass.guestCap.formatted()) guests"]
        if !pass.isAttached && pass.isActive {
            parts.append("attaches to your next event")
        }
        if let purchased = AccountDate.medium(pass.purchasedAt) {
            parts.append("purchased \(purchased)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Features / limits

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
            Text(policy.isFree ? "Plan your event" : "Compare options")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
            Text("Buy a one-time Event Pass, or go Pro if you plan events for a living.")
                .font(.system(size: 13))
                .foregroundStyle(Brand.textSecondary)
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
