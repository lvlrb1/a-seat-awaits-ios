//
//  PaywallView.swift
//  A Seat Awaits
//
//  The native paywall for the July 2026 pricing model. Event Passes are the
//  primary offer — three one-time pass cards (Standard highlighted) — with the
//  single Pro subscription beneath, for planners running many events. Legacy
//  subscription tiers (Core/Essentials/Signature) are grandfathered and never
//  shown for sale. In upgrade mode, the paywall offers only the in-place
//  pay-the-difference upgrades above an event's current pass tier.
//
//  Prices come from the App Store catalog (`Product.displayPrice`) — never
//  hard-coded. Compliance rules are enforced HERE, in one place, so no entry
//  point can get them wrong: users with an active Stripe (web) subscription
//  never see purchase UI — only neutral, non-tappable text (App Review
//  guideline 3.1.1). The footer carries the auto-renewal disclosure and the
//  Terms of Use / Privacy Policy links Apple requires for subscriptions.
//

import StoreKit
import SwiftUI

struct PaywallView: View {
    /// What this presentation is selling.
    nonisolated enum Mode: Equatable, Sendable {
        /// The full offer: passes first, the Pro subscription beneath. When
        /// `eventId` is set, a purchased pass attaches to that event;
        /// otherwise it's bought unattached and auto-attaches to the buyer's
        /// next event.
        case plans(eventId: String?)
        /// In-place upgrade of an event's existing pass: only the tiers above
        /// `from` are offered, at the pay-the-difference price.
        case upgrade(eventId: String, from: PassTier)
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var account: AccountStore
    @State private var selectedPeriod: AppleBillingPeriod = .monthly
    @State private var errorMessage: String?
    @State private var didPurchase = false

    private let mode: Mode

    init(supabase: SupabaseClient, appState: AppState, mode: Mode = .plans(eventId: nil)) {
        _account = State(initialValue: AccountStore(supabase: supabase, appState: appState))
        self.mode = mode
    }

    private var subscriptions: SubscriptionStore? { appState.subscriptionStore }
    private var snapshot: AccountSnapshot? { account.snapshot }
    private var policy: PlanPolicy { snapshot?.policy ?? .free }

    private var navigationTitle: String {
        if case .upgrade = mode { return "Upgrade Your Pass" }
        return "Choose Your Pass"
    }

    var body: some View {
        NavigationStack {
            Group {
                if !account.hasLoaded {
                    ProgressView("Loading plans…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if snapshot?.hasActiveStripeBilling == true {
                    webBillingNotice
                } else {
                    offerList
                }
            }
            .background(Brand.canvas.ignoresSafeArea())
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            await account.load()
            if let subscriptions, subscriptions.products.isEmpty {
                await subscriptions.loadProducts()
            }
        }
        .alert("Purchase issue",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Stripe subscribers (no purchase UI)

    /// Shown instead of any purchase UI when billing lives on the web. Neutral
    /// and non-tappable by design — no link out to an external purchase page.
    private var webBillingNotice: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: 34))
                .foregroundStyle(Brand.slate300)
            Text("Your \(policy.planDisplayName) plan is billed through our website")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
                .multilineTextAlignment(.center)
            Text("Plan changes and billing updates are managed where you subscribed. Changes are reflected here automatically.")
                .font(.system(size: 14))
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Offers

    private var offerList: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let message = subscriptions?.productLoadErrorMessage {
                    FeedbackBanner(kind: .error, message: message)
                }
                if subscriptions?.isActivating == true {
                    FeedbackBanner(kind: .info, message: "Activating your purchase…")
                }

                switch mode {
                case .plans(let eventId):
                    passIntro
                    ForEach(PassTier.allCases, id: \.self) { tier in
                        passCard(for: tier, eventId: eventId)
                    }
                    proSection
                case .upgrade(let eventId, let from):
                    upgradeIntro(from: from)
                    ForEach(from.upgradeTargets, id: \.self) { tier in
                        upgradeCard(from: from, to: tier, eventId: eventId)
                    }
                }

                footer
            }
            .padding(18)
            .readableWidth(Layout.contentWidth)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Pass cards

    private var passIntro: some View {
        VStack(spacing: 6) {
            Text("One pass, one event")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
            Text("Pay once and plan your event start to finish. Your pass never expires.")
                .font(.system(size: 13))
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func passCard(for tier: PassTier, eventId: String?) -> some View {
        let product = subscriptions?.passProduct(for: tier)
        let isPopular = tier == .standard
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(tier.displayName)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Brand.textPrimary)
                        if isPopular {
                            Text("Most Popular")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Brand.accent, in: Capsule())
                        }
                    }
                    Text(tier.tagline)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(product?.displayPrice ?? "—")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    Text("one time")
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                featureLine("One event, up to \(tier.guestCap.formatted()) guests")
                featureLine("Floor plan editor & drag-and-drop seating")
                if tier.aiImport { featureLine("AI guest import") }
                featureLine("Export & print floor plans")
                if tier.collaboration {
                    featureLine("Up to \(tier.maxCollaboratorsPerEvent) collaborators")
                }
                if tier.eventSharing { featureLine("Event sharing") }
            }

