//
//  SeatingStore.swift
//  A Seat Awaits
//
//  Owns the guests, tables, and groups for a single selected event, plus the
//  mutations the UI performs (add guest, assign to table, move tables, …).
//

import CoreGraphics
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
    let table_id: String?
}

/// One reviewed import row on its way to `SeatingStore.addGuests`.
nonisolated struct NewGuestDraft: Sendable {
    let name: String
    var groupName: String?
    var notes: String?
    var dietary: String?
}

nonisolated struct GuestTablePatch: Encodable, Sendable {
    let table_id: String?

    // Synthesized Encodable drops nil fields entirely, turning an unseat PATCH
    // into `{}` — a server-side no-op that resurrects the assignment on next
    // load. Encode nil as an explicit JSON null so PostgREST clears the column.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(table_id, forKey: .table_id)
    }

    private enum CodingKeys: String, CodingKey { case table_id }
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

/// Thrown by `SeatingStore.addGuest` when the event is at its entitled guest
/// cap. Carries curated, user-presentable copy (surfaced by `FriendlyError`).
nonisolated struct GuestCapReachedError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
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

/// The floor-plan canvas framing (zoom, scroll offset, sticky canvas box and
/// whether the one-time fit has run), owned by the store so it outlives the
/// `FloorPlanView` instance. The workspace swaps that view out every time the
/// planner visits the Guests tab; without this the canvas would snap back to
/// its initial fit on every return.
@MainActor
@Observable
final class FloorPlanViewState {
    var zoom: CGFloat = 1
    var scrollOffset: CGPoint = .zero
    var canvasBox: CGRect = .zero
    var didInitialFit = false
}

@MainActor
@Observable
final class SeatingStore {
    /// Canvas framing that survives tab switches (see `FloorPlanViewState`).
    let floorPlanState = FloorPlanViewState()
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

