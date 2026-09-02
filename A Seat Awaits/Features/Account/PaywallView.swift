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
    @State private var pendingMessage: String?
    @State private var didPurchase = false
    @State private var isRestoring = false
    @State private var showRestoreDone = false

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
        // On iPad, present as a form sheet instead of a near-fullscreen page
        // sheet — the offer cards are designed for a narrow column.
        .presentationSizing(.form)
        .task {
            // Concurrent: the product catalog must not wait behind the
            // account's Supabase round-trips.
            async let productLoad: Void = loadProductsIfNeeded()
            await account.load()
            _ = await productLoad
        }
        .alert("Purchase issue",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        // Ask to Buy is a successful deferred purchase, not an error — it
        // gets its own neutral alert.
        .alert("Purchase pending",
               isPresented: Binding(get: { pendingMessage != nil },
                                    set: { if !$0 { pendingMessage = nil } })) {
            Button("OK", role: .cancel) { pendingMessage = nil }
        } message: {
            Text(pendingMessage ?? "")
        }
    }

    /// Loads the App Store catalog unless it's already cached and healthy.
    private func loadProductsIfNeeded() async {
        guard let subscriptions,
              subscriptions.products.isEmpty || subscriptions.productLoadErrorMessage != nil else { return }
        await subscriptions.loadProducts()
    }

    // MARK: - Stripe subscribers (no purchase UI)

    /// Shown instead of any purchase UI when billing lives on the web. Neutral
    /// and non-tappable by design — no link out to an external purchase page.
    private var webBillingNotice: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe")
                .scaledFont(size: 34)
                .foregroundStyle(Brand.textSecondary)
                .accessibilityHidden(true)
            Text("Your \(policy.planDisplayName) plan is billed through our website")
                .scaledFont(size: 17, weight: .bold)
                .foregroundStyle(Brand.textPrimary)
                .multilineTextAlignment(.center)
            Text("Plan changes and billing updates are managed where you subscribed. Changes are reflected here automatically.")
                .scaledFont(size: 14)
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
                    Button {
                        Task { await subscriptions?.loadProducts() }
                    } label: {
                        HStack(spacing: 8) {
                            if subscriptions?.isLoadingProducts == true {
                                ProgressView()
                            }
                            Text("Try Again")
                        }
                    }
                    .buttonStyle(.secondaryOutline)
                    .disabled(subscriptions?.isLoadingProducts == true)
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
                .scaledFont(size: 20, weight: .bold)
                .foregroundStyle(Brand.textPrimary)
            Text("Pay once and plan your event start to finish. Your pass never expires.")
                .scaledFont(size: 13)
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
                    TitleBadgeRow {
                        Text(tier.displayName)
                            .scaledFont(size: 18, weight: .bold)
                            .foregroundStyle(Brand.textPrimary)
                    } badge: {
                        if isPopular {
                            Text("Most Popular")
                                .scaledFont(size: 10, weight: .bold)
                                .lineLimit(1)
                                .fixedSize()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Brand.accent, in: Capsule())
                        }
                    }
                    Text(tier.tagline)
                        .scaledFont(size: 13)
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(product?.displayPrice ?? "…")
                        .scaledFont(size: 20, weight: .bold)
                        .foregroundStyle(Brand.textPrimary)
                    Text("one time")
                        .scaledFont(size: 11)
                        .foregroundStyle(Brand.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                featureLine("One event, up to \(tier.guestCap.formatted()) guests")
                featureLine("Floor plan editor & drag-and-drop seating")
                if tier.aiImport {
                    featureLine("AI guest import (\(tier.aiImportLifetimeCap) imports)")
                }
                featureLine("Export & print floor plans")
                if tier.collaboration {
                    featureLine("Up to \(tier.maxCollaboratorsPerEvent) collaborators")
                }
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
                .scaledFont(size: 18, weight: .bold)
                .foregroundStyle(Brand.textPrimary)
            Text("Upgrade in place and pay only the difference. Everything you've planned stays exactly as it is.")
                .scaledFont(size: 13)
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
                        .scaledFont(size: 18, weight: .bold)
                        .foregroundStyle(Brand.textPrimary)
                    Text(tier.tagline)
                        .scaledFont(size: 13)
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(product?.displayPrice ?? "…")
                        .scaledFont(size: 20, weight: .bold)
                        .foregroundStyle(Brand.textPrimary)
                    Text("one time")
                        .scaledFont(size: 11)
                        .foregroundStyle(Brand.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                featureLine("Guest cap grows to \(tier.guestCap.formatted())")
                if tier.aiImport && !from.aiImport {
                    featureLine("Adds AI guest import (\(tier.aiImportLifetimeCap) imports)")
                }
                if tier.collaboration && !from.collaboration {
                    featureLine("Adds collaboration (up to \(tier.maxCollaboratorsPerEvent) people)")
                }
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
                    .scaledFont(size: 16, weight: .bold)
                    .foregroundStyle(Brand.textPrimary)
                Text("One subscription for planners and venues running many events.")
                    .scaledFont(size: 13)
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
                        .scaledFont(size: 18, weight: .bold)
                        .foregroundStyle(Brand.textPrimary)
                    Text(tier.tagline)
                        .scaledFont(size: 13)
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(product?.displayPrice ?? "…")
                        .scaledFont(size: 20, weight: .bold)
                        .foregroundStyle(Brand.textPrimary)
                    Text(selectedPeriod == .monthly ? "per month" : "per year")
                        .scaledFont(size: 11)
                        .foregroundStyle(Brand.textSecondary)
                }
            }

            Picker("Billing period", selection: $selectedPeriod) {
                Text("Monthly").tag(AppleBillingPeriod.monthly)
                Text("Yearly").tag(AppleBillingPeriod.annual)
            }
            .pickerStyle(.segmented)
            if selectedPeriod == .annual, let savings = annualSavings {
                Text(savings.label)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(Brand.successText)
            }

            VStack(alignment: .leading, spacing: 6) {
                featureLine(tier.limits.eventsText)
                featureLine(tier.limits.guestsText)
                featureLine("AI guest import")
                featureLine("Export & print floor plans")
                featureLine(tier.limits.collaboratorsText)
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

    /// Yearly-vs-monthly saving for Pro, derived from live App Store prices.
    /// Nil (and hidden) until both products have loaded.
    private var annualSavings: AnnualSavings? {
        AnnualSavings.compute(monthly: subscriptions?.product(for: .elite, period: .monthly)?.price,
                              annual: subscriptions?.product(for: .elite, period: .annual)?.price)
    }

    // MARK: - Shared pieces

    private func featureLine(_ label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(Brand.success)
                .accessibilityHidden(true)
            Text(label)
                .scaledFont(size: 13)
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
            pendingMessage = "Your purchase is awaiting approval (for example, Ask to Buy). It will activate automatically once it's approved."
        case .success(.cancelled):
            break
        case .failure(let error):
            errorMessage = error.message
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            Button {
                Task {
                    isRestoring = true
                    defer { isRestoring = false }
                    if let message = await subscriptions?.restorePurchases() {
                        errorMessage = message
                    } else {
                        await account.refreshBillingState()
                        showRestoreDone = true
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if isRestoring { ProgressView() }
                    Text("Restore Purchases")
                }
            }
            .buttonStyle(.secondaryOutline)
            .disabled(isRestoring)
            .alert("Restore complete", isPresented: $showRestoreDone) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your App Store purchases have been synced. If you had no previous purchases, there was nothing to restore.")
            }

            Text(footerDisclosure)
                .scaledFont(size: 11)
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 4) {
                footerLink("Terms of Use", url: AccountLinks.termsOfService)
                footerLink("Privacy Policy", url: AccountLinks.privacyPolicy)
            }
        }
        .padding(.top, 4)
    }

    /// Small legal link with a full 44pt hit target — App Review exercises
    /// these two links on the paywall.
    private func footerLink(_ title: String, url: URL) -> some View {
        Button { openURL(url) } label: {
            Text(title)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(Brand.accent)
                .padding(.horizontal, 6)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footerDisclosure: String {
        if case .upgrade = mode {
            return "Upgrades are one-time purchases applied to this event's pass. Passes never expire. Refund requests are handled by Apple."
        }
        return "Passes are one-time purchases and never expire. The Pro subscription renews automatically until canceled; cancel anytime in your App Store settings and it stays active until the end of the billing period."
    }
}
