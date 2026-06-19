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
}

nonisolated struct TablePositionPatch: Encodable, Sendable {
    let position_x: Double
    let position_y: Double
}

/// Encodable params for the `event_collaborators` RPC.
nonisolated struct EventCollaboratorsParams: Encodable, Sendable {
    let p_event_id: String
}

@MainActor
@Observable
final class SeatingStore {
    let event: Event
    private let supabase: SupabaseClient

    private(set) var guests: [Guest] = []
    private(set) var tables: [SeatingTable] = []
    private(set) var groups: [GuestGroup] = []
    private(set) var collaborators: [Collaborator] = []

    private(set) var isLoading = false
    var errorMessage: String?

    init(event: Event, supabase: SupabaseClient) {
        self.event = event
        self.supabase = supabase
    }

    var stats: EventStats { EventStats.compute(guests: guests, tables: tables) }

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
            let (loadedGuests, loadedTables, loadedGroups) = try await (g, t, gr)
            guests = loadedGuests
            tables = loadedTables
            groups = loadedGroups
        } catch {
            errorMessage = error.localizedDescription
        }
        await loadCollaborators()
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
        } catch {
            guests[index] = previous
            errorMessage = error.localizedDescription
        }
    }

    func deleteGuest(_ guest: Guest) async {
        let snapshot = guests
        guests.removeAll { $0.id == guest.id }
        do {
            try await supabase.delete("guests", query: [URLQueryItem(name: "id", value: "eq.\(guest.id)")])
        } catch {
            guests = snapshot
            errorMessage = error.localizedDescription
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
                  positionY: Double) async throws -> SeatingTable {
        let rows = try await supabase.insert(
            "tables",
            values: NewTableDTO(event_id: event.id,
                                name: name,
                                shape: shape.rawValue,
                                capacity: capacity,
                                width: width,
                                height: height,
                                position_x: positionX,
                                position_y: positionY),
            returning: [SeatingTable].self
        )
        guard let table = rows.first else { throw SupabaseError.decoding("No table returned.") }
        tables.append(table)
        return table
    }

    /// Persists a moved table's new position. Local state is updated by the
    /// caller during the drag; this writes the final value.
    func updatePosition(of table: SeatingTable, x: Double, y: Double) async {
        if let index = tables.firstIndex(where: { $0.id == table.id }) {
            tables[index].positionX = x
            tables[index].positionY = y
        }
        do {
            _ = try await supabase.update(
                "tables",
                values: TablePositionPatch(position_x: x, position_y: y),
                query: [URLQueryItem(name: "id", value: "eq.\(table.id)")],
                returning: [SeatingTable].self
            )
        } catch {
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
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
