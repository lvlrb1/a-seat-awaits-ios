//
//  SeatingStore.swift
//  A Seat Awaits
//
//  Owns the guests, tables, and groups for a single selected event, plus the
//  mutations the UI performs (add guest, assign to table, move tables, …).
//

import Foundation
import Observation

// MARK: - Insert / update payloads (kept nonisolated so they can cross into the
// Supabase actor as Sendable values).

nonisolated struct NewGuestDTO: Encodable, Sendable {
    let event_id: String
    let name: String
    let group_id: String?
    let group_name: String?
    let notes: String?
    let dietary_preference: String?
}

nonisolated struct GuestTablePatch: Encodable, Sendable {
    let table_id: String?
}

nonisolated struct NewTableDTO: Encodable, Sendable {
    let event_id: String
    let name: String
    let shape: String
    let capacity: Int
    let width: Double
    let height: Double
    let position_x: Double
    let position_y: Double
    // Optional columns — omitted from the request when nil so the table
    // defaults apply (keeps older call sites byte-for-byte compatible).
    var rotation: Double? = nil
    var description: String? = nil
    var is_custom: Bool? = nil
}

nonisolated struct TablePositionPatch: Encodable, Sendable {
    let position_x: Double
    let position_y: Double
}

nonisolated struct TableRotationPatch: Encodable, Sendable {
    let rotation: Double
}

/// Full table edit. `description` is encoded explicitly (even when nil) so a
/// cleared description persists as SQL NULL rather than being left untouched.
nonisolated struct TableUpdateDTO: Encodable, Sendable {
    let name: String
    let capacity: Int
    let shape: String
    let width: Double
    let height: Double
    let description: String?
    let rotation: Double
    let is_custom: Bool

    enum CodingKeys: String, CodingKey {
        case name, capacity, shape, width, height, description, rotation, is_custom
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(capacity, forKey: .capacity)
        try c.encode(shape, forKey: .shape)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(description, forKey: .description)  // null when nil
        try c.encode(rotation, forKey: .rotation)
        try c.encode(is_custom, forKey: .is_custom)
    }
}

/// Encodable params for the `event_collaborators` RPC.
nonisolated struct EventCollaboratorsParams: Encodable, Sendable {
    let p_event_id: String
}

// MARK: - Room payloads

nonisolated struct NewRoomDTO: Encodable, Sendable {
    let event_id: String
    let name: String
    let width_ft: Double
    let height_ft: Double
    let position_x: Double
    let position_y: Double
    let color: String?
    // Optional so existing call sites stay unchanged; only the template apply
    // path sets it to preserve a layout's room ordering.
    var sort_order: Int? = nil
}

/// `color` is encoded even when nil so clearing it persists as SQL NULL.
nonisolated struct RoomUpdateDTO: Encodable, Sendable {
    let name: String
    let width_ft: Double
    let height_ft: Double
    let color: String?

    func encode(to encoder: Encoder) throws {
        enum K: String, CodingKey { case name, width_ft, height_ft, color }
        var c = encoder.container(keyedBy: K.self)
        try c.encode(name, forKey: .name)
        try c.encode(width_ft, forKey: .width_ft)
        try c.encode(height_ft, forKey: .height_ft)
        try c.encode(color, forKey: .color)  // null when nil
    }
}

// MARK: - Shape (decorative object) payloads

nonisolated struct NewShapeDTO: Encodable, Sendable {
    let event_id: String
    let name: String
    let type: String
    let width: Double
    let height: Double
    let position_x: Double
    let position_y: Double
    var rotation: Double? = nil
    var description: String? = nil
}

/// `description` is encoded even when nil so a cleared note persists as NULL.
nonisolated struct ShapeUpdateDTO: Encodable, Sendable {
    let name: String
    let type: String
    let width: Double
    let height: Double
    let description: String?

    func encode(to encoder: Encoder) throws {
        enum K: String, CodingKey { case name, type, width, height, description }
        var c = encoder.container(keyedBy: K.self)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(description, forKey: .description)  // null when nil
    }
}

nonisolated struct ShapeRotationPatch: Encodable, Sendable {
    let rotation: Double
}

// MARK: - Template payloads

/// Insert body for a new `floorplan_templates` row. `user_id` is sent explicitly
/// (no DB default) and must equal `auth.uid()` to satisfy RLS.
nonisolated struct TemplateInsertDTO: Encodable, Sendable {
    let user_id: String
    let name: String
    let tables_json: [TemplateTable]
    let rooms_json: [TemplateRoom]
    let room_width_ft: Double?
    let room_height_ft: Double?
}

