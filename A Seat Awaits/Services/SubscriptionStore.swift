//
//  SubscriptionStore.swift
//  A Seat Awaits
//
//  Owns everything StoreKit: the App Store product catalog (the Pro
//  subscription, the legacy subscription products kept for restores, and the
//  Event Pass consumables), the purchase flows, the lifetime transaction
//  listener, restore, and the native manage sheet.
//
//  Entitlement remains server-authoritative: every verified transaction's JWS
//  is posted to an Edge Function — `apple-iap-sync` for subscriptions,
//  `apple-pass-sync` for pass consumables — which verifies it against Apple's
//  root certificates and writes the canonical row. The app never unlocks
//  anything optimistically — the UI waits for the refreshed server snapshot.
//  A transaction is only `finish()`ed after the server accepts it. That
//  matters doubly for consumables: an unfinished consumable is redelivered
//  via `Transaction.updates`, which is the retry mechanism — finishing before
//  the server records it would lose the purchase.
//

import Foundation
import Observation
import StoreKit

/// Request body for the `apple-iap-sync` Edge Function.
private nonisolated struct AppleIapSyncRequest: Encodable, Sendable {
    let jws: String
}

/// Response from `apple-iap-sync`: the canonical subscription row after upsert.
private nonisolated struct AppleIapSyncResponse: Decodable, Sendable {
    let subscription: SubscriptionRow?
}

/// Request body for the `apple-pass-sync` Edge Function. `eventId` is nil for
/// an unattached pass (attaches to the buyer's next event at creation) and
/// required for in-place upgrades.
private nonisolated struct ApplePassSyncRequest: Encodable, Sendable {
    let jws: String
    let eventId: String?
}

/// Response from `apple-pass-sync`: the canonical pass row after the write.
private nonisolated struct ApplePassSyncResponse: Decodable, Sendable {
    let pass: EventPass?
}

/// Persists which event a pass/upgrade purchase was aimed at, keyed by product
/// id, so a purchase that fails to sync (app killed, network down) still
/// reaches the right event when `Transaction.updates` redelivers it after
/// relaunch. A base pass with no entry simply lands unattached — the DB
/// attaches it to the buyer's next event.
private nonisolated enum PassPurchaseTargets {
    private static let key = "pendingPassPurchaseTargets"

    static func set(eventId: String?, for productID: String) {
        var map = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        map[productID] = eventId
        UserDefaults.standard.set(map, forKey: key)
    }

    static func eventId(for productID: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[productID]
    }

    static func clear(for productID: String) {
        var map = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        map.removeValue(forKey: productID)
        UserDefaults.standard.set(map, forKey: key)
    }
}

@MainActor
@Observable
final class SubscriptionStore {

    private let supabase: SupabaseClient
    private let appState: AppState

    /// Loaded StoreKit products keyed by product identifier. Empty until
    /// `loadProducts()` succeeds (StoreKit caches, so retries are cheap).
    private(set) var products: [String: Product] = [:]
    private(set) var isLoadingProducts = false
    private(set) var productLoadErrorMessage: String?

    /// True from a successful purchase/restore until the server snapshot is
    /// refreshed — the paywall shows "Activating your plan…" during this window.
    private(set) var isActivating = false

    /// The product identifier currently mid-purchase (disables its button).
    private(set) var purchasingProductID: String?

    /// Bumped whenever the server acknowledged a transaction, so screens that
    /// own an `AccountStore` know to `refreshBillingState()`.
    private(set) var entitlementVersion = 0

    /// Drives `.manageSubscriptionsSheet` in the subscription summary.
    var isPresentingManageSheet = false

    /// The lifetime `Transaction.updates` listener. `nonisolated(unsafe)` so
    /// the nonisolated `deinit` can cancel it; only written from MainActor.
    @ObservationIgnored private nonisolated(unsafe) var updatesTask: Task<Void, Never>?

    init(supabase: SupabaseClient, appState: AppState) {
        self.supabase = supabase
        self.appState = appState
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Starts the transaction listener and loads the catalog. Safe to call more
    /// than once (e.g. on sign-in); the listener is only started once.
    func start() {
        if updatesTask == nil {
            updatesTask = Task { [weak self] in
                for await result in Transaction.updates {
                    await self?.handle(updated: result)
                }
            }
        }
        Task { await loadProducts() }
    }

    /// Fetches every product from the App Store: the subscription catalog
    /// (including legacy tiers, needed for restores) and the pass consumables.
    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        productLoadErrorMessage = nil
        defer { isLoadingProducts = false }
        do {
            let fetched = try await Product.products(
                for: AppleProducts.allProductIDs + PassProducts.allProductIDs)
            products = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
            if fetched.isEmpty {
                productLoadErrorMessage = "Plans aren't available right now. Please try again later."
            }
        } catch {
            productLoadErrorMessage = "Couldn't load plans. Check your connection and try again."
        }
    }

