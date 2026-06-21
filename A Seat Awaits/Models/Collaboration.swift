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
/// Backed by the `list_my_pending_invites()` RPC, which flattens the invite
/// with its event and inviter names and scopes rows to `auth.email()`.
nonisolated struct EventInvitation: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let token: String
    let eventId: String
    var eventNameRaw: String?
    var eventDate: String?
    var eventDescription: String?
    var inviterNameRaw: String?
    var inviteeName: String?
    var role: String?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, token, role
        case eventId = "event_id"
        case eventNameRaw = "event_name"
        case eventDate = "event_date"
        case eventDescription = "event_description"
        case inviterNameRaw = "inviter_name"
        case inviteeName = "invitee_name"
        case createdAt = "created_at"
    }

    var inviterName: String { inviterNameRaw?.nilIfBlank ?? "Someone" }
    var eventName: String { eventNameRaw?.nilIfBlank ?? "an event" }
    var roleLabel: String { (role ?? "editor").capitalized }
}

/// The signed-in user's permission on an event. Mirrors the web app's
/// `useCollaborationPermissions` role model: the owner and shared editors may
/// mutate; viewers (and the safe default before the role resolves) are
/// read-only. The DB `share_role` enum only has `viewer`/`editor`; ownership is
/// derived from `events.owner_id`.
nonisolated enum EventRole: String, Sendable {
    case owner
    case editor
    case viewer

    /// True when this role may add/edit/move/delete tables, shapes, rooms and
    /// (re)assign guests. Viewers get a read-only floor plan.
    var canEdit: Bool { self == .owner || self == .editor }
}

/// One row of `event_shares` (just the bits we need to resolve a role).
nonisolated struct EventShareRow: Codable, Sendable {
    let role: String?
}

/// A collaborator on an event (the owner plus any shared editors/viewers).
/// Backed by the `event_collaborators(p_event_id)` RPC.
nonisolated struct Collaborator: Codable, Identifiable, Equatable, Sendable {
    let email: String
    var fullName: String?
    var role: String?
    var isOwner: Bool

    enum CodingKeys: String, CodingKey {
        case email, role
        case fullName = "full_name"
        case isOwner = "is_owner"
    }

    var id: String { email }
    var displayName: String { fullName?.nilIfBlank ?? email }
}

/// Server-computed seating progress for one event.
/// Backed by the `event_seating_summary(p_event_ids)` RPC.
nonisolated struct EventSeatingSummary: Codable, Identifiable, Equatable, Sendable {
    let eventId: String
    let totalGuests: Int
    let seatedGuests: Int
    let unseatedGuests: Int
    let totalCapacity: Int
    let openSeats: Int

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case totalGuests = "total_guests"
        case seatedGuests = "seated_guests"
        case unseatedGuests = "unseated_guests"
        case totalCapacity = "total_capacity"
        case openSeats = "open_seats"
    }

    var id: String { eventId }
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