    /// The signed-in user's effective entitlement on this event: their entitled
    /// subscription merged with their Event Pass attached to this event (a pass
    /// never changes the subscription tier, so neither source alone is enough).
    /// UX gating only — the DB triggers and edge functions remain the real
    /// enforcement. Free until `loadEntitlement()` resolves.
    private(set) var entitlement = EventEntitlement.resolve(pass: nil, policy: .free)
    /// True once the entitlement fetch has completed (even unsuccessfully, which
    /// leaves the Free fallback in place). Cap warnings wait for this so a slow
    /// load never flashes a bogus "limit reached" at an entitled user.
    private(set) var entitlementLoaded = false

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
        // A cancelled request (the view went away, a newer load superseded
        // this one) is not a failure the planner needs to hear about.
        if error is CancellationError { return }
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
                                          query: [URLQueryItem(name: "select", value: "*"),
                                                  eventFilter,
                                                  URLQueryItem(name: "order", value: "created_at.asc.nullslast")],
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
        await loadEntitlement()
    }

    /// Resolves the viewer's entitlement for this event (see `entitlement`).
    /// Errors are non-fatal: the Free fallback stays, matching the web's
    /// fail-closed feature gates.
    func loadEntitlement() async {
        guard let userId = await supabase.currentUser?.id else {
            entitlementLoaded = true
            return
        }

        async let passTask = try? supabase.select(
            "event_passes",
            query: [
                URLQueryItem(name: "select", value: EventPass.selectColumns),
                eventFilter,
                URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            ],
            as: [EventPass].self)
        async let subscriptionTask = try? supabase.select(
            "subscriptions",
            query: [
                URLQueryItem(name: "select", value: SubscriptionRow.selectColumns),
                URLQueryItem(name: "user_id", value: "eq.\(userId)"),
                URLQueryItem(name: "order", value: "created_at.desc.nullslast"),
                URLQueryItem(name: "limit", value: "1"),
            ],
            as: [SubscriptionRow].self)
        async let profileTask = try? supabase.select(
            "users",
            query: [
                URLQueryItem(name: "select",
                             value: "id,full_name,subscription_tier,subscription_status,legacy_free,created_at,updated_at"),
                URLQueryItem(name: "id", value: "eq.\(userId)"),
            ],
            as: [UserProfile].self)
        let (passes, subscriptions, profiles) = await (passTask, subscriptionTask, profileTask)

        let policy = PlanPolicy.resolve(subscription: subscriptions?.first,
                                        fallbackTier: profiles?.first?.subscriptionTier,
                                        fallbackStatus: profiles?.first?.subscriptionStatus)
        entitlement = EventEntitlement.resolve(pass: passes?.first, policy: policy)
        entitlementLoaded = true
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

    /// Guest slots left on this event under the current entitlement. `nil` while
    /// the entitlement is still resolving, so callers never trim an import
    /// against a cap they don't know yet.
    var remainingGuestCapacity: Int? {
        guard entitlementLoaded else { return nil }
        return max(0, entitlement.guestCap - guests.count)
    }

    /// Shared upgrade copy for the cap gate. `wanted` is how many guests the
    /// caller is trying to add, so a bulk import can say exactly how far over
    /// the line it is instead of just "limit reached".
    func guestCapMessage(wanted: Int = 1) -> String {
        let room = max(0, entitlement.guestCap - guests.count)
        let base = "This event allows \(entitlement.guestCap) guests on \(entitlement.guestCapSourceLabel)."
        if room == 0 {
            return "Guest limit reached. \(base) Upgrade to add more."
        }
        if wanted > room {
            let over = wanted - room
            return "\(base) There's room for \(room) more, so \(over) \(over == 1 ? "guest doesn't" : "guests don't") fit. Deselect \(over) or upgrade for more room."
        }
        return base
    }

    @discardableResult
    func addGuest(name: String,
                  groupId: String?,
                  groupName: String?,
                  notes: String?,
                  dietary: String?,
                  tableId: String? = nil) async throws -> Guest {
        // UX-level cap guard (also stops a bulk import at the line): once the
        // entitlement is known, reject adds beyond the event's guest cap with
        // upgrade copy instead of letting the DB bounce the insert.
        if entitlementLoaded, guests.count >= entitlement.guestCap {
            throw GuestCapReachedError(message: guestCapMessage())
        }
        let rows = try await supabase.insert(
            "guests",
            values: NewGuestDTO(event_id: event.id,
                                name: name,
                                group_id: groupId,
                                group_name: groupName?.nilIfBlank,
                                notes: notes?.nilIfBlank,
                                dietary_preference: dietary?.nilIfBlank,
                                table_id: tableId),
            returning: [Guest].self
        )
        guard let guest = rows.first else { throw SupabaseError.decoding("No guest returned.") }
        guests.append(guest)
        markReachable()
        return guest
    }

    /// Bulk-inserts a reviewed import in chunks, so a 250-name list is a handful
    /// of requests instead of 250 round trips. The whole batch is checked against
    /// the event's guest cap up front (the review screen keeps the selection
    /// inside it), and `onProgress` reports the running total after each chunk so
    /// a mid-flight failure can still say exactly how many landed.
    @discardableResult
    func addGuests(_ drafts: [NewGuestDraft],
                   onProgress: (Int) -> Void = { _ in }) async throws -> Int {
        guard !drafts.isEmpty else { return 0 }
        if entitlementLoaded, guests.count + drafts.count > entitlement.guestCap {
            throw GuestCapReachedError(message: guestCapMessage(wanted: drafts.count))
        }
        var imported = 0
        for chunk in drafts.chunked(into: 100) {
            let rows = try await supabase.insert(
                "guests",
                values: chunk.map {
                    NewGuestDTO(event_id: event.id,
                                name: $0.name,
                                group_id: nil,
                                group_name: $0.groupName?.nilIfBlank,
                                notes: $0.notes?.nilIfBlank,
                                dietary_preference: $0.dietary?.nilIfBlank,
                                table_id: nil)
                },
                returning: [Guest].self)
            guests.append(contentsOf: rows)
            imported += rows.count
            onProgress(imported)
        }
        markReachable()
        return imported
    }

    /// Runs a pasted/CSV list or an Excel file through the `ai-import-guests`
    /// Edge Function (column-aware AI extraction — adults, partners and children,
    /// parity with the web app) and returns the structured `ParsedGuest`s for
    /// review. Throws on plan/rate-limit/AI failure or transport error —
    /// `ImportGuestsView` falls back to the on-device `GuestImportParser` so the
    /// import flow always works offline.
    func aiStructureGuests(_ input: GuestImportInput) async throws -> [ParsedGuest] {
        let service = GuestImportService(invoker: supabase)
        let response = try await service.aiImport(eventId: event.id, input: input)
        markReachable()
        return response.parsedGuests()
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
            // Re-resolve by id: the array may have been reordered or trimmed
            // while the request was in flight, so the captured index could
            // now point at a different guest.
            if let current = guests.firstIndex(where: { $0.id == guest.id }) {
                guests[current].tableId = previous.tableId
            }
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
        guard let removedIndex = guests.firstIndex(where: { $0.id == guest.id }) else { return }
        let removed = guests.remove(at: removedIndex)
        do {
            try await supabase.delete("guests", query: [URLQueryItem(name: "id", value: "eq.\(guest.id)")])
            markReachable()
        } catch {
            // Put just this guest back — never overwrite the whole array with
            // a pre-await snapshot, which would discard concurrent changes.
            reinsert(removed, into: &guests, preferredIndex: removedIndex)
            report(error)
        }
    }

    /// Re-inserts a removed element at its old index (or the end if the array
    /// has shrunk since), skipping the insert if it's somehow already present.
    private func reinsert<T: Identifiable>(_ element: T, into array: inout [T], preferredIndex: Int) {
        guard !array.contains(where: { $0.id == element.id }) else { return }
        array.insert(element, at: min(preferredIndex, array.count))
    }

    /// Deletes rows by id in chunks so a long id list never overruns the URL.
    private func deleteRows(from table: String, ids: [String]) async throws {
        for chunk in ids.chunked(into: 80) {
            try await supabase.delete(table, query: [
                URLQueryItem(name: "id", value: "in.(\(chunk.joined(separator: ",")))")
            ])
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
        undo.show("Deleted “\(restore.name)”.") { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.addGuest(
                        name: restore.name,
                        groupId: restore.groupId,
                        groupName: restore.groupName,
                        notes: restore.notes,
                        dietary: restore.dietaryPreference,
                        tableId: restore.tableId)
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
            if let updated = rows.first, let current = tables.firstIndex(where: { $0.id == table.id }) {
                tables[current] = updated
            }
            return tables.first { $0.id == table.id }
        } catch {
            // Re-resolve by id — the array may have changed during the await.
            if let current = tables.firstIndex(where: { $0.id == table.id }) {
                tables[current] = previous
            }
            report(error)
            return nil
        }
    }

    /// Every seatable footprint on the canvas (tables + shapes), for placement
    /// and collision checks. Rooms are containers and don't block placement.
    var placementObstacles: [FloorPlanGeometry.Item] {
        tables.map {
            FloorPlanGeometry.Item(id: $0.id, x: $0.positionX ?? 80, y: $0.positionY ?? 80,
                                   width: $0.width, height: $0.height, rotation: $0.rotationDegrees)
        } + shapes.map {
            FloorPlanGeometry.Item(id: $0.id, x: $0.positionX ?? 120, y: $0.positionY ?? 120,
                                   width: $0.width, height: $0.height, rotation: $0.rotationDegrees)
        }
    }

    /// Room footprints, for placing a new room clear of the existing ones.
    var roomObstacles: [FloorPlanGeometry.Item] {
        rooms.map {
            FloorPlanGeometry.Item(id: $0.id, x: $0.positionX, y: $0.positionY,
                                   width: $0.widthPoints, height: $0.heightPoints, rotation: 0)
        }
    }

    /// Where a new item should be centered when the caller has no viewport to
    /// go on (the Add sheet opened from the toolbar, say): the middle of the
    /// first room, else the middle of whatever is already on the canvas, else
    /// a comfortable spot near the origin. `FloorPlanGeometry.freePosition`
    /// then nudges it off anything already there.
    var defaultPlacementAnchor: (x: Double, y: Double) {
        if let room = rooms.first {
            return (room.positionX + room.widthPoints / 2, room.positionY + room.heightPoints / 2)
        }
        let items = placementObstacles
        guard !items.isEmpty else { return (180, 180) }
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for item in items {
            let b = FloorPlanGeometry.bounds(item)
            minX = min(minX, b.left); minY = min(minY, b.top)
            maxX = max(maxX, b.right); maxY = max(maxY, b.bottom)
        }
        return ((minX + maxX) / 2, (minY + maxY) / 2)
    }

    /// Where a copy of an item should land: immediately to its right with a
    /// one-foot gap, or the nearest free spot spiralling out from there when
    /// that space is taken. Never on top of the original.
    private func duplicatePosition(x: Double, y: Double,
                                   width: Double, height: Double) -> (x: Double, y: Double) {
        let gap = TableScale.pointsPerFoot
        let anchor = (x: x + width + gap + width / 2, y: y + height / 2)
        return FloorPlanGeometry.freePosition(near: anchor, size: (width, height),
                                              among: placementObstacles)
    }

    /// Inserts a copy of a table beside the original (never overlapping it).
    /// Guests are not copied. Returns the new table so the canvas can select it.
    @discardableResult
    func duplicateTable(_ table: SeatingTable) async -> SeatingTable? {
        let spot = duplicatePosition(x: table.positionX ?? 80, y: table.positionY ?? 80,
                                     width: table.width, height: table.height)
        do {
            let rows = try await supabase.insert(
                "tables",
                values: NewTableDTO(event_id: event.id,
                                    name: "\(table.name) copy",
                                    shape: (table.shape ?? .circle).rawValue,
                                    capacity: table.capacity ?? 0,
                                    width: table.width,
                                    height: table.height,
                                    position_x: spot.x,
                                    position_y: spot.y,
                                    rotation: table.rotation ?? 0,
                                    description: table.description,
                                    is_custom: table.isCustom ?? false),
                returning: [SeatingTable].self
            )
            guard let new = rows.first else { return nil }
            tables.append(new)
            markReachable()
            return new
        } catch {
            report(error)
            return nil
        }
    }

    /// Commits a rotation from the canvas twist gesture. Like `updatePosition`,
    /// the local model is updated *synchronously* so the gesture can clear its
    /// live state in the same render pass without the item flashing back to its
    /// old angle; the write happens in the background.
    func commitRotation(of table: SeatingTable, to degrees: Double) {
        Task { await updateRotation(of: table, to: degrees) }
    }

    /// Persists a table's rotation (normalised to 0..<360). The local angle is
    /// applied synchronously before the first suspension and rolled back (by
    /// id, and only if nothing newer replaced it) when the write fails.
    func updateRotation(of table: SeatingTable, to degrees: Double) async {
        let normalized = ((degrees.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        guard let index = tables.firstIndex(where: { $0.id == table.id }) else { return }
        let previous = tables[index].rotation
        tables[index].rotation = normalized
        do {
            _ = try await supabase.update(
                "tables",
                values: TableRotationPatch(rotation: normalized),
                query: [URLQueryItem(name: "id", value: "eq.\(table.id)")],
                returning: [SeatingTable].self
            )
            markReachable()
        } catch {
            if let current = tables.firstIndex(where: { $0.id == table.id }),
               tables[current].rotation == normalized {
                tables[current].rotation = previous
            }
            report(error)
        }
    }

    /// Commits a moved table's new position. The local model is updated
    /// *synchronously* so the caller can clear its drag offset in the same render
    /// pass without the table flashing back to its old spot; the write to the
    /// backend happens in the background and rolls the move back on failure.
    func updatePosition(of table: SeatingTable, x: Double, y: Double) {
        guard let index = tables.firstIndex(where: { $0.id == table.id }) else { return }
        let previous = (x: tables[index].positionX, y: tables[index].positionY)
        tables[index].positionX = x
        tables[index].positionY = y
        Task {
            await persist(table: "tables", id: table.id, x: x, y: y) { [weak self] in
                guard let self,
                      let current = self.tables.firstIndex(where: { $0.id == table.id }),
                      self.tables[current].positionX == x, self.tables[current].positionY == y
                else { return }
                self.tables[current].positionX = previous.x
                self.tables[current].positionY = previous.y
            }
        }
    }

    func deleteTable(_ table: SeatingTable) async {
        guard let removedIndex = tables.firstIndex(where: { $0.id == table.id }) else { return }
        let removed = tables.remove(at: removedIndex)
        // Locally unassign guests that were at this table, remembering who.
        var unseated: [String] = []
        for index in guests.indices where guests[index].tableId == table.id {
            guests[index].tableId = nil
            unseated.append(guests[index].id)
        }
        do {
            try await supabase.delete("tables", query: [URLQueryItem(name: "id", value: "eq.\(table.id)")])
            markReachable()
        } catch {
            reinsert(removed, into: &tables, preferredIndex: removedIndex)
            for id in unseated {
                if let index = guests.firstIndex(where: { $0.id == id }), guests[index].tableId == nil {
                    guests[index].tableId = table.id
                }
            }
            report(error)
        }
    }

    /// Deletes a table immediately, then offers an undo that re-creates it
    /// (new row id) and re-seats everyone who was at it.
    func deleteTableWithUndo(_ table: SeatingTable) async {
        let restore = tables.first { $0.id == table.id } ?? table
        let seatedIds = guests.filter { $0.tableId == table.id }.map(\.id)
        await deleteTable(table)
        guard errorMessage == nil, !tables.contains(where: { $0.id == table.id }) else { return }
        undo.show("Deleted “\(restore.name)”.") { [weak self] in
            guard let self else { return }
            Task {
                do {
                    let new = try await self.addTable(name: restore.name,
                                                      shape: restore.shape ?? .circle,
                                                      capacity: restore.capacity ?? 0,
                                                      width: restore.width,
                                                      height: restore.height,
                                                      positionX: restore.positionX ?? 80,
                                                      positionY: restore.positionY ?? 80,
                                                      description: restore.description,
                                                      rotation: restore.rotation ?? 0,
                                                      isCustom: restore.isCustom ?? false)
                    let batch = self.guests.filter { seatedIds.contains($0.id) }
                    if !batch.isEmpty { await self.assign(batch, toTable: new.id) }
                } catch {
                    self.report(error)
                }
            }
        }
    }

    // MARK: - Rooms

    @discardableResult
    func addRoom(name: String,
                 widthFt: Double,
                 heightFt: Double,
                 positionX: Double,
                 positionY: Double) async throws -> FloorPlanRoom {
        let rows = try await supabase.insert(
            "floorplan_rooms",
            values: NewRoomDTO(event_id: event.id, name: name,
                               width_ft: widthFt, height_ft: heightFt,
                               position_x: positionX, position_y: positionY,
                               color: nil),
            returning: [FloorPlanRoom].self
        )
        guard let room = rows.first else { throw SupabaseError.decoding("No room returned.") }
        rooms.append(room)
        return room
    }

    /// Saves a room edit (name, size). Optimistic with rollback. Always writes
    /// a NULL color so rooms saved by older builds shed their custom tint.
    @discardableResult
    func updateRoom(_ room: FloorPlanRoom,
                    name: String,
                    widthFt: Double,
                    heightFt: Double) async -> FloorPlanRoom? {
        guard let index = rooms.firstIndex(where: { $0.id == room.id }) else { return nil }
        let previous = rooms[index]
        rooms[index].name = name
        rooms[index].widthFt = widthFt
        rooms[index].heightFt = heightFt
        rooms[index].color = nil
        do {
            let rows = try await supabase.update(
                "floorplan_rooms",
                values: RoomUpdateDTO(name: name, width_ft: widthFt, height_ft: heightFt, color: nil),
                query: [URLQueryItem(name: "id", value: "eq.\(room.id)")],
                returning: [FloorPlanRoom].self
            )
            if let updated = rows.first, let current = rooms.firstIndex(where: { $0.id == room.id }) {
                rooms[current] = updated
            }
            return rooms.first { $0.id == room.id }
        } catch {
            if let current = rooms.firstIndex(where: { $0.id == room.id }) {
                rooms[current] = previous
            }
            report(error)
            return nil
        }
    }

    /// Commits a moved room's new position (top-left). See `updatePosition`.
    func updateRoomPosition(of room: FloorPlanRoom, x: Double, y: Double) {
        guard let index = rooms.firstIndex(where: { $0.id == room.id }) else { return }
        let previous = (x: rooms[index].positionX, y: rooms[index].positionY)
        rooms[index].positionX = x
        rooms[index].positionY = y
        Task {
            await persist(table: "floorplan_rooms", id: room.id, x: x, y: y) { [weak self] in
                guard let self,
                      let current = self.rooms.firstIndex(where: { $0.id == room.id }),
                      self.rooms[current].positionX == x, self.rooms[current].positionY == y
                else { return }
                self.rooms[current].positionX = previous.x
                self.rooms[current].positionY = previous.y
            }
        }
    }

    func deleteRoom(_ room: FloorPlanRoom) async {
        guard let removedIndex = rooms.firstIndex(where: { $0.id == room.id }) else { return }
        let removed = rooms.remove(at: removedIndex)
        do {
            try await supabase.delete("floorplan_rooms",
                                      query: [URLQueryItem(name: "id", value: "eq.\(room.id)")])
            markReachable()
        } catch {
            reinsert(removed, into: &rooms, preferredIndex: removedIndex)
            report(error)
        }
    }

    /// Deletes a room immediately with an undo that re-creates it in place.
    func deleteRoomWithUndo(_ room: FloorPlanRoom) async {
        let restore = rooms.first { $0.id == room.id } ?? room
        await deleteRoom(room)
        guard errorMessage == nil, !rooms.contains(where: { $0.id == room.id }) else { return }
        undo.show("Deleted “\(restore.name)”.") { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.addRoom(name: restore.name,
                                           widthFt: restore.widthFt, heightFt: restore.heightFt,
                                           positionX: restore.positionX, positionY: restore.positionY)
                } catch {
                    self.report(error)
                }
            }
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
            if let updated = rows.first, let current = shapes.firstIndex(where: { $0.id == shape.id }) {
                shapes[current] = updated
            }
            return shapes.first { $0.id == shape.id }
        } catch {
            if let current = shapes.firstIndex(where: { $0.id == shape.id }) {
                shapes[current] = previous
            }
            report(error)
            return nil
        }
    }

    /// Inserts a copy of a shape beside the original (never overlapping it).
    /// Returns the new shape so the canvas can select it.
    @discardableResult
    func duplicateShape(_ shape: DecorShape) async -> DecorShape? {
        let spot = duplicatePosition(x: shape.positionX ?? 120, y: shape.positionY ?? 120,
                                     width: shape.width, height: shape.height)
        do {
            let rows = try await supabase.insert(
                "shapes",
                values: NewShapeDTO(event_id: event.id, name: "\(shape.name) copy",
                                    type: shape.type.rawValue,
                                    width: shape.width, height: shape.height,
                                    position_x: spot.x,
                                    position_y: spot.y,
                                    rotation: shape.rotation ?? 0,
                                    description: shape.description),
                returning: [DecorShape].self
            )
            guard let new = rows.first else { return nil }
            shapes.append(new)
            markReachable()
            return new
        } catch {
            report(error)
            return nil
        }
    }

    /// Commits a shape rotation from the canvas twist gesture. See `commitRotation`.
    func commitShapeRotation(of shape: DecorShape, to degrees: Double) {
        Task { await updateShapeRotation(of: shape, to: degrees) }
    }

    /// Persists a shape's rotation (normalised to 0..<360), applying it locally
    /// first and rolling back by id if the write fails.
    func updateShapeRotation(of shape: DecorShape, to degrees: Double) async {
        let normalized = ((degrees.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        guard let index = shapes.firstIndex(where: { $0.id == shape.id }) else { return }
        let previous = shapes[index].rotation
        shapes[index].rotation = normalized
        do {
            _ = try await supabase.update(
                "shapes",
                values: ShapeRotationPatch(rotation: normalized),
                query: [URLQueryItem(name: "id", value: "eq.\(shape.id)")],
                returning: [DecorShape].self
            )
            markReachable()
        } catch {
            if let current = shapes.firstIndex(where: { $0.id == shape.id }),
               shapes[current].rotation == normalized {
                shapes[current].rotation = previous
            }
            report(error)
        }
    }

    /// Commits a moved shape's new position (top-left). See `updatePosition`.
    func updateShapePosition(of shape: DecorShape, x: Double, y: Double) {
        guard let index = shapes.firstIndex(where: { $0.id == shape.id }) else { return }
        let previous = (x: shapes[index].positionX, y: shapes[index].positionY)
        shapes[index].positionX = x
        shapes[index].positionY = y
        Task {
            await persist(table: "shapes", id: shape.id, x: x, y: y) { [weak self] in
                guard let self,
                      let current = self.shapes.firstIndex(where: { $0.id == shape.id }),
                      self.shapes[current].positionX == x, self.shapes[current].positionY == y
                else { return }
                self.shapes[current].positionX = previous.x
                self.shapes[current].positionY = previous.y
            }
        }
    }

    func deleteShape(_ shape: DecorShape) async {
        guard let removedIndex = shapes.firstIndex(where: { $0.id == shape.id }) else { return }
        let removed = shapes.remove(at: removedIndex)
        do {
            try await supabase.delete("shapes",
                                      query: [URLQueryItem(name: "id", value: "eq.\(shape.id)")])
            markReachable()
        } catch {
            reinsert(removed, into: &shapes, preferredIndex: removedIndex)
            report(error)
        }
    }

    /// Deletes a shape immediately with an undo that re-creates it in place.
    func deleteShapeWithUndo(_ shape: DecorShape) async {
        let restore = shapes.first { $0.id == shape.id } ?? shape
        await deleteShape(shape)
        guard errorMessage == nil, !shapes.contains(where: { $0.id == shape.id }) else { return }
        undo.show("Deleted “\(restore.name)”.") { [weak self] in
            guard let self else { return }
            Task {
                do {
                    let new = try await self.addShape(name: restore.name, type: restore.type,
                                                      width: restore.width, height: restore.height,
                                                      positionX: restore.positionX ?? 120,
                                                      positionY: restore.positionY ?? 120,
                                                      description: restore.description)
                    if restore.rotationDegrees != 0 {
                        await self.updateShapeRotation(of: new, to: restore.rotationDegrees)
                    }
                } catch {
                    self.report(error)
                }
            }
        }
    }

    /// Shared position write for tables/rooms/shapes. The caller has already
    /// applied the move locally; `rollback` runs on failure to undo it (by id,
    /// and only if no newer move superseded it).
    private func persist(table: String, id: String, x: Double, y: Double,
                         rollback: @escaping @MainActor () -> Void) async {
        do {
            _ = try await supabase.update(
                table,
                values: TablePositionPatch(position_x: x, position_y: y),
                query: [URLQueryItem(name: "id", value: "eq.\(id)")],
                returning: [EmptyRow].self
            )
            markReachable()
        } catch {
            rollback()
            report(error)
        }
    }

    // MARK: - AI floor plan import

    /// Sends an uploaded floor plan (photo/scan/PDF) through the
    /// `ai-import-floorplan` Edge Function — the same consensus vision pipeline
    /// as the web — and returns the canvas-ready plan for review. Throws on
    /// plan/rate-limit/AI failure or transport error (no on-device fallback).
    func aiAnalyzeFloorPlan(fileData: Data, filename: String,
                            contentType: String) async throws -> AiFloorplanImportResponse {
        let service = FloorPlanImportService(invoker: supabase)
        let response = try await service.analyze(eventId: event.id, fileData: fileData,
                                                 filename: filename, contentType: contentType)
        markReachable()
        return response
    }

    /// Applies a reviewed AI import: creates the room (when the plan had a
    /// measurable scale) to the RIGHT of any existing rooms — additive, never
    /// burying what's already on the canvas — then bulk-inserts fixtures and
    /// tables offset into it. Mirrors the web's apply handler, including
    /// continuing "Table N" numbering after existing tables.
    func applyImportedFloorPlan(_ plan: ImportedFloorPlan) async throws {
        // Place the import to the right of every existing room.
        let roomGapPoints: Double = 48
        let offsetX = rooms.reduce(0.0) { edge, room in
            max(edge, room.positionX + room.widthPoints + roomGapPoints)
        }
        let offsetY: Double = 0

        if let planRoom = plan.room {
            let sortOrder = rooms.compactMap(\.sortOrder).max().map { $0 + 1 }
            let inserted = try await supabase.insert(
                "floorplan_rooms",
                values: NewRoomDTO(event_id: event.id, name: planRoom.name,
                                   width_ft: planRoom.widthFt, height_ft: planRoom.heightFt,
                                   position_x: offsetX, position_y: offsetY,
                                   color: nil, sort_order: sortOrder),
                returning: [FloorPlanRoom].self
            )
            if let room = inserted.first { rooms.append(room) }
        }

        if !plan.shapes.isEmpty {
            let dtos = plan.shapes.map { s in
                NewShapeDTO(event_id: event.id, name: s.name, type: s.type,
                            width: s.width, height: s.height,
                            position_x: s.positionX + offsetX,
                            position_y: s.positionY + offsetY,
                            rotation: s.rotation)
            }
            let inserted = try await supabase.insert("shapes", values: dtos,
                                                     returning: [DecorShape].self)
            shapes.append(contentsOf: inserted)
        }

        if !plan.tables.isEmpty {
            // Continue "Table N" numbering after existing tables; uniqueName
            // stays as the final guard for non-generic collisions ("Head Table").
            let renumbered = FloorPlanImportNaming.renumber(plan.tables,
                                                            after: tables.map(\.name))
            var existingNames = Set(tables.map(\.name))
            let dtos = renumbered.map { t in
                let name = FloorPlanImportNaming.uniqueName(t.name, existing: existingNames)
                existingNames.insert(name)
                return NewTableDTO(event_id: event.id, name: name, shape: t.shape,
                                   capacity: t.capacity, width: t.width, height: t.height,
                                   position_x: t.positionX + offsetX,
                                   position_y: t.positionY + offsetY,
                                   rotation: t.rotation,
                                   is_custom: t.isCustom)
            }
            let inserted = try await supabase.insert("tables", values: dtos,
                                                     returning: [SeatingTable].self)
            tables.append(contentsOf: inserted)
        }
        markReachable()
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

    /// Swaps the event's layout: inserts the new tables + rooms FIRST, and only
    /// once every insert has landed deletes the old rows by id. The old order
    /// (delete everything, then insert) left the event empty whenever the
    /// insert failed. If a delete fails after the inserts, the freshly inserted
    /// rows are removed again (best effort) so the server never holds both
    /// layouts, and the caller re-syncs. Local state is untouched until the
    /// whole swap succeeds.
    private func replaceLayout(tables tableDTOs: [NewTableDTO],
                               rooms roomDTOs: [NewRoomDTO],
                               removingTables oldTables: [SeatingTable],
                               removingRooms oldRooms: [FloorPlanRoom])
        async throws -> (tables: [SeatingTable], rooms: [FloorPlanRoom]) {
        var newTables: [SeatingTable] = []
        var newRooms: [FloorPlanRoom] = []
        func rollBackInserts() async {
            // Best effort: a failure here is reported by the caller's reload.
            try? await deleteRows(from: "tables", ids: newTables.map(\.id))
            try? await deleteRows(from: "floorplan_rooms", ids: newRooms.map(\.id))
        }
        do {
            if !tableDTOs.isEmpty {
                newTables = try await supabase.insert("tables", values: tableDTOs,
                                                      returning: [SeatingTable].self)
            }
            if !roomDTOs.isEmpty {
                newRooms = try await supabase.insert("floorplan_rooms", values: roomDTOs,
                                                     returning: [FloorPlanRoom].self)
            }
            // Rooms first: if the table delete then fails, the rollback leaves
            // the planner with their tables (guests still seated) and no room,
            // rather than rooms and no tables.
            try await deleteRows(from: "floorplan_rooms", ids: oldRooms.map(\.id))
            try await deleteRows(from: "tables", ids: oldTables.map(\.id))
        } catch {
            await rollBackInserts()
            throw error
        }
        return (newTables, newRooms.sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) })
    }

    /// Applies a template to this event, **replacing** all current tables and
    /// rooms (matching the web's load-template behaviour). Decorative shapes are
    /// left untouched. Seated guests at the removed tables become unassigned (the
    /// `tables` FK is `ON DELETE SET NULL`). Built-in starter layouts flow
    /// through here too; nothing ever touches the server's template table. On
    /// any failure the event is re-synced from the server so local state never
    /// diverges.
    func applyTemplate(_ template: FloorPlanTemplate) async {
        // Snapshot the layout being replaced so the apply can be undone (F3).
        let priorTables = tables
        let priorRooms = rooms
        var priorAssignments: [String: String?] = [:]
        for guest in guests { priorAssignments[guest.id] = guest.tableId }

        let tableDTOs = template.tablesJson.map { t in
            NewTableDTO(event_id: event.id, name: t.name, shape: t.shape,
                        capacity: t.capacity, width: t.width, height: t.height,
                        position_x: t.positionX, position_y: t.positionY,
                        rotation: t.rotation, description: t.description,
                        is_custom: t.isCustom ?? false)
        }
        let roomDTOs = template.roomsJson.map { r in
            NewRoomDTO(event_id: event.id, name: r.name,
                       width_ft: r.widthFt, height_ft: r.heightFt,
                       position_x: r.positionX, position_y: r.positionY,
                       color: nil, sort_order: r.sortOrder)
        }

        do {
            let new = try await replaceLayout(tables: tableDTOs, rooms: roomDTOs,
                                              removingTables: priorTables, removingRooms: priorRooms)

            // Commit locally: swap in the new layout, unassign every guest.
            tables = new.tables
            rooms = new.rooms
            for index in guests.indices { guests[index].tableId = nil }
            markReachable()

            // Offer an undo that rebuilds the prior layout and re-seats guests.
            undo.show("Applied “\(template.name)”.") { [weak self] in
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
        let tableDTOs = priorTables.map { t in
            NewTableDTO(event_id: event.id, name: t.name,
                        shape: (t.shape ?? .circle).rawValue,
                        capacity: t.capacity ?? 0, width: t.width, height: t.height,
                        position_x: t.positionX ?? 0, position_y: t.positionY ?? 0,
                        rotation: t.rotation ?? 0, description: t.description,
                        is_custom: t.isCustom ?? false)
        }
        let roomDTOs = priorRooms.map { r in
            NewRoomDTO(event_id: event.id, name: r.name,
                       width_ft: r.widthFt, height_ft: r.heightFt,
                       position_x: r.positionX, position_y: r.positionY,
                       color: nil, sort_order: r.sortOrder)
        }
        do {
            let new = try await replaceLayout(tables: tableDTOs, rooms: roomDTOs,
                                              removingTables: tables, removingRooms: rooms)
            let newTables = new.tables

            // Map old table id → new table id by insertion order.
            var idMap: [String: String] = [:]
            for (old, new) in zip(priorTables, newTables) { idMap[old.id] = new.id }

            tables = newTables
            rooms = new.rooms

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
        // Built-in starters are local only — nothing to delete.
        guard !template.isBuiltIn,
              let removedIndex = templates.firstIndex(where: { $0.id == template.id }) else { return }
        let removed = templates.remove(at: removedIndex)
        do {
            try await supabase.delete("floorplan_templates",
                                      query: [URLQueryItem(name: "id", value: "eq.\(template.id)")])
            markReachable()
        } catch {
            reinsert(removed, into: &templates, preferredIndex: removedIndex)
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

// MARK: - Chunking

private extension Array {
    /// Splits the array into consecutive slices of at most `size` elements.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, count > size else { return isEmpty ? [] : [Array(self)] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