    /// The loaded product for a tier + period, if the catalog has it.
    func product(for tier: PlanTier, period: AppleBillingPeriod) -> Product? {
        products[AppleProduct(tier: tier, period: period).productID]
    }

    /// The loaded consumable for a fresh pass at a tier.
    func passProduct(for tier: PassTier) -> Product? {
        products[PassProducts.passProduct(for: tier).productID]
    }

    /// The loaded pay-the-difference upgrade consumable, if the pair is valid.
    func passUpgradeProduct(from: PassTier, to: PassTier) -> Product? {
        guard let upgrade = PassProducts.upgradeProduct(from: from, to: to) else { return nil }
        return products[upgrade.productID]
    }

    // MARK: - Purchase

    enum PurchaseOutcome: Equatable {
        case success
        case cancelled
        case pending // e.g. Ask to Buy — resolved later via Transaction.updates
    }

    struct PurchaseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Purchases a subscription product, tagging it with the Supabase user id
    /// so the server (and the App Store server notifications webhook) can
    /// attribute it.
    func purchase(_ product: Product) async -> Result<PurchaseOutcome, PurchaseError> {
        await runPurchase(product) { [weak self] verification, transaction in
            try await self?.sync(jws: verification, finishing: transaction)
        }
    }

    /// Purchases an Event Pass consumable (base pass or in-place upgrade).
    /// `eventId` targets a specific event: required for upgrades, optional for
    /// a base pass (nil buys an unattached pass that auto-attaches to the next
    /// event the buyer creates). The target survives app restarts so a failed
    /// sync retried via `Transaction.updates` still reaches the right event.
    func purchasePass(_ product: Product, eventId: String?) async -> Result<PurchaseOutcome, PurchaseError> {
        guard PassProducts.isPassProduct(product.id) else {
            return .failure(PurchaseError(message: "That product isn't an Event Pass."))
        }
        PassPurchaseTargets.set(eventId: eventId, for: product.id)
        return await runPurchase(product) { [weak self] verification, transaction in
            try await self?.syncPass(jws: verification, eventId: eventId, finishing: transaction)
            PassPurchaseTargets.clear(for: product.id)
        }
    }

