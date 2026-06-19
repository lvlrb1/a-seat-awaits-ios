//
//  Collaboration.swift
//  A Seat Awaits
//
//  Models for cross-event data surfaced on the dashboard & guest-facing lookup:
//  per-event seating progress, pending collaboration invitations, and the
//  public "Find Your Table" QR guest-search result.
//

import Foundation

/// Seating progress for one event (seated vs. total guests).
nonisolated struct EventProgress: Equatable, Sendable {
    var seated: Int
    var total: Int
    var fraction: Double { total > 0 ? Double(seated) / Double(total) : 0 }
    var open: Int { max(0, total - seated) }
}

/// A pending collaboration invitation the signed-in user has received.
/// Backed by `event_invitations` (RLS lets an invitee read rows whose
/// `invitee_email` matches their JWT email).
nonisolated struct EventInvitation: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let eventId: String
    var inviteeName: String?
    var inviteeEmail: String?
    var role: String?
    var status: String
    var event: EventRef?
    var inviter: InviterRef?

    nonisolated struct EventRef: Codable, Equatable, Sendable { var name: String? }
    nonisolated struct InviterRef: Codable, Equatable, Sendable {
        var fullName: String?
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }

    enum CodingKeys: String, CodingKey {
        case id, status, role, event, inviter
        case eventId = "event_id"
        case inviteeName = "invitee_name"
        case inviteeEmail = "invitee_email"
    }

    var inviterName: String { inviter?.fullName?.nilIfBlank ?? "Someone" }
    var eventName: String { event?.name?.nilIfBlank ?? "an event" }
    var roleLabel: String { (role ?? "editor").capitalized }
}

/// One result row from `search_guests_by_qr_token`.
nonisolated struct GuestSearchResult: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var groupName: String?
    var tableName: String?
    var tableDescription: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case groupName = "group_name"
        case tableName = "table_name"
        case tableDescription = "table_description"
    }

    /// The numeric/short portion of the table name for the big result display
    /// (e.g. "Table 5" → "5", "VIP" → "VIP").
    var tableNumber: String {
        guard let tableName, !tableName.isEmpty else { return "—" }
        if let n = tableName.split(whereSeparator: { !$0.isNumber }).last, !n.isEmpty {
            return String(n)
        }
        return tableName
    }
}
