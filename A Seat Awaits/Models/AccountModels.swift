//
//  AccountModels.swift
//  A Seat Awaits
//
//  Value types backing the native Manage Account experience: the authoritative
//  `public.subscriptions` row, the aggregated account snapshot the UI renders,
//  the export row DTOs, and the small set of secure external destinations the
//  app may open for privileged operations (Stripe billing, account deletion).
//
//  All of these are plain `Sendable` data. Loading and mutation live in
//  `AccountStore`; formatting lives in the views.
//

import Foundation

// MARK: - Subscription row

/// The authoritative subscription state from `public.subscriptions`. Every field
/// is optional because a user may have no subscription row at all (Free).
nonisolated struct SubscriptionRow: Codable, Equatable, Sendable {
    var plan: String?
    var status: String?
    var provider: String?
    var stripePriceId: String?
    var appleProductId: String?
    var currentPeriodStart: String?
    var currentPeriodEnd: String?
    var cancelAtPeriodEnd: Bool?
    var canceledAt: String?
    var trialEnd: String?
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case plan, status, provider
        case stripePriceId = "stripe_price_id"
        case appleProductId = "apple_product_id"
        case currentPeriodStart = "current_period_start"
        case currentPeriodEnd = "current_period_end"
        case cancelAtPeriodEnd = "cancel_at_period_end"
        case canceledAt = "canceled_at"
        case trialEnd = "trial_end"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// PostgREST `select` list for this row.
    static let selectColumns =
        "plan,status,provider,stripe_price_id,apple_product_id,current_period_start,current_period_end,cancel_at_period_end,canceled_at,trial_end,created_at,updated_at"

    var isCanceling: Bool { cancelAtPeriodEnd == true }

    /// Where this subscription is billed. Missing/unknown values are treated as
    /// Stripe, the only provider that existed before the column was added.
    var billingProvider: BillingProvider {
        BillingProvider(provider: provider, plan: plan)
    }
}

// MARK: - Billing provider

/// Which payment system bills the user's subscription. Drives what the app may
/// show: App Store subscriptions get native purchase/management UI, while
/// Stripe subscriptions must not be steered to external purchase pages
/// (App Review guideline 3.1.1) — those users see neutral text instead.
nonisolated enum BillingProvider: Sendable, Equatable {
    /// No paid subscription (Free tier).
    case none
    case stripe
    case apple

    init(provider: String?, plan: String?) {
        guard PlanTier.normalize(plan) != .free else { self = .none; return }
        switch (provider ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "apple": self = .apple
        default: self = .stripe
        }
    }
}

// MARK: - Account snapshot

/// Everything the Account screens need in one immutable value: the authenticated
/// user (with provider/verification details), the `public.users` profile, and
/// the subscription. The derived `policy` centralizes tier/entitlement logic.
nonisolated struct AccountSnapshot: Equatable, Sendable {
    var authUser: AuthUser
    var profile: UserProfile?
    var subscription: SubscriptionRow?
    /// The user's Event Passes (attached and unattached), newest first.
    var passes: [EventPass] = []

    var policy: PlanPolicy {
        PlanPolicy.resolve(subscription: subscription,
                           fallbackTier: profile?.subscriptionTier,
                           fallbackStatus: profile?.subscriptionStatus)
    }

    /// Non-refunded passes (a pass never expires; only a refund revokes it).
    var activePasses: [EventPass] { passes.filter(\.isActive) }

    /// Active passes not yet attached to an event — spendable at event creation.
    var unattachedActivePasses: [EventPass] { activePasses.filter { !$0.isAttached } }

    /// The event's active pass, if this account owns one for it.
    func activePass(forEvent eventId: String) -> EventPass? {
        activePasses.first { $0.eventId == eventId }
    }

    /// Whether creating an event will succeed, mirroring the DB trigger's
    /// order: an unattached active pass, an entitled paid subscription, or the
    /// grandfathered `legacy_free` flag. UX only — the trigger is enforcement.
    var canCreateEvent: Bool {
        if !unattachedActivePasses.isEmpty { return true }
        if policy.isEntitled && policy.nominalTier != .free { return true }
        return profile?.legacyFree == true
    }

    var fullName: String {
        profile?.fullName?.nilIfBlank ?? authUser.userMetadata?.fullName?.nilIfBlank ?? "Planner"
    }

    var email: String? { authUser.email }

    /// Where the current subscription is billed (`.none` for Free).
    var billingProvider: BillingProvider {
        subscription?.billingProvider ?? .none
    }

    /// True when the user has a Stripe-billed subscription that isn't fully
    /// over — including payment-issue states, since those must be resolved on
    /// the web, not by buying a second subscription through Apple.
    var hasActiveStripeBilling: Bool {
        guard billingProvider == .stripe else { return false }
        switch SubscriptionStatus.from(subscription?.status) {
        case .canceled, .incompleteExpired: return false
        default: return true
        }
    }

    /// Account creation date, preferring the auth record, then the profile row.
    var createdDate: Date? {
        authUser.createdDate ?? profile?.createdAt.flatMap(AuthUser.parseISO)
    }
}

