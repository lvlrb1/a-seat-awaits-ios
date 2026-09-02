//
//  SeatingLogic.swift
//  A Seat Awaits
//
//  Pure, testable business logic for guest filtering/sorting and seating stats.
//  Kept free of UI and networking so it can be unit-tested in isolation.
//

import Foundation

enum GuestSort: String, CaseIterable, Identifiable {
    case lastNameAZ
    case firstNameAZ
    case group
    case unassignedFirst
    case newestAdded
    case oldestAdded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lastNameAZ: return "Last Name (A to Z)"
        case .firstNameAZ: return "First Name (A to Z)"
        case .group: return "Group"
        case .unassignedFirst: return "Unassigned First"
        case .newestAdded: return "Newest Added"
        case .oldestAdded: return "Oldest Added"
        }
    }
}

/// Ordering for the Tables list view. Occupancy-aware sorts read the live guest
/// list so "most open" / "fullest" reflect who is actually seated.
enum TableSort: String, CaseIterable, Identifiable {
    case nameAZ
    case capacity
    case mostOpen
    case fullest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nameAZ: return "Name (A to Z)"
        case .capacity: return "Seats (most first)"
        case .mostOpen: return "Most open"
        case .fullest: return "Fullest first"
        }
    }

    var systemImage: String {
        switch self {
        case .nameAZ: return "textformat"
        case .capacity: return "chair.lounge"
        case .mostOpen: return "person.badge.plus"
        case .fullest: return "person.2.fill"
        }
    }
}

/// Aggregate counts shown in the guest-list footer and event cards.
struct EventStats: Equatable {
    var total: Int
    var assigned: Int
    var open: Int
    var tableCount: Int
    var totalCapacity: Int

    static func compute(guests: [Guest], tables: [SeatingTable]) -> EventStats {
        let assigned = guests.filter { $0.isAssigned }.count
        return EventStats(
            total: guests.count,
            assigned: assigned,
            open: guests.count - assigned,
            tableCount: tables.count,
            totalCapacity: tables.reduce(0) { $0 + $1.seats }
        )
    }
}

/// A household filter keyed on the group's NAME. Imported guests usually carry
/// only `group_name` (no linked `guest_groups` row), while guests created in
/// the app carry a `group_id`, so a household matches on either: the name
/// itself, or any group id known to have that name.
nonisolated struct HouseholdFilter: Equatable, Sendable {
    var name: String
    var groupIds: Set<String> = []

    func matches(_ guest: Guest) -> Bool {
        if let groupName = guest.groupName, groupName == name { return true }
        if let groupId = guest.groupId, groupIds.contains(groupId) { return true }
        return false
    }
}

enum SeatingLogic {

    /// Filters guests by a free-text search, group, household, and table, then
    /// sorts them.
    static func filterAndSort(_ guests: [Guest],
                              search: String = "",
                              groupId: String? = nil,
                              household: HouseholdFilter? = nil,
                              tableId: String? = nil,
                              sort: GuestSort = .lastNameAZ) -> [Guest] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let filtered = guests.filter { guest in
            if !trimmed.isEmpty {
                let haystack = [guest.name, guest.email ?? "", guest.groupName ?? ""]
                    .joined(separator: " ").lowercased()
                if !haystack.contains(trimmed) { return false }
            }
            if let groupId, guest.groupId != groupId { return false }
            if let household, !household.matches(guest) { return false }
            if let tableId, guest.tableId != tableId { return false }
            return true
        }