/// Update body when overwriting an existing template (user_id is left untouched).
nonisolated struct TemplateUpdateDTO: Encodable, Sendable {
    let name: String
    let tables_json: [TemplateTable]
    let rooms_json: [TemplateRoom]
    let room_width_ft: Double?
    let room_height_ft: Double?
}

/// Throwaway decode target for writes whose returned representation we ignore.
nonisolated struct EmptyRow: Decodable, Sendable {}

@MainActor
@Observable
final class SeatingStore {
    let event: Event
    private let supabase: SupabaseClient

    private(set) var guests: [Guest] = []
    private(set) var tables: [SeatingTable] = []
    private(set) var groups: [GuestGroup] = []
    private(set) var rooms: [FloorPlanRoom] = []
    private(set) var shapes: [DecorShape] = []
    private(set) var collaborators: [Collaborator] = []
    /// The signed-in user's reusable floor-plan templates (per-user, cross-event).
    private(set) var templates: [FloorPlanTemplate] = []

    /// The signed-in user's permission on this event. Starts as `.viewer` (the
    /// safe, read-only default) and is resolved during `loadAll`. Drives every
    /// editing affordance through `canEdit`.
    private(set) var role: EventRole = .viewer
    /// Set when a live `event_shares` change (Stage 5 realtime) revokes the
    /// signed-in user's access entirely — the workspace surfaces a notice.
    private(set) var accessRevoked = false

    private(set) var isLoading = false
    var errorMessage: String?

    /// True when the last operation failed because the device is offline. Drives
    /// the workspace's offline banner (F10).
    private(set) var isOffline = false

    /// Shared undo banner for reversible seating actions (assign, unseat,
    /// bulk-seat, guest delete, apply template) — the single pattern from F3.
    let undo = UndoToast()

    /// Whether the current user may mutate the floor plan / guest list.
    var canEdit: Bool { role.canEdit && !accessRevoked }

    init(event: Event, supabase: SupabaseClient) {
        self.event = event
        self.supabase = supabase
    }

    var stats: EventStats { EventStats.compute(guests: guests, tables: tables) }

    /// Routes a caught error to friendly UI copy and tracks offline state (F10).
    /// Connectivity failures surface only via the persistent offline banner — not
    /// a one-off alert — so a venue with weak Wi-Fi doesn't spam dialogs.
    private func report(_ error: Error) {
        if FriendlyError.isOffline(error) {
            isOffline = true
        } else {
            errorMessage = FriendlyError.message(for: error)
        }
    }

    /// Clears the offline banner after any successful round-trip.
    private func markReachable() {
        if isOffline { isOffline = false }
    }

    private var eventFilter: URLQueryItem {
        URLQueryItem(name: "event_id", value: "eq.\(event.id)")
    }

    // MARK: - Loading

