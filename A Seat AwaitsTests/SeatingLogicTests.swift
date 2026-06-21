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

@Suite("Table sorting")
struct TableSortTests {

    private func tables() -> [SeatingTable] {
        [makeTable("Sweetheart", id: "t1", capacity: 2),
         makeTable("Family", id: "t2", capacity: 10),
         makeTable("Aunties", id: "t3", capacity: 6)]
    }

    @Test("Name sort is case-insensitive A–Z")
    func nameSort() {
        let sorted = SeatingLogic.sortedTables(tables(), by: .nameAZ, guests: [])
        #expect(sorted.map(\.name) == ["Aunties", "Family", "Sweetheart"])
    }

    @Test("Capacity sort orders by most seats, ties broken by name")
    func capacitySort() {
        let extra = makeTable("Bar", id: "t4", capacity: 10)   // ties with Family
        let sorted = SeatingLogic.sortedTables(tables() + [extra], by: .capacity, guests: [])
        #expect(sorted.map(\.name) == ["Bar", "Family", "Aunties", "Sweetheart"])
    }

    @Test("Most-open sort surfaces tables with the most empty seats")
    func mostOpenSort() {
        // Family (10 cap) seats 1 → 9 open; Aunties (6) seats 5 → 1 open;
        // Sweetheart (2) seats 0 → 2 open.
        let guests = [makeGuest("A", tableId: "t2"),
                      makeGuest("B", tableId: "t3"), makeGuest("C", tableId: "t3"),
                      makeGuest("D", tableId: "t3"), makeGuest("E", tableId: "t3"),
                      makeGuest("F", tableId: "t3")]
        let sorted = SeatingLogic.sortedTables(tables(), by: .mostOpen, guests: guests)
        #expect(sorted.map(\.name) == ["Family", "Sweetheart", "Aunties"])
    }

    @Test("Fullest sort surfaces the most-occupied tables first")
    func fullestSort() {
        // Sweetheart (2) seats 2 → 100%; Aunties (6) seats 3 → 50%; Family (10) seats 1 → 10%.
        let guests = [makeGuest("A", tableId: "t1"), makeGuest("B", tableId: "t1"),
                      makeGuest("C", tableId: "t3"), makeGuest("D", tableId: "t3"),
                      makeGuest("E", tableId: "t3"),
                      makeGuest("F", tableId: "t2")]
        let sorted = SeatingLogic.sortedTables(tables(), by: .fullest, guests: guests)
        #expect(sorted.map(\.name) == ["Sweetheart", "Aunties", "Family"])
    }

    @Test("Uncapped tables count as unlimited room and zero fill")
    func uncappedExtremes() {
        let capped = makeTable("Round", id: "c1", capacity: 4)
        let bar = makeTable("Bar", id: "c2", capacity: nil)
        // Seat the capped table to 100% and pile guests at the bar; the bar's
        // fill stays zero because it has no seat limit.
        let guests = [makeGuest("A", tableId: "c1"), makeGuest("B", tableId: "c1"),
                      makeGuest("C", tableId: "c1"), makeGuest("D", tableId: "c1"),
                      makeGuest("E", tableId: "c2"), makeGuest("F", tableId: "c2")]
        let mostOpen = SeatingLogic.sortedTables([capped, bar], by: .mostOpen, guests: guests)
        #expect(mostOpen.first?.name == "Bar")        // unlimited room first
        let fullest = SeatingLogic.sortedTables([capped, bar], by: .fullest, guests: guests)
        #expect(fullest.first?.name == "Round")       // bar never counts as full
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

@Suite("Table presets & real-world scale")
struct TablePresetTests {

    @Test("Scale converts feet/inches to points at 24pt = 1ft")
    func scale() {
        #expect(TableScale.feet(4) == 96)
        #expect(TableScale.inches(30) == 60)
        #expect(TableScale.toFeet(points: 120) == 5)
    }

    @Test("Presets mirror the web specs: round tables square, rectangles wider")
    func presetShapes() {
        let round = TablePreset.all.first { $0.id == "round-60in" }!
        #expect(round.width == round.height)          // 60" round → 120 × 120
        #expect(round.capacity == 10)

        let rect = TablePreset.all.first { $0.id == "rectangle-6ft" }!
        #expect(rect.width > rect.height)             // 6ft × 30"
        #expect(rect.width == TableScale.feet(6))
        #expect(rect.height == TableScale.inches(30))
    }

    @Test("Matching resolves a table's preset by shape + size, else nil (custom)")
    func matching() {
        // 48" round, 8 seats → preset; arbitrary size → custom.
        #expect(TablePreset.match(shape: .circle, width: 96, height: 96)?.id == "round-48in")
        #expect(TablePreset.match(shape: .rectangle, width: 137, height: 71) == nil)
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
