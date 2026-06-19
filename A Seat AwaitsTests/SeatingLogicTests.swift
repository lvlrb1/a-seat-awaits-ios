//
//  SeatingLogicTests.swift
//  A Seat AwaitsTests
//
//  Unit tests for the pure seating/guest business logic.
//

import Testing
@testable import A_Seat_Awaits

private func makeGuest(_ name: String,
                       group: String? = nil,
                       groupId: String? = nil,
                       email: String? = nil,
                       tableId: String? = nil) -> Guest {
    Guest(id: UUID().uuidString,
          eventId: "event-1",
          name: name,
          email: email,
          groupId: groupId,
          groupName: group,
          tableId: tableId,
          dietaryPreference: nil,
          notes: nil,
          createdAt: nil,
          updatedAt: nil)
}

private func makeTable(_ name: String, id: String = UUID().uuidString, capacity: Int? = 8) -> SeatingTable {
    SeatingTable(id: id,
                 eventId: "event-1",
                 name: name,
                 capacity: capacity,
                 shape: .circle,
                 width: 80, height: 80,
                 positionX: 0, positionY: 0,
                 rotation: nil, isCustom: nil, description: nil,
                 createdAt: nil, updatedAt: nil)
}

@Suite("Event stats")
struct EventStatsTests {

    @Test("Totals split assigned vs open correctly")
    func computesTotals() {
        let guests = [
            makeGuest("Chris Anderson", tableId: "t1"),
            makeGuest("Layla Adams"),
            makeGuest("Olivia Brown", tableId: "t2"),
            makeGuest("Jackson Brown"),
        ]
        let tables = [makeTable("Table 1", id: "t1", capacity: 8),
                      makeTable("Table 2", id: "t2", capacity: 6)]

        let stats = EventStats.compute(guests: guests, tables: tables)

        #expect(stats.total == 4)
        #expect(stats.assigned == 2)
        #expect(stats.open == 2)
        #expect(stats.tableCount == 2)
        #expect(stats.totalCapacity == 14)
    }

    @Test("Empty event yields zeroed stats")
    func emptyEvent() {
        let stats = EventStats.compute(guests: [], tables: [])
        #expect(stats == EventStats(total: 0, assigned: 0, open: 0, tableCount: 0, totalCapacity: 0))
    }
}

@Suite("Guest filtering & sorting")
struct GuestFilterTests {

    @Test("Search matches name, email, and group case-insensitively")
    func searchAcrossFields() {
        let guests = [
            makeGuest("Chloe Anderson", group: "Product", email: "chloe@x.co"),
            makeGuest("William Carter", group: "Board Members"),
            makeGuest("Lily Chen", group: "Design"),
        ]
        #expect(SeatingLogic.filterAndSort(guests, search: "anderson").count == 1)
        #expect(SeatingLogic.filterAndSort(guests, search: "BOARD").count == 1)
        #expect(SeatingLogic.filterAndSort(guests, search: "chloe@x").count == 1)
        #expect(SeatingLogic.filterAndSort(guests, search: "zzz").isEmpty)
    }

    @Test("Group and table filters narrow results")
    func groupAndTableFilters() {
        let guests = [
            makeGuest("A", groupId: "g1", tableId: "t1"),
            makeGuest("B", groupId: "g1"),
            makeGuest("C", groupId: "g2", tableId: "t1"),
        ]
        #expect(SeatingLogic.filterAndSort(guests, groupId: "g1").count == 2)
        #expect(SeatingLogic.filterAndSort(guests, tableId: "t1").count == 2)
        #expect(SeatingLogic.filterAndSort(guests, groupId: "g1", tableId: "t1").count == 1)
    }

    @Test("Last-name sort orders by surname then first name")
    func lastNameSort() {
        let guests = [makeGuest("Olivia Brown"),
                      makeGuest("Chris Anderson"),
                      makeGuest("Jackson Brown")]
        let sorted = SeatingLogic.sorted(guests, by: .lastNameAZ).map(\.name)
        #expect(sorted == ["Chris Anderson", "Jackson Brown", "Olivia Brown"])
    }

    @Test("Unassigned-first sort puts open guests ahead of seated ones")
    func unassignedFirstSort() {
        let guests = [makeGuest("Seated Sam", tableId: "t1"),
                      makeGuest("Open Olivia")]
        let sorted = SeatingLogic.sorted(guests, by: .unassignedFirst).map(\.name)
        #expect(sorted.first == "Open Olivia")
    }
}

@Suite("Table occupancy")
struct OccupancyTests {

    @Test("Occupancy counts guests at a table")
    func occupancyCount() {
        let guests = [makeGuest("A", tableId: "t1"),
                      makeGuest("B", tableId: "t1"),
                      makeGuest("C", tableId: "t2")]
        #expect(SeatingLogic.occupancy(of: "t1", guests: guests) == 2)
    }

    @Test("Over-capacity is detected and remaining seats clamp at zero")
    func overCapacity() {
        let table = makeTable("Tiny", id: "t1", capacity: 2)
        let guests = [makeGuest("A", tableId: "t1"),
                      makeGuest("B", tableId: "t1"),
                      makeGuest("C", tableId: "t1")]
        #expect(SeatingLogic.isOverCapacity(table, guests: guests))
        #expect(SeatingLogic.remainingSeats(table, guests: guests) == 0)
    }

    @Test("Remaining seats reflect open spots; nil when uncapped")
    func remainingSeats() {
        let table = makeTable("Eight", id: "t1", capacity: 8)
        let guests = [makeGuest("A", tableId: "t1"), makeGuest("B", tableId: "t1")]
        #expect(SeatingLogic.remainingSeats(table, guests: guests) == 6)

        let uncapped = makeTable("Bar", id: "t9", capacity: nil)
        #expect(SeatingLogic.remainingSeats(uncapped, guests: guests) == nil)
        #expect(SeatingLogic.isOverCapacity(uncapped, guests: guests) == false)
    }
}

@Suite("Add-table sizing")
struct TableSizingTests {

    @Test("Rectangles are wider than tall; circles are square")
    func sizing() {
        let circle = AddTableView.size(for: .circle, capacity: 8)
        #expect(circle.width == circle.height)

        let rect = AddTableView.size(for: .rectangle, capacity: 8)
        #expect(rect.width > rect.height)
    }
}

@Suite("Hex color parsing")
struct HexColorTests {

    @Test("Valid hex parses; invalid returns nil")
    func parsing() {
        #expect(Color(hex: "#43204f") != nil)
        #expect(Color(hex: "7C3AED") != nil)
        #expect(Color(hex: "nope") == nil)
        #expect(Color(hex: nil) == nil)
    }
}

import SwiftUI
