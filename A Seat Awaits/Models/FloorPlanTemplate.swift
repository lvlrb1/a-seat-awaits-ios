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
    /// Color is intentionally dropped — room tints are no longer a setting.
    init(room: FloorPlanRoom) {
        self.init(name: room.name,
                  widthFt: room.widthFt,
                  heightFt: room.heightFt,
                  positionX: room.positionX,
                  positionY: room.positionY,
                  color: nil,
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

    /// Memberwise init for locally-built templates (the built-in starters).
    init(id: String, userId: String, name: String,
         roomWidthFt: Double? = nil, roomHeightFt: Double? = nil,
         tablesJson: [TemplateTable], roomsJson: [TemplateRoom],
         createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id; self.userId = userId; self.name = name
        self.roomWidthFt = roomWidthFt; self.roomHeightFt = roomHeightFt
        self.tablesJson = tablesJson; self.roomsJson = roomsJson
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// Id prefix reserved for the app's bundled starter layouts. These never
    /// exist in `floorplan_templates` — they're applied locally and can't be
    /// overwritten or deleted.
    static let builtInIdPrefix = "builtin."

    var isBuiltIn: Bool { id.hasPrefix(Self.builtInIdPrefix) }

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

// MARK: - Built-in starter layouts

/// A bundled starter layout: a local-only `FloorPlanTemplate` plus the copy
/// that sells it in the Templates sheet. Applied through the same
/// `applyTemplate` path as saved templates (undo included); never written to
/// the server's template table.
nonisolated struct StarterLayout: Identifiable, Sendable {
    let template: FloorPlanTemplate
    let blurb: String
    let systemImage: String

    var id: String { template.id }

    /// All five starters, in display order. Geometry is authored in feet and
    /// converted to canvas points (24pt = 1ft) so it matches hand-placed
    /// tables and the web canvas exactly.
    static let all: [StarterLayout] = [
        StarterLayout(template: Builder.classicReception,
                      blurb: "Ten 48-inch rounds of 8 in two rows. Room for a dance floor below.",
                      systemImage: "circle.grid.3x3"),
        StarterLayout(template: Builder.intimateDinner,
                      blurb: "A head table for 10 with four rounds of 6 gathered in front.",
                      systemImage: "fork.knife"),
        StarterLayout(template: Builder.banquetRows,
                      blurb: "Six 8-foot banquet tables of 10 in two tidy columns.",
                      systemImage: "rectangle.grid.2x2"),
        StarterLayout(template: Builder.uShapeBoardroom,
                      blurb: "Seven 6-foot tables in a U, everyone facing the open end.",
                      systemImage: "rectangle.3.group"),
        StarterLayout(template: Builder.cocktailHighboys,
                      blurb: "Eight standing highboys for mingling plus two rounds to sit at.",
                      systemImage: "wineglass"),
    ]

    /// Authoring helpers. Centers are given in FEET; sizes follow the preset
    /// table specs so every starter table reads as a standard type.
    private enum Builder {
        private static func ft(_ feet: Double) -> Double { TableScale.feet(feet) }

        /// A round table centered at (`cx`, `cy`) feet.
        private static func round(_ name: String, inches: Double, seats: Int,
                                  cx: Double, cy: Double, isCustom: Bool = false) -> TemplateTable {
            let d = TableScale.inches(inches)
            return TemplateTable(name: name, shape: "circle", capacity: seats,
                                 width: d, height: d,
                                 positionX: ft(cx) - d / 2, positionY: ft(cy) - d / 2,
                                 rotation: 0, description: nil, isCustom: isCustom)
        }

        /// A 30-inch-deep banquet rectangle of `lengthFt`, centered at
        /// (`cx`, `cy`) feet. `rotation` spins it about that center, so the
        /// stored (un-rotated) top-left is still center minus half size.
        private static func banquet(_ name: String, lengthFt: Double, seats: Int,
                                    cx: Double, cy: Double, rotation: Double = 0) -> TemplateTable {
            let w = ft(lengthFt), h = TableScale.inches(30)
            return TemplateTable(name: name, shape: "rectangle", capacity: seats,
                                 width: w, height: h,
                                 positionX: ft(cx) - w / 2, positionY: ft(cy) - h / 2,
                                 rotation: rotation, description: nil, isCustom: false)
        }

        private static func room(_ name: String, widthFt: Double, heightFt: Double) -> TemplateRoom {
            TemplateRoom(name: name, widthFt: widthFt, heightFt: heightFt,
                         positionX: 0, positionY: 0, color: nil, sortOrder: 0)
        }

        private static func template(_ key: String, _ name: String,
                                     room: TemplateRoom, tables: [TemplateTable]) -> FloorPlanTemplate {
            FloorPlanTemplate(id: FloorPlanTemplate.builtInIdPrefix + key, userId: "",
                              name: name,
                              roomWidthFt: room.widthFt, roomHeightFt: room.heightFt,
                              tablesJson: tables, roomsJson: [room])
        }

        /// Ten 48" rounds (8 seats) on 10ft centers, two rows of five.
        static let classicReception: FloorPlanTemplate = {
            var tables: [TemplateTable] = []
            var n = 1
            for cy in [8.0, 20.0] {
                for cx in stride(from: 6.0, through: 46.0, by: 10.0) {
                    tables.append(round("Table \(n)", inches: 48, seats: 8, cx: cx, cy: cy))
                    n += 1
                }
            }
            return template("classic-reception", "Classic Reception",
                            room: room("Ballroom", widthFt: 52, heightFt: 34), tables: tables)
        }()

        /// An 8ft head table for 10 up top, four 48" rounds of 6 in front.
        static let intimateDinner: FloorPlanTemplate = {
            var tables = [banquet("Head Table", lengthFt: 8, seats: 10, cx: 15, cy: 4)]
            let spots: [(Double, Double)] = [(9, 13), (21, 13), (9, 23), (21, 23)]
            for (i, spot) in spots.enumerated() {
                tables.append(round("Table \(i + 1)", inches: 48, seats: 6, cx: spot.0, cy: spot.1))
            }
            return template("intimate-dinner", "Intimate Dinner",
                            room: room("Dining Room", widthFt: 30, heightFt: 30), tables: tables)
        }()

        /// Six 8ft banquet rectangles of 10 in two columns, three rows.
        static let banquetRows: FloorPlanTemplate = {
            var tables: [TemplateTable] = []
            var n = 1
            for cy in [7.0, 17.0, 27.0] {
                for cx in [10.0, 26.0] {
                    tables.append(banquet("Table \(n)", lengthFt: 8, seats: 10, cx: cx, cy: cy))
                    n += 1
                }
            }
            return template("banquet-rows", "Banquet Rows",
                            room: room("Hall", widthFt: 36, heightFt: 36), tables: tables)
        }()

        /// Three 6ft tables across the top and two down each side (rotated
        /// 90°), with a half-foot gap between pieces so nothing overlaps.
        static let uShapeBoardroom: FloorPlanTemplate = {
            var tables: [TemplateTable] = []
            for (i, cx) in [9.0, 15.0, 21.0].enumerated() {
                tables.append(banquet("Top \(i + 1)", lengthFt: 6, seats: 8, cx: cx, cy: 5))
            }
            for (i, cy) in [9.75, 16.25].enumerated() {
                tables.append(banquet("Left \(i + 1)", lengthFt: 6, seats: 8,
                                      cx: 7.25, cy: cy, rotation: 90))
                tables.append(banquet("Right \(i + 1)", lengthFt: 6, seats: 8,
                                      cx: 22.75, cy: cy, rotation: 90))
            }
            return template("u-shape-boardroom", "U-Shape Boardroom",
                            room: room("Boardroom", widthFt: 30, heightFt: 26), tables: tables)
        }()

        /// Eight 30" standing highboys on an 8ft grid, two 60" rounds to sit at.
        static let cocktailHighboys: FloorPlanTemplate = {
            var tables: [TemplateTable] = []
            var n = 1
            for cy in [7.0, 15.0] {
                for cx in stride(from: 6.0, through: 30.0, by: 8.0) {
                    tables.append(round("Highboy \(n)", inches: 30, seats: 4,
                                        cx: cx, cy: cy, isCustom: true))
                    n += 1
                }
            }
            tables.append(round("Lounge 1", inches: 60, seats: 10, cx: 11, cy: 24))
            tables.append(round("Lounge 2", inches: 60, seats: 10, cx: 25, cy: 24))
            return template("cocktail-highboys", "Cocktail & Highboys",
                            room: room("Lounge", widthFt: 36, heightFt: 30), tables: tables)
        }()
    }
}