// MARK: - Secure external destinations

/// The only external web destinations the app opens. Used for privileged
/// operations that must not run with a user JWT (Stripe billing, deleting
/// `auth.users`) and for legal documents. The upgrade call-to-action is
/// configurable so it can be tuned for App Store storefront compliance.
nonisolated enum AccountLinks {
    static let base = URL(string: "https://aseatawaits.com")!

    /// Secure billing/customer-portal management page (manage subscription,
    /// payment method, invoices, resume/cancel — all confirmed by Stripe there).
    static let billing = URL(string: "https://aseatawaits.com/account/billing")!

    /// Account settings page where deletion is completed securely server-side.
    static let accountSettings = URL(string: "https://aseatawaits.com/account")!

    static let pricing = URL(string: "https://aseatawaits.com/pricing")!
    static let privacyPolicy = URL(string: "https://aseatawaits.com/privacy.pdf")!
    static let termsOfService = URL(string: "https://aseatawaits.com/terms.pdf")!
    static let helpCenter = URL(string: "https://aseatawaits.com/help")!
    static let supportEmail = URL(string: "mailto:support@aseatawaits.com")!

    /// Whether the app should surface an external upgrade/purchase call-to-action.
    /// Disabled: purchases go through StoreKit In-App Purchase (App Review
    /// guideline 3.1.1). Existing Stripe subscribers see neutral, non-tappable
    /// billing text rather than a link to the web portal.
    static let externalUpgradeEnabled = false

    /// Where the upgrade CTA points when enabled.
    static let upgrade = pricing
}

// MARK: - Date formatting

/// Shared formatting for the ISO-8601 timestamps Supabase returns.
nonisolated enum AccountDate {
    /// "Jun 20, 2026" style. Returns nil for missing/unparseable input.
    static func medium(_ iso: String?) -> String? {
        guard let iso, let date = AuthUser.parseISO(iso) else { return nil }
        return mediumFormatter.string(from: date)
    }

    static func medium(_ date: Date?) -> String? {
        guard let date else { return nil }
        return mediumFormatter.string(from: date)
    }

    private static let mediumFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// File-name stamp "yyyy-MM-dd".
    static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Validation

/// Pure, testable input validation for the editable account fields.
nonisolated enum AccountValidation {
    static let maxNameLength = 80

    enum NameError: LocalizedError, Equatable {
        case empty
        case tooLong(Int)
        var errorDescription: String? {
            switch self {
            case .empty: return "Please enter your name."
            case .tooLong(let max): return "Name must be \(max) characters or fewer."
            }
        }
    }

    /// Trims and validates a full name, returning the cleaned value.
    static func validateName(_ raw: String) -> Result<String, NameError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.count <= maxNameLength else { return .failure(.tooLong(maxNameLength)) }
        return .success(trimmed)
    }

    enum EmailError: LocalizedError, Equatable {
        case empty
        case invalid
        case unchanged
        var errorDescription: String? {
            switch self {
            case .empty: return "Please enter an email address."
            case .invalid: return "That doesn't look like a valid email address."
            case .unchanged: return "That's already your email address."
            }
        }
    }

    /// Normalizes (trim + lowercase) and validates an email against the current
    /// address. A deliberately permissive check — the server is authoritative.
    static func validateEmail(_ raw: String, current: String?) -> Result<String, EmailError> {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return .failure(.empty) }
        // Minimal shape check: something@something.tld
        let pattern = #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#
        guard normalized.range(of: pattern, options: .regularExpression) != nil else {
            return .failure(.invalid)
        }
        if let current = current?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           current == normalized {
            return .failure(.unchanged)
        }
        return .success(normalized)
    }

    enum PasswordError: LocalizedError, Equatable {
        case tooShort(Int)
        case mismatch
        case missingCurrent
        var errorDescription: String? {
            switch self {
            case .tooShort(let min): return "New password must be at least \(min) characters."
            case .mismatch: return "The new passwords don't match."
            case .missingCurrent: return "Please enter your current password."
            }
        }
    }

    static let minPasswordLength = 8

    /// Validates a password change request (does not touch the network).
    static func validatePassword(current: String, new: String, confirm: String) -> Result<Void, PasswordError> {
        guard !current.isEmpty else { return .failure(.missingCurrent) }
        guard new.count >= minPasswordLength else { return .failure(.tooShort(minPasswordLength)) }
        guard new == confirm else { return .failure(.mismatch) }
        return .success(())
    }
}
