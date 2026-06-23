//
//  Event.swift
//  A Seat Awaits
//
//  Mirrors the `events` table.
//

import Foundation

nonisolated struct Event: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var date: String?
    var location: String?
    var description: String?
    let ownerId: String
    var qrCodeToken: String?
    var roomWidthFt: Double?
    var roomHeightFt: Double?
    var slug: String?
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, date, location, description, slug
        case ownerId = "owner_id"
        case qrCodeToken = "qr_code_token"
        case roomWidthFt = "room_width_ft"
        case roomHeightFt = "room_height_ft"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// A friendly representation of the event date, when present.
    var displayDate: String? {
        guard let date else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = iso.date(from: date)
            ?? ISO8601DateFormatter().date(from: date)
            ?? Self.dateOnly.date(from: String(date.prefix(10)))
        guard let parsed else { return date }
        return Self.display.string(from: parsed)
    }

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()
}

extension Event {
    /// A minimal reference to an owned event, sufficient for screens that only
    /// need its identity (e.g. inviting a collaborator from the account-wide
    /// Collaborators screen, which loads event summaries rather than full rows).
    init(id: String, name: String, ownerId: String) {
        self.init(id: id, name: name, date: nil, location: nil, description: nil,
                  ownerId: ownerId, qrCodeToken: nil, roomWidthFt: nil, roomHeightFt: nil,
                  slug: nil, createdAt: nil, updatedAt: nil)
    }
}
