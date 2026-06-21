//
//  UserProfile.swift
//  A Seat Awaits
//
//  Subset of the `users` table the app reads for the Account screen.
//

import Foundation

nonisolated struct UserProfile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var fullName: String?
    var subscriptionTier: String?
    var subscriptionStatus: String?
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case subscriptionTier = "subscription_tier"
        case subscriptionStatus = "subscription_status"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Customer-facing plan name, normalized through `PlanTier`.
    var tierLabel: String {
        PlanTier.normalize(subscriptionTier).displayName
    }
}
