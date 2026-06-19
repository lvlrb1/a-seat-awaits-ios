//
//  Guest.swift
//  A Seat Awaits
//
//  Mirrors the `guests` table.
//

import Foundation

nonisolated struct Guest: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let eventId: String
    var name: String
    var email: String?
    var groupId: String?
    var groupName: String?
    var tableId: String?
    var dietaryPreference: String?
    var notes: String?
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, email, notes
        case eventId = "event_id"
        case groupId = "group_id"
        case groupName = "group_name"
        case tableId = "table_id"
        case dietaryPreference = "dietary_preference"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var isAssigned: Bool { tableId != nil }

    /// Last name used for "Last name (A–Z)" sorting; falls back to full name.
    var lastNameKey: String {
        let parts = name.split(separator: " ")
        return (parts.count > 1 ? String(parts.last!) : name).lowercased()
    }

    var firstNameKey: String { name.lowercased() }
}
