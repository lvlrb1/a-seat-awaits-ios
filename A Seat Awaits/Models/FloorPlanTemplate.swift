//
//  FloorPlanTemplate.swift
//  A Seat Awaits
//
//  A reusable floor-plan layout (tables + rooms) saved per-user and applied
//  across events. Mirrors the `floorplan_templates` table and the web app's
//  `useFloorplanTemplates` JSON shape exactly, so templates authored on either
//  client round-trip cleanly:
//
//    floorplan_templates(id, user_id, name, room_width_ft, room_height_ft,
//                        tables_json jsonb, rooms_json jsonb, created_at, updated_at)
//
//  `tables_json` / `rooms_json` are arrays of the strip-down structs below
//  (no ids, no event scoping) — applying a template re-creates fresh rows.
//

import Foundation

/// One table inside a template's `tables_json`. Geometry is in canvas points
/// (24pt = 1ft) just like the live `tables` table; see `TableScale`.
nonisolated struct TemplateTable: Codable, Sendable {
    var name: String
    var shape: String
    var capacity: Int
    var width: Double
    var height: Double
    var positionX: Double
    var positionY: Double
    var rotation: Double
    var description: String?
    var isCustom: Bool?

    enum CodingKeys: String, CodingKey {
        case name, shape, capacity, width, height, rotation, description
        case positionX = "position_x"
        case positionY = "position_y"
        case isCustom = "is_custom"
    }

    /// Decodes leniently: web rows may omit `width`/`height`/`rotation`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        shape = (try? c.decode(String.self, forKey: .shape)) ?? "circle"
        capacity = (try? c.decode(Int.self, forKey: .capacity)) ?? 0
        width = (try? c.decode(Double.self, forKey: .width)) ?? 120
        height = (try? c.decode(Double.self, forKey: .height)) ?? 120
        positionX = (try? c.decode(Double.self, forKey: .positionX)) ?? 0
        positionY = (try? c.decode(Double.self, forKey: .positionY)) ?? 0
        rotation = (try? c.decode(Double.self, forKey: .rotation)) ?? 0
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        isCustom = try? c.decodeIfPresent(Bool.self, forKey: .isCustom)
    }

    init(name: String, shape: String, capacity: Int, width: Double, height: Double,
         positionX: Double, positionY: Double, rotation: Double,
         description: String?, isCustom: Bool?) {
        self.name = name; self.shape = shape; self.capacity = capacity
        self.width = width; self.height = height
        self.positionX = positionX; self.positionY = positionY
        self.rotation = rotation; self.description = description; self.isCustom = isCustom
    }

    /// Captures a live table as a template entry (drops id + event scoping).
    init(table: SeatingTable) {
        self.init(name: table.name,
                  shape: (table.shape ?? .circle).rawValue,
                  capacity: table.capacity ?? 0,
                  width: table.width,
                  height: table.height,
                  positionX: table.positionX ?? 80,
                  positionY: table.positionY ?? 80,
                  rotation: table.rotation ?? 0,
                  description: table.description,
                  isCustom: table.isCustom ?? false)
    }

    var tableShape: TableShape { TableShape(rawValue: shape) ?? .circle }
}

/// One room inside a template's `rooms_json`. Size is in FEET; position is in
/// canvas points (matches `FloorPlanRoom`).
nonisolated struct TemplateRoom: Codable, Sendable {
    var name: String
    var widthFt: Double
    var heightFt: Double
    var positionX: Double
    var positionY: Double
    var color: String?
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case name, color
        case widthFt = "width_ft"
        case heightFt = "height_ft"
        case positionX = "position_x"
        case positionY = "position_y"
        case sortOrder = "sort_order"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Room"
        widthFt = (try? c.decode(Double.self, forKey: .widthFt)) ?? 50
        heightFt = (try? c.decode(Double.self, forKey: .heightFt)) ?? 80
        positionX = (try? c.decode(Double.self, forKey: .positionX)) ?? 0
        positionY = (try? c.decode(Double.self, forKey: .positionY)) ?? 0
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        sortOrder = (try? c.decode(Int.self, forKey: .sortOrder)) ?? 0
    }

    init(name: String, widthFt: Double, heightFt: Double,
         positionX: Double, positionY: Double, color: String?, sortOrder: Int) {
        self.name = name; self.widthFt = widthFt; self.heightFt = heightFt
        self.positionX = positionX; self.positionY = positionY
        self.color = color; self.sortOrder = sortOrder
    }

    /// Captures a live room as a template entry (drops id + event scoping).
    init(room: FloorPlanRoom) {
        self.init(name: room.name,
                  widthFt: room.widthFt,
                  heightFt: room.heightFt,
                  positionX: room.positionX,
                  positionY: room.positionY,
                  color: room.color,
                  sortOrder: room.sortOrder ?? 0)
    }
}

/// A saved floor-plan template. Per-user (RLS scopes to `auth.uid()`), reusable
/// across any of the user's events.
nonisolated struct FloorPlanTemplate: Codable, Identifiable, Sendable {
    let id: String
    var userId: String
    var name: String
    var roomWidthFt: Double?
    var roomHeightFt: Double?
    var tablesJson: [TemplateTable]
    var roomsJson: [TemplateRoom]
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case userId = "user_id"
        case roomWidthFt = "room_width_ft"
        case roomHeightFt = "room_height_ft"
        case tablesJson = "tables_json"
        case roomsJson = "rooms_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decode(String.self, forKey: .userId)
        name = try c.decode(String.self, forKey: .name)
        roomWidthFt = try? c.decodeIfPresent(Double.self, forKey: .roomWidthFt)
        roomHeightFt = try? c.decodeIfPresent(Double.self, forKey: .roomHeightFt)
        tablesJson = (try? c.decodeIfPresent([TemplateTable].self, forKey: .tablesJson)) ?? []
        roomsJson = (try? c.decodeIfPresent([TemplateRoom].self, forKey: .roomsJson)) ?? []
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    /// A one-line summary for the templates list ("4 tables · 1 room").
    var summary: String {
        let t = tablesJson.count
        let r = roomsJson.count
        let tables = "\(t) table\(t == 1 ? "" : "s")"
        guard r > 0 else { return tables }
        return "\(tables) · \(r) room\(r == 1 ? "" : "s")"
    }

    /// Total seats the template lays out, for a richer subtitle.
    var totalSeats: Int { tablesJson.reduce(0) { $0 + $1.capacity } }
}
