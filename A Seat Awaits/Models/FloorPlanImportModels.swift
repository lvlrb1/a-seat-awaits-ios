//
//  FloorPlanImportModels.swift
//  A Seat Awaits
//
//  Request/response DTOs for the `ai-import-floorplan` Supabase Edge Function —
//  the AI floor plan importer that mirrors the web app. The user uploads a
//  photo/scan/PDF of a venue plan; the function runs the same consensus vision
//  extraction + deterministic geometry as the web endpoint and returns a
//  canvas-ready plan (24 pt = 1 ft, top-left origin, relative to the imported
//  room's corner) plus review metadata. The app holds NO AI key and does no
//  geometry: entitlement, rate limits, model, prompt, and layout are all
//  decided server-side (see [[ios-architecture]], [[ai-guest-import]]).
//

import Foundation

// MARK: - Request (the ONLY fields iOS supplies)

/// Body for `ai-import-floorplan`.
nonisolated struct AiFloorplanImportRequest: Encodable, Sendable {
    let eventId: String
    let fileBase64: String
    let filename: String
    let contentType: String
}

// MARK: - Response

/// A detected fixture (dance floor, stage, bar…) as a canvas-ready shape row.
nonisolated struct ImportedPlanShape: Decodable, Sendable, Equatable {
    let name: String
    let type: String
    let positionX: Double
    let positionY: Double
    let width: Double
    let height: Double
    let rotation: Double

    private enum CodingKeys: String, CodingKey {
        case name, type, width, height, rotation
        case positionX = "position_x"
        case positionY = "position_y"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type)
        positionX = try c.decode(Double.self, forKey: .positionX)
        positionY = try c.decode(Double.self, forKey: .positionY)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
    }
}

/// A detected guest table as a canvas-ready table row.
nonisolated struct ImportedPlanTable: Decodable, Sendable, Equatable {
    let name: String
    let shape: String
    let capacity: Int
    let positionX: Double
    let positionY: Double
    let width: Double
    let height: Double
    let rotation: Double
    let isCustom: Bool
    /// Name came from a label the PLANNER wrote on the plan (table numbers) —
    /// renumbering must never shift it, or the import stops matching the
    /// printed chart.
    let nameFromPlan: Bool

    private enum CodingKeys: String, CodingKey {
        case name, shape, capacity, width, height, rotation
        case positionX = "position_x"
        case positionY = "position_y"
        case isCustom = "is_custom"
        case nameFromPlan = "name_from_plan"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        shape = try c.decode(String.self, forKey: .shape)
        capacity = try c.decode(Int.self, forKey: .capacity)
        positionX = try c.decode(Double.self, forKey: .positionX)
        positionY = try c.decode(Double.self, forKey: .positionY)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        isCustom = try c.decodeIfPresent(Bool.self, forKey: .isCustom) ?? true
        nameFromPlan = try c.decodeIfPresent(Bool.self, forKey: .nameFromPlan) ?? false
    }

    init(name: String, shape: String, capacity: Int,
         positionX: Double, positionY: Double,
         width: Double, height: Double, rotation: Double,
         isCustom: Bool, nameFromPlan: Bool) {
        self.name = name
        self.shape = shape
        self.capacity = capacity
        self.positionX = positionX
        self.positionY = positionY
        self.width = width
        self.height = height
        self.rotation = rotation
        self.isCustom = isCustom
        self.nameFromPlan = nameFromPlan
    }
}

/// The room detected on the plan. `nil` in the plan when the image had no
/// measurable scale — the furniture still imports, but a guessed-size room
/// would just be wrong.
nonisolated struct ImportedPlanRoom: Decodable, Sendable, Equatable {
    let name: String
    let widthFt: Double
    let heightFt: Double

    private enum CodingKeys: String, CodingKey {
        case name
        case widthFt = "width_ft"
        case heightFt = "height_ft"
    }
}

/// Canvas-ready result of the extraction, mode "detected" (as drawn).
nonisolated struct ImportedFloorPlan: Decodable, Sendable, Equatable {
    let room: ImportedPlanRoom?
    let shapes: [ImportedPlanShape]
    let tables: [ImportedPlanTable]
}