        return sorted(filtered, by: sort)
    }

    /// Every distinct household name among the guests plus the event's named
    /// groups, sorted for a chip row. Names are matched exactly (the same
    /// string a guest carries), so the filter chip built from one always hits.
    static func householdNames(guests: [Guest], groups: [GuestGroup]) -> [String] {
        var names = Set(groups.map(\.name).filter { !$0.isEmpty })
        for guest in guests {
            if let name = guest.groupName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                names.insert(name)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The household filter for a given name: the name plus every group id
    /// carrying it, so id-linked and name-only guests land in the same bucket.
    static func householdFilter(named name: String, groups: [GuestGroup]) -> HouseholdFilter {
        HouseholdFilter(name: name, groupIds: Set(groups.filter { $0.name == name }.map(\.id)))
    }

    /// The party key a guest sorts into for "select the whole household":
    /// the linked group id when present, else the bare group name. Nil for
    /// guests with no household at all.
    static func partyKey(for guest: Guest) -> String? {
        if let id = guest.groupId { return id }
        if let name = guest.groupName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return "name:\(name)"
        }
        return nil
    }

    /// The body of the "Remove {guest}?" confirmation: names what the guest
    /// carries (a seat, dietary notes, notes) in one grammatical sentence, then
    /// reminds the planner the delete can be undone. Empty details produce just
    /// the undo reminder.
    static func deletionMessage(tableName: String?, hasDietary: Bool, hasNotes: Bool) -> String {
        let reminder = "You'll be able to undo for a few seconds."
        let notesClause: String? = hasDietary ? "dietary notes on file"
                                  : (hasNotes ? "notes on file" : nil)
        switch (tableName, notesClause) {
        case let (table?, clause?):
            return "They're seated at \(table) and have \(clause). \(reminder)"
        case let (table?, nil):
            return "They're seated at \(table). \(reminder)"
        case let (nil, clause?):
            return "They have \(clause). \(reminder)"
        case (nil, nil):
            return reminder
        }
    }

    static func sorted(_ guests: [Guest], by sort: GuestSort) -> [Guest] {
        switch sort {
        case .lastNameAZ:
            return guests.sorted { lhs, rhs in
                if lhs.lastNameKey == rhs.lastNameKey { return lhs.firstNameKey < rhs.firstNameKey }
                return lhs.lastNameKey < rhs.lastNameKey
            }
        case .firstNameAZ:
            return guests.sorted { $0.firstNameKey < $1.firstNameKey }
        case .group:
            return guests.sorted { lhs, rhs in
                let l = (lhs.groupName ?? "~").lowercased()
                let r = (rhs.groupName ?? "~").lowercased()
                if l == r { return lhs.lastNameKey < rhs.lastNameKey }
                return l < r
            }
        case .unassignedFirst:
            return guests.sorted { lhs, rhs in
                if lhs.isAssigned != rhs.isAssigned { return !lhs.isAssigned && rhs.isAssigned }
                return lhs.lastNameKey < rhs.lastNameKey
            }
        // created_at is an ISO-8601 string, so lexicographic order is
        // chronological. "Oldest Added" reproduces import/file order because
        // imports insert sequentially. Ties break on id for a stable order.
        case .newestAdded:
            return guests.sorted { lhs, rhs in
                let l = lhs.createdAt ?? "", r = rhs.createdAt ?? ""
                if l == r { return lhs.id > rhs.id }
                return l > r
            }
        case .oldestAdded:
            return guests.sorted { lhs, rhs in
                let l = lhs.createdAt ?? "", r = rhs.createdAt ?? ""
                if l == r { return lhs.id < rhs.id }
                return l < r
            }
        }
    }

    /// Sorts tables for the list view. Ties always break on name so the order is
    /// stable and predictable. Uncapped tables (no seat limit) count as having
    /// unlimited room for "most open" and zero fill for "fullest".
    static func sortedTables(_ tables: [SeatingTable],
                             by sort: TableSort,
                             guests: [Guest]) -> [SeatingTable] {
        func byName(_ lhs: SeatingTable, _ rhs: SeatingTable) -> Bool {
            // Numeric-aware compare so "Table 2" precedes "Table 10".
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        switch sort {
        case .nameAZ:
            return tables.sorted(by: byName)
        case .capacity:
            return tables.sorted { lhs, rhs in
                let l = lhs.capacity ?? 0, r = rhs.capacity ?? 0
                return l == r ? byName(lhs, rhs) : l > r
            }
        case .mostOpen:
            // One pass over the guests, then O(1) lookups in the comparator —
            // the old per-compare filter was O(tables·log(tables)·guests).
            let occupancy = occupancyByTable(guests: guests)
            func open(_ t: SeatingTable) -> Int {
                guard let capacity = t.capacity, capacity > 0 else { return .max }
                return max(0, capacity - occupancy[t.id, default: 0])
            }
            return tables.sorted { lhs, rhs in
                let l = open(lhs), r = open(rhs)
                return l == r ? byName(lhs, rhs) : l > r
            }
        case .fullest:
            let occupancy = occupancyByTable(guests: guests)
            func fill(_ t: SeatingTable) -> Double {
                guard let capacity = t.capacity, capacity > 0 else { return 0 }
                return Double(occupancy[t.id, default: 0]) / Double(capacity)
            }
            return tables.sorted { lhs, rhs in
                let l = fill(lhs), r = fill(rhs)
                return l == r ? byName(lhs, rhs) : l > r
            }
        }
    }

    /// Seated-guest counts keyed by table id, computed in a single pass.
    static func occupancyByTable(guests: [Guest]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for guest in guests {
            if let id = guest.tableId { counts[id, default: 0] += 1 }
        }
        return counts
    }

    /// Guests seated at each table, in a stable "last name, then first name"
    /// order — the order seat chips render in on the floor plan.
    static func seatedGuestsByTable(guests: [Guest]) -> [String: [Guest]] {
        var byTable: [String: [Guest]] = [:]
        for guest in guests {
            if let id = guest.tableId { byTable[id, default: []].append(guest) }
        }
        for (id, seated) in byTable {
            byTable[id] = seated.sorted { lhs, rhs in
                if lhs.lastNameKey == rhs.lastNameKey { return lhs.firstNameKey < rhs.firstNameKey }
                return lhs.lastNameKey < rhs.lastNameKey
            }
        }
        return byTable
    }

    /// How full a table is, 0...1+ (over-capacity exceeds 1). Uncapped → 0.
    static func fillFraction(_ table: SeatingTable, guests: [Guest]) -> Double {
        guard let capacity = table.capacity, capacity > 0 else { return 0 }
        return Double(occupancy(of: table.id, guests: guests)) / Double(capacity)
    }

    /// Number of guests currently seated at a given table.
    static func occupancy(of tableId: String, guests: [Guest]) -> Int {
        guests.filter { $0.tableId == tableId }.count
    }

    /// True when a table has more guests assigned than its capacity allows.
    static func isOverCapacity(_ table: SeatingTable, guests: [Guest]) -> Bool {
        guard let capacity = table.capacity, capacity > 0 else { return false }
        return occupancy(of: table.id, guests: guests) > capacity
    }

    /// Remaining open seats at a table (never negative). Nil when uncapped.
    static func remainingSeats(_ table: SeatingTable, guests: [Guest]) -> Int? {
        guard let capacity = table.capacity, capacity > 0 else { return nil }
        return max(0, capacity - occupancy(of: table.id, guests: guests))
    }
}
