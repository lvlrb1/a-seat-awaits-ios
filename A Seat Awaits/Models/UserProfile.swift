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

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case subscriptionTier = "subscription_tier"
        case subscriptionStatus = "subscription_status"
    }

    var tierLabel: String {
        (subscriptionTier ?? "free").capitalized
    }
}
