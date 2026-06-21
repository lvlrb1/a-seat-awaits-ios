//
//  SubscriptionSummaryView.swift
//  A Seat Awaits
//
//  A native billing summary built entirely from locally available Supabase
//  subscription state. The app never calls Stripe's secret API, mutates
//  subscriptions, fabricates invoices, or claims a cancellation succeeded before
//  Stripe confirms it. Billing changes (manage, payment method, invoices,
//  resume, resolve) open the secure hosted billing page. State is refreshed when
//  the app returns to the foreground (handled in the parent).
//
//  No prices are shown: there is no authoritative StoreKit catalog or secure
//  billing source in the app, so price display would be misleading.
//

import SwiftUI

struct SubscriptionSummaryView: View {
    @Bindable var store: AccountStore
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    private var snapshot: AccountSnapshot? { store.snapshot }
    private var policy: PlanPolicy { snapshot?.policy ?? .free }
    private var subscription: SubscriptionRow? { snapshot?.subscription }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                planCard
                if policy.isAccessReducedByStatus || policy.status.hasPaymentIssue {
                    paymentWarning
                }
                datesCard
                featuresCard
                billingActionsCard
                if !policy.isTopTier && AccountLinks.externalUpgradeEnabled {
                    upgradeCard
                }
                disclaimer
            }
            .padding(18)
        }
        .background(Brand.canvas.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .navigationTitle("Plan & Billing")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refreshBillingState() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refreshBillingState() } }
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
        return "Your \(policy.planDisplayName) plan isn't active right now, so Free limits apply. Manage billing to restore it."
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

    private var billingActionsCard: some View {
        VStack(spacing: 0) {
            billingRow(icon: "creditcard", title: "Manage Subscription")
            AccountRowDivider()
            billingRow(icon: "wallet.pass", title: "Update Payment Method")
            AccountRowDivider()
            billingRow(icon: "doc.plaintext", title: "View Invoices")
            if subscription?.isCanceling == true {
                AccountRowDivider()
                billingRow(icon: "arrow.clockwise.circle", title: "Resume Subscription")
            }
            if policy.status.hasPaymentIssue {
                AccountRowDivider()
                billingRow(icon: "exclamationmark.triangle", title: "Resolve Payment Issue", tint: Brand.warning)
            }
        }
        .brandCard(radius: 16)
    }

    private func billingRow(icon: String, title: String, tint: Color = Brand.accent) -> some View {
        Button {
            openURL(AccountLinks.billing)
        } label: {
            AccountRowLabel(icon: icon, title: title, tint: tint, showsChevron: true)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the secure billing page in your browser")
    }

    // MARK: - Upgrade

    private var upgradeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(policy.isFree ? "Upgrade for more" : "Compare plans")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
            Text("See every plan and what it unlocks on the web.")
                .font(.system(size: 13))
                .foregroundStyle(Brand.textSecondary)
            Button("View Plans") { openURL(AccountLinks.upgrade) }
                .buttonStyle(.secondaryOutline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    private var disclaimer: some View {
        Text("Billing is securely managed by Stripe. Changes you make there are reflected here automatically.")
            .font(.system(size: 12))
            .foregroundStyle(Brand.slate400)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .padding(.top, 4)
    }
}
