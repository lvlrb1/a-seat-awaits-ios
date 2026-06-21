//
//  SeatingTable.swift
//  A Seat Awaits
//
//  Mirrors the `tables` table. Named `SeatingTable` to avoid colliding with
//  SwiftUI's `Table`.
//

import Foundation

nonisolated enum TableShape: String, Codable, CaseIterable, Sendable, Identifiable {
    case circle, rectangle, square, oval
    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .circle: return "circle"
        case .rectangle: return "rectangle"
        case .square: return "square"
        case .oval: return "oval"
        }
    }
}

nonisolated struct SeatingTable: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let eventId: String
    var name: String
    var capacity: Int?
    var shape: TableShape?
    var width: Double
    var height: Double
    var positionX: Double?
    var positionY: Double?
    var rotation: Double?
    var isCustom: Bool?
    var description: String?
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, capacity, shape, width, height, description, rotation
        case eventId = "event_id"
        case positionX = "position_x"
        case positionY = "position_y"
        case isCustom = "is_custom"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var seats: Int { capacity ?? 0 }

    /// Round-footprint tables (no meaningful rotation, draw a capacity ring).
    var isRound: Bool {
        let s = shape ?? .circle
        return s == .circle || s == .oval
    }

    /// Stored rotation in degrees (0 when unset).
    var rotationDegrees: Double { rotation ?? 0 }

    /// Physical footprint in feet (width/height are stored at 24pt = 1ft).
    var widthFeet: Double { TableScale.toFeet(points: width) }
    var heightFeet: Double { TableScale.toFeet(points: height) }

    /// The matching preset type, when the table's shape + size align to one.
    var matchingPreset: TablePreset? {
        TablePreset.match(shape: shape ?? .circle, width: width, height: height)
    }
}
