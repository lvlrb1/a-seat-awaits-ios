//
//  FloorPlanRoom.swift
//  A Seat Awaits
//
//  Mirrors the `floorplan_rooms` table — a labelled boundary drawn behind the
//  tables (a banquet hall, tent, patio, …). Unlike tables/shapes, a room's size
//  is stored in *feet* (`width_ft`/`height_ft`); its position is in canvas points
//  (24pt = 1ft, see `TableScale`), matching the web floor plan.
//

import Foundation

nonisolated struct FloorPlanRoom: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let eventId: String
    var name: String
    var widthFt: Double
    var heightFt: Double
    var positionX: Double
    var positionY: Double
    var color: String?
    var sortOrder: Int?
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case eventId = "event_id"
        case widthFt = "width_ft"
        case heightFt = "height_ft"
        case positionX = "position_x"
        case positionY = "position_y"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Footprint in canvas points (rooms store feet; everything else is points).
    var widthPoints: Double { TableScale.feet(widthFt) }
    var heightPoints: Double { TableScale.feet(heightFt) }

    /// The room's fill, defaulting to the web's neutral slate when unset.
    var colorHex: String { (color?.isEmpty == false ? color : nil) ?? "#E5E7EB" }
}
