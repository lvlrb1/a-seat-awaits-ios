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

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lastNameAZ: return "Last Name (A–Z)"
        case .firstNameAZ: return "First Name (A–Z)"
        case .group: return "Group"
        case .unassignedFirst: return "Unassigned First"
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
        case .nameAZ: return "Name (A–Z)"
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

enum SeatingLogic {

    /// Filters guests by a free-text search, group, and table, then sorts them.
    static func filterAndSort(_ guests: [Guest],
                              search: String = "",
                              groupId: String? = nil,
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
            if let tableId, guest.tableId != tableId { return false }
            return true
        }

        return sorted(filtered, by: sort)
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
            return tables.sorted { lhs, rhs in
                let l = remainingSeats(lhs, guests: guests) ?? .max
                let r = remainingSeats(rhs, guests: guests) ?? .max
                return l == r ? byName(lhs, rhs) : l > r
            }
        case .fullest:
            return tables.sorted { lhs, rhs in
                let l = fillFraction(lhs, guests: guests)
                let r = fillFraction(rhs, guests: guests)
                return l == r ? byName(lhs, rhs) : l > r
            }
        }
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