    /// Shared StoreKit purchase plumbing: buys with the `.appAccountToken`
    /// attribution, then hands the verified JWS to `onVerified` (which must
    /// sync server-side and finish the transaction, throwing on failure).
    private func runPurchase(
        _ product: Product,
        onVerified: @MainActor (String, Transaction) async throws -> Void
    ) async -> Result<PurchaseOutcome, PurchaseError> {
        guard purchasingProductID == nil else { return .success(.pending) }
        guard let userIdString = appState.currentUserId,
              let userUUID = UUID(uuidString: userIdString) else {
            return .failure(PurchaseError(message: "Please sign in to make a purchase."))
        }
        purchasingProductID = product.id
        defer { purchasingProductID = nil }

        do {
            let result = try await product.purchase(options: [.appAccountToken(userUUID)])
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    do {
                        try await onVerified(verification.jwsRepresentation, transaction)
                        return .success(.success)
                    } catch {
                        // The transaction stays unfinished; StoreKit redelivers
                        // it via Transaction.updates, so the purchase isn't lost.
                        return .failure(PurchaseError(message: Self.syncFailureMessage(for: error)))
                    }
                case .unverified:
                    return .failure(PurchaseError(
                        message: "The App Store receipt couldn't be verified. Please try again."))
                }
            case .userCancelled:
                return .success(.cancelled)
            case .pending:
                return .success(.pending)
            @unknown default:
                return .success(.pending)
            }
        } catch {
            return .failure(PurchaseError(message: "The purchase couldn't be completed. Please try again."))
        }
    }

    // MARK: - Restore & re-sync

    /// Restores purchases (App Store account sync) then re-syncs entitlements.
    /// Returns a user-facing error message, or nil on success.
    func restorePurchases() async -> String? {
        do {
            try await AppStore.sync()
        } catch {
            // AppStore.sync() throws when the user cancels the App Store
            // sign-in prompt; treat that as a no-op rather than an error.
            return nil
        }
        return await syncCurrentEntitlements(force: true)
    }

    /// Re-syncs the current App Store entitlement to the server when it
    /// disagrees with the server-side subscription row. Called on launch and
    /// foreground; a no-op for users with no App Store subscription.
    /// Returns a user-facing error message, or nil.
    @discardableResult
    func syncCurrentEntitlements(serverRow: SubscriptionRow? = nil, force: Bool = false) async -> String? {
        var latest: (jws: String, transaction: Transaction)?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  AppleProducts.parse(transaction.productID) != nil else { continue }
            if latest == nil || transaction.purchaseDate > latest!.transaction.purchaseDate {
                latest = (result.jwsRepresentation, transaction)
            }
        }
        guard let latest else { return nil }
        if !force, let serverRow, Self.serverMatches(serverRow, transaction: latest.transaction) {
            return nil
        }
        do {
            try await sync(jws: latest.jws, finishing: nil)
            return nil
        } catch {
            return Self.syncFailureMessage(for: error)
        }
    }

    /// True when the server row already reflects this App Store transaction,
    /// so no re-sync is needed.
    private static func serverMatches(_ row: SubscriptionRow, transaction: Transaction) -> Bool {
        guard row.provider == "apple", row.appleProductId == transaction.productID else { return false }
        guard let expiration = transaction.expirationDate,
              let periodEndISO = row.currentPeriodEnd,
              let periodEnd = AuthUser.parseISO(periodEndISO) else { return false }
        return abs(periodEnd.timeIntervalSince(expiration)) < 60
    }

    // MARK: - Transaction plumbing

    /// Handles a transaction delivered by `Transaction.updates` (renewals,
    /// Ask-to-Buy approvals, purchases from App Store settings, retries of
    /// transactions we couldn't sync earlier — including unfinished pass
    /// consumables, which StoreKit redelivers until they're finished).
    private func handle(updated result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        if AppleProducts.parse(transaction.productID) != nil {
            try? await sync(jws: result.jwsRepresentation, finishing: transaction)
        } else if PassProducts.isPassProduct(transaction.productID) {
            // Recover the intended event (if any) from the persisted target;
            // a base pass without one simply syncs unattached.
            let eventId = PassPurchaseTargets.eventId(for: transaction.productID)
            do {
                try await syncPass(jws: result.jwsRepresentation,
                                   eventId: eventId,
                                   finishing: transaction)
                PassPurchaseTargets.clear(for: transaction.productID)
            } catch {
                // Stays unfinished; StoreKit will redeliver and we'll retry.
            }
        }
    }

    /// Posts the signed transaction to `apple-iap-sync`; finishes it only after
    /// the server accepts (2xx). Bumps `entitlementVersion` so screens refresh.
    private func sync(jws: String, finishing transaction: Transaction?) async throws {
        isActivating = true
        defer { isActivating = false }
        _ = try await supabase.invokeFunction(
            "apple-iap-sync",
            body: AppleIapSyncRequest(jws: jws),
            as: AppleIapSyncResponse.self)
        if let transaction {
            await transaction.finish()
        }
        entitlementVersion += 1
    }

    /// Posts a pass consumable's signed transaction to `apple-pass-sync`;
    /// finishes it only after the server records the pass (2xx). An unfinished
    /// consumable is redelivered via `Transaction.updates`, so a lost network
    /// call never loses the purchase.
    private func syncPass(jws: String, eventId: String?, finishing transaction: Transaction?) async throws {
        isActivating = true
        defer { isActivating = false }
        _ = try await supabase.invokeFunction(
            "apple-pass-sync",
            body: ApplePassSyncRequest(jws: jws, eventId: eventId),
            as: ApplePassSyncResponse.self)
        if let transaction {
            await transaction.finish()
        }
        entitlementVersion += 1
    }

    /// Maps a sync failure to a friendly message; surfaces the server's safe
    /// message for expected conflicts (409 Stripe-active, 403 wrong account).
    private static func syncFailureMessage(for error: Error) -> String {
        if let edge = error as? EdgeFunctionError,
           case .http(_, let message, _, _) = edge, !message.isEmpty {
            return message
        }
        return "Your purchase went through, but we couldn't activate it yet. It will retry automatically."
    }
}