            purchaseButton(product: product, title: "Buy \(tier.displayName)") { product in
                await purchasePass(product, eventId: eventId)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
        .overlay {
            if isPopular {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Brand.accent.opacity(0.5), lineWidth: 1.5)
            }
        }
    }

    // MARK: - Upgrade cards

    private func upgradeIntro(from: PassTier) -> some View {
        VStack(spacing: 6) {
            Text("This event has a \(from.displayName)")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
            Text("Upgrade in place — pay only the difference. Everything you've planned stays exactly as it is.")
                .font(.system(size: 13))
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func upgradeCard(from: PassTier, to tier: PassTier, eventId: String) -> some View {
        let product = subscriptions?.passUpgradeProduct(from: from, to: tier)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tier.displayName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    Text(tier.tagline)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(product?.displayPrice ?? "—")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    Text("one time")
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                featureLine("Guest cap grows to \(tier.guestCap.formatted())")
                if tier.aiImport && !from.aiImport { featureLine("Adds AI guest import") }
                if tier.collaboration && !from.collaboration {
                    featureLine("Adds collaboration (up to \(tier.maxCollaboratorsPerEvent) people)")
                }
                if tier.eventSharing && !from.eventSharing { featureLine("Adds event sharing") }
            }

            purchaseButton(product: product, title: "Upgrade to \(tier.shortName)") { product in
                await purchasePass(product, eventId: eventId)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    // MARK: - Pro subscription

    /// Whether the signed-in user already holds the entitled Pro subscription
    /// through the App Store (nothing further to sell them here).
    private var hasApplePro: Bool {
        guard snapshot?.billingProvider == .apple, policy.status.isEntitled,
              let productID = snapshot?.subscription?.appleProductId,
              let current = AppleProducts.parse(productID) else { return false }
        return current.tier == .elite
    }

    private var proSection: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Planning events for a living?")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                Text("One subscription for planners and venues running many events.")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 10)

            proCard
        }
    }

    private var proCard: some View {
        let tier = PlanTier.elite
        let product = subscriptions?.product(for: tier, period: selectedPeriod)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tier.displayName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    Text(tier.tagline)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(product?.displayPrice ?? "—")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    Text(selectedPeriod == .monthly ? "per month" : "per year")
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.textSecondary)
                }
            }

            Picker("Billing period", selection: $selectedPeriod) {
                Text("Monthly").tag(AppleBillingPeriod.monthly)
                Text("Yearly").tag(AppleBillingPeriod.annual)
            }
            .pickerStyle(.segmented)
            if selectedPeriod == .annual {
                Text("2 months free with yearly billing")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.success)
            }

            VStack(alignment: .leading, spacing: 6) {
                featureLine(tier.limits.eventsText)
                featureLine(tier.limits.guestsText)
                featureLine("AI guest import")
                featureLine("Export & print floor plans")
                featureLine(tier.limits.collaboratorsText)
                featureLine("Event sharing")
            }

            if hasApplePro {
                let samePeriod = AppleProducts.parse(snapshot?.subscription?.appleProductId ?? "")?.period == selectedPeriod
                purchaseButton(product: product,
                               title: samePeriod ? "Current Plan" : "Switch Billing Period",
                               disabled: samePeriod) { product in
                    await purchaseSubscription(product)
                }
            } else {
                purchaseButton(product: product, title: "Subscribe") { product in
                    await purchaseSubscription(product)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    // MARK: - Shared pieces

    private func featureLine(_ label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.success)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Brand.textPrimary)
        }
    }

    @ViewBuilder
    private func purchaseButton(product: Product?, title: String, disabled: Bool = false,
                                action: @escaping (Product) async -> Void) -> some View {
        let isPurchasing = subscriptions?.purchasingProductID != nil
        Button {
            if let product { Task { await action(product) } }
        } label: {
            HStack {
                Spacer()
                // `product == nil` must fall through to the title: comparing two
                // nils here would show an eternal spinner on an unloaded card.
                if let product, subscriptions?.purchasingProductID == product.id {
                    ProgressView()
                } else {
                    Text(title)
                }
                Spacer()
            }
        }
        .buttonStyle(.primaryBrand)
        .disabled(product == nil || disabled || isPurchasing || didPurchase)
    }

    private func purchasePass(_ product: Product, eventId: String?) async {
        guard let subscriptions else { return }
        await handleOutcome(await subscriptions.purchasePass(product, eventId: eventId))
    }

    private func purchaseSubscription(_ product: Product) async {
        guard let subscriptions else { return }
        await handleOutcome(await subscriptions.purchase(product))
    }

    private func handleOutcome(_ result: Result<SubscriptionStore.PurchaseOutcome, SubscriptionStore.PurchaseError>) async {
        switch result {
        case .success(.success):
            didPurchase = true
            await account.refreshBillingState()
            dismiss()
        case .success(.pending):
            errorMessage = "Your purchase is awaiting approval (for example, Ask to Buy). It will activate automatically once it's approved."
        case .success(.cancelled):
            break
        case .failure(let error):
            errorMessage = error.message
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            Button("Restore Purchases") {
                Task {
                    if let message = await subscriptions?.restorePurchases() {
                        errorMessage = message
                    } else {
                        await account.refreshBillingState()
                    }
                }
            }
            .buttonStyle(.secondaryOutline)

            Text(footerDisclosure)
                .font(.system(size: 11))
                .foregroundStyle(Brand.slate400)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button("Terms of Use") { openURL(AccountLinks.termsOfService) }
                Button("Privacy Policy") { openURL(AccountLinks.privacyPolicy) }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Brand.accent)
        }
        .padding(.top, 4)
    }

    private var footerDisclosure: String {
        if case .upgrade = mode {
            return "Upgrades are one-time purchases applied to this event's pass. Passes never expire; unused passes are refundable."
        }
        return "Passes are one-time purchases and never expire. The Pro subscription renews automatically until canceled; cancel anytime in your App Store settings and it stays active until the end of the billing period."
    }
}