/// The structured response from `ai-import-floorplan`.
nonisolated struct AiFloorplanImportResponse: Decodable, Sendable {
    let ok: Bool
    let cached: Bool
    let model: String?
    /// Model's own 0..1 confidence in the scale/geometry.
    let confidence: Double
    /// How the pixel→feet scale was established: "scale_bar",
    /// "round_table_prior", or "assumed" (no reference at all).
    let scaleSource: String
    let notes: String?
    /// Detected room geometry — reported even when `plan.room` is nil so the
    /// preview can still size itself.
    let roomName: String
    let roomWidthFt: Double
    let roomHeightFt: Double
    /// Reconciliation against the seat tally written on the plan, if any:
    /// "match", "mismatch", or "no_tally".
    let tallyStatus: String
    let tallyNote: String?
    /// Tables drawn but struck through on the plan — detected, deliberately
    /// not imported.
    let crossedOutCount: Int
    let seatCount: Int
    let plan: ImportedFloorPlan

    init(from decoder: Decoder) throws {
        enum K: String, CodingKey {
            case ok, cached, model, confidence, scaleSource, notes, roomName,
                 roomWidthFt, roomHeightFt, tallyStatus, tallyNote,
                 crossedOutCount, seatCount, plan
        }
        let c = try decoder.container(keyedBy: K.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        cached = try c.decodeIfPresent(Bool.self, forKey: .cached) ?? false
        model = try c.decodeIfPresent(String.self, forKey: .model)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.5
        scaleSource = try c.decodeIfPresent(String.self, forKey: .scaleSource) ?? "assumed"
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        roomName = try c.decodeIfPresent(String.self, forKey: .roomName) ?? "Imported Floor Plan"
        roomWidthFt = try c.decodeIfPresent(Double.self, forKey: .roomWidthFt) ?? 50
        roomHeightFt = try c.decodeIfPresent(Double.self, forKey: .roomHeightFt) ?? 50
        tallyStatus = try c.decodeIfPresent(String.self, forKey: .tallyStatus) ?? "no_tally"
        tallyNote = try c.decodeIfPresent(String.self, forKey: .tallyNote)
        crossedOutCount = try c.decodeIfPresent(Int.self, forKey: .crossedOutCount) ?? 0
        seatCount = try c.decodeIfPresent(Int.self, forKey: .seatCount) ?? 0
        plan = try c.decode(ImportedFloorPlan.self, forKey: .plan)
    }
}

// MARK: - Table renumbering (parity with shared/floorplan renumberPlanTables)

nonisolated enum FloorPlanImportNaming {
    /// The one format for generically-numbered table names ("Table 7").
    static func tableNumber(in name: String) -> Int? {
        guard name.hasPrefix("Table ") else { return nil }
        let rest = name.dropFirst("Table ".count)
        guard rest.count <= 3, !rest.isEmpty, rest.allSatisfy(\.isNumber) else { return nil }
        return Int(rest)
    }

    /// Continue generic "Table N" numbering after the event's existing tables so
    /// an import into a non-empty floor plan yields "Table 19, Table 20…"
    /// instead of collision suffixes. Planner-authored numbers (from labels on
    /// the plan) are the printed chart — never shifted.
    static func renumber(_ tables: [ImportedPlanTable], after existingNames: [String]) -> [ImportedPlanTable] {
        let maxExisting = existingNames.compactMap(tableNumber(in:)).max() ?? 0
        guard maxExisting > 0 else { return tables }
        return tables.map { t in
            guard !t.nameFromPlan, let n = tableNumber(in: t.name) else { return t }
            return ImportedPlanTable(name: "Table \(n + maxExisting)", shape: t.shape,
                                     capacity: t.capacity,
                                     positionX: t.positionX, positionY: t.positionY,
                                     width: t.width, height: t.height, rotation: t.rotation,
                                     isCustom: t.isCustom, nameFromPlan: t.nameFromPlan)
        }
    }

    /// "Table 3" collides with an existing "Table 3" → "Table 3 (2)".
    static func uniqueName(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        for i in 2..<100 {
            let candidate = "\(name) (\(i))"
            if !existing.contains(candidate) { return candidate }
        }
        return name
    }
}