    func loadAll() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let g = supabase.select("guests",
                                          query: [URLQueryItem(name: "select", value: "*"), eventFilter],
                                          as: [Guest].self)
            async let t = supabase.select("tables",
                                          query: [URLQueryItem(name: "select", value: "*"), eventFilter],
                                          as: [SeatingTable].self)
            async let gr = supabase.select("guest_groups",
                                           query: [URLQueryItem(name: "select", value: "*"), eventFilter],
                                           as: [GuestGroup].self)
            async let rm = supabase.select("floorplan_rooms",
                                           query: [URLQueryItem(name: "select", value: "*"), eventFilter,
                                                   URLQueryItem(name: "order", value: "sort_order.asc")],
                                           as: [FloorPlanRoom].self)
            async let sh = supabase.select("shapes",
                                           query: [URLQueryItem(name: "select", value: "*"), eventFilter],
                                           as: [DecorShape].self)
            let (loadedGuests, loadedTables, loadedGroups, loadedRooms, loadedShapes) =
                try await (g, t, gr, rm, sh)
            guests = loadedGuests
            tables = loadedTables
            groups = loadedGroups
            rooms = loadedRooms
            shapes = loadedShapes
            isOffline = false
        } catch {
            report(error)
        }
        await resolveRole()
        await loadCollaborators()
    }

    // MARK: - Permissions

    /// Resolves the signed-in user's role on this event, mirroring the web's
    /// `useCollaborationPermissions`: owner via `events.owner_id`, otherwise an
    /// `event_shares` row keyed by email (editor/viewer). Falls back to viewer
    /// (read-only) when no role can be determined, so we never grant edit by
    /// accident. Non-fatal — leaves the prior role on failure.
    func resolveRole() async {
        guard let user = await supabase.currentUser else { return }
        if event.ownerId == user.id {
            role = .owner
            return
        }
        guard let email = user.email else { role = .viewer; return }
        do {
            let rows = try await supabase.select(
                "event_shares",
                query: [URLQueryItem(name: "select", value: "role"),
                        eventFilter,
                        URLQueryItem(name: "email", value: "eq.\(email)")],
                as: [EventShareRow].self
            )
            role = (rows.first?.role == "editor") ? .editor : .viewer
        } catch {
            role = .viewer
        }
    }

    /// Applies a live `event_shares` change for the signed-in user (Stage 5
    /// realtime). A deletion revokes access; an insert/update re-derives the
    /// editor/viewer role. Owners are unaffected.
    func applyShareChange(role newRole: String?, deleted: Bool) {
        guard role != .owner else { return }
        if deleted {
            accessRevoked = true
            role = .viewer
        } else {
            accessRevoked = false
            role = (newRole == "editor") ? .editor : .viewer
        }
    }

    /// Loads the event's collaborators (owner + shared editors/viewers) via the
    /// `event_collaborators` RPC. Non-fatal: the avatar stack falls back to the
    /// planner's own name when this is empty.
    func loadCollaborators() async {
        do {
            collaborators = try await supabase.rpc(
                "event_collaborators",
                params: EventCollaboratorsParams(p_event_id: event.id),
                as: [Collaborator].self
            )
        } catch {
            // Non-fatal — keep whatever we already had.
        }
    }

    // MARK: - Guests

    @discardableResult
    func addGuest(name: String,
                  groupId: String?,
                  groupName: String?,
                  notes: String?,
                  dietary: String?) async throws -> Guest {
        let rows = try await supabase.insert(
            "guests",
            values: NewGuestDTO(event_id: event.id,
                                name: name,
                                group_id: groupId,
                                group_name: groupName?.nilIfBlank,
                                notes: notes?.nilIfBlank,
                                dietary_preference: dietary?.nilIfBlank),
            returning: [Guest].self
        )
        guard let guest = rows.first else { throw SupabaseError.decoding("No guest returned.") }
        guests.append(guest)
        markReachable()
        return guest
    }

    /// Assigns (or, with `nil`, unassigns) a guest to a table. Optimistically
    /// updates local state and rolls back on failure.
    func assign(_ guest: Guest, toTable tableId: String?) async {
        guard let index = guests.firstIndex(where: { $0.id == guest.id }) else { return }
        let previous = guests[index]
        guests[index].tableId = tableId

        do {
            _ = try await supabase.update(
                "guests",
                values: GuestTablePatch(table_id: tableId),
                query: [URLQueryItem(name: "id", value: "eq.\(guest.id)")],
                returning: [Guest].self
            )
            markReachable()
        } catch {
            guests[index] = previous
            report(error)
        }
    }

    /// Assigns several guests to a single table (or, with `nil`, unassigns them)
    /// in one round-trip. Optimistically updates local state and rolls every
    /// guest back together on failure. No-op for an empty selection.
    func assign(_ guests: [Guest], toTable tableId: String?) async {
        let ids = guests.map(\.id)
        guard !ids.isEmpty else { return }

        // Snapshot prior table for each affected guest, then apply optimistically.
        var previous: [String: String?] = [:]
        for id in ids {
            guard let index = self.guests.firstIndex(where: { $0.id == id }) else { continue }
            previous[id] = self.guests[index].tableId
            self.guests[index].tableId = tableId
        }
        guard !previous.isEmpty else { return }

        do {
            _ = try await supabase.update(
                "guests",
                values: GuestTablePatch(table_id: tableId),
                query: [URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))")],
                returning: [Guest].self
            )
            markReachable()
        } catch {
            for (id, table) in previous {
                if let index = self.guests.firstIndex(where: { $0.id == id }) {
                    self.guests[index].tableId = table
                }
            }
            report(error)
        }
    }

    func deleteGuest(_ guest: Guest) async {
        let snapshot = guests
        guests.removeAll { $0.id == guest.id }
        do {
            try await supabase.delete("guests", query: [URLQueryItem(name: "id", value: "eq.\(guest.id)")])
            markReachable()
        } catch {
            guests = snapshot
            report(error)
        }
    }

    // MARK: - Undo-aware seating actions (F3)

    /// Assigns/unseats a single guest, then offers a transient undo restoring the
    /// prior table. Every user-facing seat/unseat affordance routes through this.
    func assignWithUndo(_ guest: Guest, toTable tableId: String?) async {
        let previousTable = guests.first(where: { $0.id == guest.id })?.tableId
        guard previousTable != tableId else { return }   // nothing changed
        await assign(guest, toTable: tableId)
        guard errorMessage == nil else { return }
        presentAssignUndo([guest.id: previousTable],
                          message: assignMessage(name: guest.name, toTable: tableId))
    }

    /// Bulk seat/unseat with a single undo restoring every guest's prior table.
    func assignWithUndo(_ batch: [Guest], toTable tableId: String?) async {
        let ids = batch.map(\.id)
        guard !ids.isEmpty else { return }
        var previous: [String: String?] = [:]
        for guest in batch { previous[guest.id] = guests.first(where: { $0.id == guest.id })?.tableId }
        await assign(batch, toTable: tableId)
        guard errorMessage == nil else { return }
        let count = ids.count
        let message: String
        if let name = table(withId: tableId)?.name {
            message = "Seated \(count) guest\(count == 1 ? "" : "s") at \(name)."
        } else {
            message = "Unseated \(count) guest\(count == 1 ? "" : "s")."
        }
        presentAssignUndo(previous, message: message)
    }

    private func assignMessage(name: String, toTable tableId: String?) -> String {
        if let table = table(withId: tableId)?.name { return "Seated \(name) at \(table)." }
        return "Unseated \(name)."
    }

    /// Shows the undo banner that restores each guest's table from `previous`
    /// (guestId → prior tableId) by re-issuing the assignment writes.
    private func presentAssignUndo(_ previous: [String: String?], message: String) {
        undo.show(message) { [weak self] in
            guard let self else { return }
            Task {
                for (id, table) in previous {
                    guard let guest = self.guests.first(where: { $0.id == id }) else { continue }
                    await self.assign(guest, toTable: table)
                }
            }
        }
    }

    /// Deletes a guest immediately, then offers an undo that re-creates them with
    /// the same details and restores their seat (F2). A new row id is minted on
    /// undo — invisible to the user, who sees the same guest back at their table.
    func deleteGuestWithUndo(_ guest: Guest) async {
        let restore = guest
        await deleteGuest(guest)
        guard errorMessage == nil else { return }
        undo.show("Deleted \(restore.name).") { [weak self] in
            guard let self else { return }
            Task {
                do {
                    let recreated = try await self.addGuest(
                        name: restore.name,
                        groupId: restore.groupId,
                        groupName: restore.groupName,
                        notes: restore.notes,
                        dietary: restore.dietaryPreference)
                    if let table = restore.tableId {
                        await self.assign(recreated, toTable: table)
                    }
                } catch {
                    self.report(error)
                }
            }
        }
    }

    // MARK: - Tables

    @discardableResult
    func addTable(name: String,
                  shape: TableShape,
                  capacity: Int,
                  width: Double,
                  height: Double,
                  positionX: Double,
                  positionY: Double,
                  description: String? = nil,
                  rotation: Double = 0,
                  isCustom: Bool = false) async throws -> SeatingTable {
        let rows = try await supabase.insert(
            "tables",
            values: NewTableDTO(event_id: event.id,
                                name: name,
                                shape: shape.rawValue,
                                capacity: capacity,
                                width: width,
                                height: height,
                                position_x: positionX,
                                position_y: positionY,
                                rotation: rotation,
                                description: description,
                                is_custom: isCustom),
            returning: [SeatingTable].self
        )
        guard let table = rows.first else { throw SupabaseError.decoding("No table returned.") }
        tables.append(table)
        return table
    }

    /// Saves a full table edit (name, capacity, shape, size, rotation, notes).
    /// Optimistically updates local state and rolls back on failure. Returns the
    /// persisted row on success, or nil on failure (with `errorMessage` set).
    @discardableResult
    func updateTable(_ table: SeatingTable,
                     name: String,
                     capacity: Int,
                     shape: TableShape,
                     width: Double,
                     height: Double,
                     description: String?,
                     rotation: Double,
                     isCustom: Bool) async -> SeatingTable? {
        guard let index = tables.firstIndex(where: { $0.id == table.id }) else { return nil }
        let previous = tables[index]
        tables[index].name = name
        tables[index].capacity = capacity
        tables[index].shape = shape
        tables[index].width = width
        tables[index].height = height
        tables[index].description = description
        tables[index].rotation = rotation
        tables[index].isCustom = isCustom
        do {
            let rows = try await supabase.update(
                "tables",
                values: TableUpdateDTO(name: name, capacity: capacity, shape: shape.rawValue,
                                       width: width, height: height, description: description,
                                       rotation: rotation, is_custom: isCustom),
                query: [URLQueryItem(name: "id", value: "eq.\(table.id)")],
                returning: [SeatingTable].self
            )
            if let updated = rows.first { tables[index] = updated }
            return tables[index]
        } catch {
            tables[index] = previous
            report(error)
            return nil
        }
    }

    /// Inserts a copy of a table, offset slightly so it doesn't sit exactly on
    /// top of the original. Guests are not copied.
    func duplicateTable(_ table: SeatingTable) async {
        let offset = TableScale.pointsPerFoot   // one foot down-and-right
        do {
            let rows = try await supabase.insert(
                "tables",
                values: NewTableDTO(event_id: event.id,
                                    name: "\(table.name) copy",
                                    shape: (table.shape ?? .circle).rawValue,
                                    capacity: table.capacity ?? 0,
                                    width: table.width,
                                    height: table.height,
                                    position_x: (table.positionX ?? 0) + offset,
                                    position_y: (table.positionY ?? 0) + offset,
                                    rotation: table.rotation ?? 0,
                                    description: table.description,
                                    is_custom: table.isCustom ?? false),
                returning: [SeatingTable].self
            )
            if let new = rows.first { tables.append(new) }
        } catch {
            report(error)
        }
    }

    /// Persists a table's rotation (normalised to 0..<360). Used by the canvas
    /// "Rotate 15°" affordance.
    func updateRotation(of table: SeatingTable, to degrees: Double) async {
        let normalized = ((degrees.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        if let index = tables.firstIndex(where: { $0.id == table.id }) {
            tables[index].rotation = normalized
        }
        do {
            _ = try await supabase.update(
                "tables",
                values: TableRotationPatch(rotation: normalized),
                query: [URLQueryItem(name: "id", value: "eq.\(table.id)")],
                returning: [SeatingTable].self
            )
        } catch {
            report(error)
        }
    }

    /// Commits a moved table's new position. The local model is updated
    /// *synchronously* so the caller can clear its drag offset in the same render
    /// pass without the table flashing back to its old spot; the write to the
    /// backend happens in the background.
    func updatePosition(of table: SeatingTable, x: Double, y: Double) {
        if let index = tables.firstIndex(where: { $0.id == table.id }) {
            tables[index].positionX = x
            tables[index].positionY = y
        }
        Task { await persistPosition(id: table.id, x: x, y: y) }
    }

    private func persistPosition(id: String, x: Double, y: Double) async {
        do {
            _ = try await supabase.update(
                "tables",
                values: TablePositionPatch(position_x: x, position_y: y),
                query: [URLQueryItem(name: "id", value: "eq.\(id)")],
                returning: [SeatingTable].self
            )
        } catch {
            report(error)
        }
    }

    func deleteTable(_ table: SeatingTable) async {
        let tableSnapshot = tables
        let guestSnapshot = guests
        tables.removeAll { $0.id == table.id }
        // Locally unassign guests that were at this table.
        for index in guests.indices where guests[index].tableId == table.id {
            guests[index].tableId = nil
        }
        do {
            try await supabase.delete("tables", query: [URLQueryItem(name: "id", value: "eq.\(table.id)")])
        } catch {
            tables = tableSnapshot
            guests = guestSnapshot
            report(error)
        }
    }

    // MARK: - Rooms

    @discardableResult
    func addRoom(name: String,
                 widthFt: Double,
                 heightFt: Double,
                 positionX: Double,
                 positionY: Double,
                 color: String?) async throws -> FloorPlanRoom {
        let rows = try await supabase.insert(
            "floorplan_rooms",
            values: NewRoomDTO(event_id: event.id, name: name,
                               width_ft: widthFt, height_ft: heightFt,
                               position_x: positionX, position_y: positionY,
                               color: color),
            returning: [FloorPlanRoom].self
        )
        guard let room = rows.first else { throw SupabaseError.decoding("No room returned.") }
        rooms.append(room)
        return room
    }

    /// Saves a room edit (name, size, color). Optimistic with rollback.
    @discardableResult
    func updateRoom(_ room: FloorPlanRoom,
                    name: String,
                    widthFt: Double,
                    heightFt: Double,
                    color: String?) async -> FloorPlanRoom? {
        guard let index = rooms.firstIndex(where: { $0.id == room.id }) else { return nil }
        let previous = rooms[index]
        rooms[index].name = name
        rooms[index].widthFt = widthFt
        rooms[index].heightFt = heightFt
        rooms[index].color = color
        do {
            let rows = try await supabase.update(
                "floorplan_rooms",
                values: RoomUpdateDTO(name: name, width_ft: widthFt, height_ft: heightFt, color: color),
                query: [URLQueryItem(name: "id", value: "eq.\(room.id)")],
                returning: [FloorPlanRoom].self
            )
            if let updated = rows.first { rooms[index] = updated }
            return rooms[index]
        } catch {
            rooms[index] = previous
            report(error)
            return nil
        }
    }

    /// Commits a moved room's new position (top-left). See `updatePosition`.
    func updateRoomPosition(of room: FloorPlanRoom, x: Double, y: Double) {
        if let index = rooms.firstIndex(where: { $0.id == room.id }) {
            rooms[index].positionX = x
            rooms[index].positionY = y
        }
        Task { await persist(table: "floorplan_rooms", id: room.id, x: x, y: y) }
    }

    func deleteRoom(_ room: FloorPlanRoom) async {
        let snapshot = rooms
        rooms.removeAll { $0.id == room.id }
        do {
            try await supabase.delete("floorplan_rooms",
                                      query: [URLQueryItem(name: "id", value: "eq.\(room.id)")])
        } catch {
            rooms = snapshot
            report(error)
        }
    }

    // MARK: - Shapes (decorative objects)

    @discardableResult
    func addShape(name: String,
                  type: TableShape,
                  width: Double,
                  height: Double,
                  positionX: Double,
                  positionY: Double,
                  description: String? = nil) async throws -> DecorShape {
        let rows = try await supabase.insert(
            "shapes",
            values: NewShapeDTO(event_id: event.id, name: name, type: type.rawValue,
                                width: width, height: height,
                                position_x: positionX, position_y: positionY,
                                rotation: 0, description: description),
            returning: [DecorShape].self
        )
        guard let shape = rows.first else { throw SupabaseError.decoding("No shape returned.") }
        shapes.append(shape)
        return shape
    }

    /// Saves a shape edit (name, type, size, note). Optimistic with rollback.
    @discardableResult
    func updateShape(_ shape: DecorShape,
                     name: String,
                     type: TableShape,
                     width: Double,
                     height: Double,
                     description: String?) async -> DecorShape? {
        guard let index = shapes.firstIndex(where: { $0.id == shape.id }) else { return nil }
        let previous = shapes[index]
        shapes[index].name = name
        shapes[index].type = type
        shapes[index].width = width
        shapes[index].height = height
        shapes[index].description = description
        do {
            let rows = try await supabase.update(
                "shapes",
                values: ShapeUpdateDTO(name: name, type: type.rawValue,
                                       width: width, height: height, description: description),
                query: [URLQueryItem(name: "id", value: "eq.\(shape.id)")],
                returning: [DecorShape].self
            )
            if let updated = rows.first { shapes[index] = updated }
            return shapes[index]
        } catch {
            shapes[index] = previous
            report(error)
            return nil
        }
    }

    /// Inserts a copy of a shape, offset one foot so it doesn't sit on top.
    func duplicateShape(_ shape: DecorShape) async {
        let offset = TableScale.pointsPerFoot
        do {
            let rows = try await supabase.insert(
                "shapes",
                values: NewShapeDTO(event_id: event.id, name: "\(shape.name) copy",
                                    type: shape.type.rawValue,
                                    width: shape.width, height: shape.height,
                                    position_x: (shape.positionX ?? 0) + offset,
                                    position_y: (shape.positionY ?? 0) + offset,
                                    rotation: shape.rotation ?? 0,
                                    description: shape.description),
                returning: [DecorShape].self
            )
            if let new = rows.first { shapes.append(new) }
        } catch {
            report(error)
        }
    }

    /// Persists a shape's rotation (normalised to 0..<360).
    func updateShapeRotation(of shape: DecorShape, to degrees: Double) async {
        let normalized = ((degrees.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        if let index = shapes.firstIndex(where: { $0.id == shape.id }) {
            shapes[index].rotation = normalized
        }
        do {
            _ = try await supabase.update(
                "shapes",
                values: ShapeRotationPatch(rotation: normalized),
                query: [URLQueryItem(name: "id", value: "eq.\(shape.id)")],
                returning: [DecorShape].self
            )
        } catch {
            report(error)
        }
    }

    /// Commits a moved shape's new position (top-left). See `updatePosition`.
    func updateShapePosition(of shape: DecorShape, x: Double, y: Double) {
        if let index = shapes.firstIndex(where: { $0.id == shape.id }) {
            shapes[index].positionX = x
            shapes[index].positionY = y
        }
        Task { await persist(table: "shapes", id: shape.id, x: x, y: y) }
    }

    func deleteShape(_ shape: DecorShape) async {
        let snapshot = shapes
        shapes.removeAll { $0.id == shape.id }
        do {
            try await supabase.delete("shapes",
                                      query: [URLQueryItem(name: "id", value: "eq.\(shape.id)")])
        } catch {
            shapes = snapshot
            report(error)
        }
    }

    /// Shared position write for rooms/shapes (tables keep their own helper for
    /// the synchronous-local-update contract documented on `updatePosition`).
    private func persist(table: String, id: String, x: Double, y: Double) async {
        do {
            _ = try await supabase.update(
                table,
                values: TablePositionPatch(position_x: x, position_y: y),
                query: [URLQueryItem(name: "id", value: "eq.\(id)")],
                returning: [EmptyRow].self
            )
        } catch {
            report(error)
        }
    }

    // MARK: - Templates (per-user, reusable layouts)

    /// Loads the signed-in user's saved templates, newest first. Non-fatal.
    func fetchTemplates() async {
        guard let uid = await supabase.currentUser?.id else { return }
        do {
            templates = try await supabase.select(
                "floorplan_templates",
                query: [URLQueryItem(name: "select", value: "*"),
                        URLQueryItem(name: "user_id", value: "eq.\(uid)"),
                        URLQueryItem(name: "order", value: "updated_at.desc")],
                as: [FloorPlanTemplate].self
            )
        } catch {
            report(error)
        }
    }

    /// Saves the event's current tables + rooms as a new template, or overwrites
    /// an existing one. Returns the saved template on success. Mirrors the web's
    /// `saveTemplate` (incl. the legacy first-room dimensions for back-compat).
    @discardableResult
    func saveTemplate(name: String, overwriteId: String? = nil) async -> FloorPlanTemplate? {
        guard let uid = await supabase.currentUser?.id else {
            errorMessage = "You must be signed in to save templates."
            return nil
        }
        let tablesJson = tables.map(TemplateTable.init(table:))
        let roomsJson = rooms.map(TemplateRoom.init(room:))
        // Back-compat: also stash the first room's dimensions in the legacy fields.
        let firstRoom = rooms.first
        do {
            let saved: FloorPlanTemplate
            if let overwriteId {
                let rows = try await supabase.update(
                    "floorplan_templates",
                    values: TemplateUpdateDTO(name: name, tables_json: tablesJson, rooms_json: roomsJson,
                                              room_width_ft: firstRoom?.widthFt, room_height_ft: firstRoom?.heightFt),
                    query: [URLQueryItem(name: "id", value: "eq.\(overwriteId)"),
                            URLQueryItem(name: "user_id", value: "eq.\(uid)")],
                    returning: [FloorPlanTemplate].self
                )
                guard let row = rows.first else { throw SupabaseError.decoding("No template returned.") }
                saved = row
                if let index = templates.firstIndex(where: { $0.id == overwriteId }) {
                    templates[index] = saved
                } else {
                    templates.insert(saved, at: 0)
                }
            } else {
                let rows = try await supabase.insert(
                    "floorplan_templates",
                    values: TemplateInsertDTO(user_id: uid, name: name,
                                              tables_json: tablesJson, rooms_json: roomsJson,
                                              room_width_ft: firstRoom?.widthFt, room_height_ft: firstRoom?.heightFt),
                    returning: [FloorPlanTemplate].self
                )
                guard let row = rows.first else { throw SupabaseError.decoding("No template returned.") }
                saved = row
                templates.insert(saved, at: 0)
            }
            return saved
        } catch {
            report(error)
            return nil
        }
    }

    /// Applies a template to this event, **replacing** all current tables and
    /// rooms (matching the web's load-template behaviour). Decorative shapes are
    /// left untouched. Seated guests at the removed tables become unassigned (the
    /// `tables` FK is `ON DELETE SET NULL`). On any failure the event is re-synced
    /// from the server so local state never diverges.
    func applyTemplate(_ template: FloorPlanTemplate) async {
        // Snapshot the layout being replaced so the apply can be undone (F3).
        let priorTables = tables
        let priorRooms = rooms
        var priorAssignments: [String: String?] = [:]
        for guest in guests { priorAssignments[guest.id] = guest.tableId }

        do {
            // 1. Clear the existing layout (tables + rooms) for this event.
            try await supabase.delete("tables", query: [eventFilter])
            try await supabase.delete("floorplan_rooms", query: [eventFilter])

            // 2. Bulk-insert the template's tables, then rooms.
            var newTables: [SeatingTable] = []
            if !template.tablesJson.isEmpty {
                let dtos = template.tablesJson.map { t in
                    NewTableDTO(event_id: event.id, name: t.name, shape: t.shape,
                                capacity: t.capacity, width: t.width, height: t.height,
                                position_x: t.positionX, position_y: t.positionY,
                                rotation: t.rotation, description: t.description,
                                is_custom: t.isCustom ?? false)
                }
                newTables = try await supabase.insert("tables", values: dtos, returning: [SeatingTable].self)
            }
            var newRooms: [FloorPlanRoom] = []
            if !template.roomsJson.isEmpty {
                let dtos = template.roomsJson.map { r in
                    NewRoomDTO(event_id: event.id, name: r.name,
                               width_ft: r.widthFt, height_ft: r.heightFt,
                               position_x: r.positionX, position_y: r.positionY,
                               color: r.color, sort_order: r.sortOrder)
                }
                newRooms = try await supabase.insert("floorplan_rooms", values: dtos, returning: [FloorPlanRoom].self)
            }

            // 3. Commit locally: swap in the new layout, unassign every guest.
            tables = newTables
            rooms = newRooms.sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
            for index in guests.indices { guests[index].tableId = nil }

            // 4. Offer an undo that rebuilds the prior layout and re-seats guests.
            undo.show("Applied “\(template.name).”") { [weak self] in
                guard let self else { return }
                Task {
                    await self.restoreLayout(priorTables: priorTables,
                                             priorRooms: priorRooms,
                                             assignments: priorAssignments)
                }
            }
        } catch {
            report(error)
            // Re-sync so we never show a half-applied layout.
            await loadAll()
        }
    }

    /// Rebuilds a previously-replaced layout (Undo after apply-template). Re-inserts
    /// the prior tables/rooms (minting new ids), maps old→new table ids by insertion
    /// order, and re-seats every guest at their former table.
    private func restoreLayout(priorTables: [SeatingTable],
                               priorRooms: [FloorPlanRoom],
                               assignments: [String: String?]) async {
        do {
            try await supabase.delete("tables", query: [eventFilter])
            try await supabase.delete("floorplan_rooms", query: [eventFilter])

            var newTables: [SeatingTable] = []
            if !priorTables.isEmpty {
                let dtos = priorTables.map { t in
                    NewTableDTO(event_id: event.id, name: t.name,
                                shape: (t.shape ?? .circle).rawValue,
                                capacity: t.capacity ?? 0, width: t.width, height: t.height,
                                position_x: t.positionX ?? 0, position_y: t.positionY ?? 0,
                                rotation: t.rotation ?? 0, description: t.description,
                                is_custom: t.isCustom ?? false)
                }
                newTables = try await supabase.insert("tables", values: dtos, returning: [SeatingTable].self)
            }
            var newRooms: [FloorPlanRoom] = []
            if !priorRooms.isEmpty {
                let dtos = priorRooms.map { r in
                    NewRoomDTO(event_id: event.id, name: r.name,
                               width_ft: r.widthFt, height_ft: r.heightFt,
                               position_x: r.positionX ?? 0, position_y: r.positionY ?? 0,
                               color: r.color, sort_order: r.sortOrder)
                }
                newRooms = try await supabase.insert("floorplan_rooms", values: dtos, returning: [FloorPlanRoom].self)
            }

            // Map old table id → new table id by insertion order.
            var idMap: [String: String] = [:]
            for (old, new) in zip(priorTables, newTables) { idMap[old.id] = new.id }

            tables = newTables
            rooms = newRooms.sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }

            // Re-seat guests at their former (now re-created) tables.
            var byNewTable: [String: [String]] = [:]
            for (guestId, oldTable) in assignments {
                guard let oldTable, let newTable = idMap[oldTable] else { continue }
                byNewTable[newTable, default: []].append(guestId)
            }
            for index in guests.indices { guests[index].tableId = nil }
            for (newTable, guestIds) in byNewTable {
                for gid in guestIds {
                    if let index = guests.firstIndex(where: { $0.id == gid }) {
                        guests[index].tableId = newTable
                    }
                }
                _ = try await supabase.update(
                    "guests",
                    values: GuestTablePatch(table_id: newTable),
                    query: [URLQueryItem(name: "id", value: "in.(\(guestIds.joined(separator: ",")))")],
                    returning: [Guest].self
                )
            }
        } catch {
            report(error)
            await loadAll()
        }
    }

    /// Deletes a saved template. Optimistic with rollback.
    func deleteTemplate(_ template: FloorPlanTemplate) async {
        let snapshot = templates
        templates.removeAll { $0.id == template.id }
        do {
            try await supabase.delete("floorplan_templates",
                                      query: [URLQueryItem(name: "id", value: "eq.\(template.id)")])
        } catch {
            templates = snapshot
            report(error)
        }
    }

    // MARK: - Lookups

    func table(withId id: String?) -> SeatingTable? {
        guard let id else { return nil }
        return tables.first { $0.id == id }
    }

    func occupancy(of table: SeatingTable) -> Int {
        SeatingLogic.occupancy(of: table.id, guests: guests)
    }
}
