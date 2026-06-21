//
//  DecorShape.swift
//  A Seat Awaits
//
//  Mirrors the `shapes` table — a decorative, non-seatable object on the floor
//  plan (a stage, dance floor, bar, gift table, …). It shares the four geometric
//  forms of a table (`TableShape`) but carries no capacity or seats. Width/height
//  are canvas points (24pt = 1ft, see `TableScale`); `rotation` is in degrees.
//

import Foundation

nonisolated struct DecorShape: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let eventId: String
    var name: String
    var type: TableShape
    var width: Double
    var height: Double
    var positionX: Double?
    var positionY: Double?
    var rotation: Double?
    var description: String?
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, type, width, height, rotation, description
        case eventId = "event_id"
        case positionX = "position_x"
        case positionY = "position_y"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var rotationDegrees: Double { rotation ?? 0 }

    /// Round footprints (circle/oval) draw with an ellipse and ignore rotation.
    var isRound: Bool { type == .circle || type == .oval }

    /// The default footprint for a freshly-created shape of a given type, in
    /// canvas points — matches the web `getDefaultSizeForType` (rectangle/oval
    /// are wide; square/circle are equal-sided).
    static func defaultSize(for type: TableShape) -> (width: Double, height: Double) {
        switch type {
        case .rectangle, .oval: return (180, 100)
        case .square, .circle: return (120, 120)
        }
    }
}
