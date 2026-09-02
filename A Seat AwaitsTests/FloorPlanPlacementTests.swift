//
//  FloorPlanPlacementTests.swift
//  A Seat AwaitsTests
//
//  Unit tests for the pure placement logic that lands new/duplicated items on
//  the canvas (`FloorPlanGeometry.freePosition`), the bundled starter layouts
//  (no overlaps, everything inside its room), the occupancy-aware table sort,
//  and the guest-list copy helpers.
//

import Foundation
import Testing
@testable import A_Seat_Awaits

private typealias G = FloorPlanGeometry

private func item(_ id: String, _ x: Double, _ y: Double,
                  _ w: Double, _ h: Double, rot: Double = 0) -> G.Item {
    G.Item(id: id, x: x, y: y, width: w, height: h, rotation: rot)
}

private func makeGuest(_ name: String,
                       group: String? = nil,
                       groupId: String? = nil,
                       tableId: String? = nil) -> Guest {
    Guest(id: UUID().uuidString, eventId: "event-1", name: name, email: nil,
          groupId: groupId, groupName: group, tableId: tableId,
          dietaryPreference: nil, notes: nil, createdAt: nil, updatedAt: nil)
}

private func makeTable(_ name: String, id: String, capacity: Int?) -> SeatingTable {
    SeatingTable(id: id, eventId: "event-1", name: name, capacity: capacity, shape: .circle,
                 width: 96, height: 96, positionX: 0, positionY: 0,
                 rotation: nil, isCustom: nil, description: nil, createdAt: nil, updatedAt: nil)
}

// MARK: - Free placement (spiral)

@Suite("Free placement")
struct FreePositionTests {

    @Test("Empty canvas centers the item on the anchor")
    func emptyCanvasCentersOnAnchor() {
        let spot = G.freePosition(near: (300, 400), size: (100, 60), among: [])
        #expect(spot.x == 250)
        #expect(spot.y == 370)
    }

    @Test("A clear anchor is used as-is even with neighbors elsewhere")
    func clearAnchorIsKept() {
        let far = [item("far", 2000, 2000, 100, 100)]
        let spot = G.freePosition(near: (300, 400), size: (100, 60), among: far)
        #expect(spot.x == 250)
        #expect(spot.y == 370)
    }

    @Test("An occupied anchor is nudged to the nearest clear cell")
    func occupiedAnchorSpiralsOut() {
        // A 96×96 table sits exactly where the new one wants to go.
        let blocker = item("b", 252, 352, 96, 96)      // center (300, 400)
        let size = (width: 96.0, height: 96.0)
        let spot = G.freePosition(near: (300, 400), size: size, among: [blocker],
                                  clearance: 24, step: 24)
        // Result must not overlap the blocker (with the clearance halo)...
        let placed = item("new", spot.x - 24, spot.y - 24, size.width + 48, size.height + 48)
        #expect(G.collisions(for: placed, among: [blocker]).isEmpty)
        // ...and must sit within a few steps of the anchor, not off in a corner.
        let dx = abs((spot.x + 48) - 300), dy = abs((spot.y + 48) - 400)
        #expect(max(dx, dy) <= 24 * 8)
    }

    @Test("Spiral is deterministic and never overlaps a crowded cluster")
    func crowdedClusterFindsGapWithoutOverlap() {
        var others: [G.Item] = []
        for row in 0..<3 {
            for col in 0..<3 {
                others.append(item("t\(row)\(col)", Double(col) * 150, Double(row) * 150, 96, 96))
            }
        }
        let size = (width: 96.0, height: 96.0)
        let a = G.freePosition(near: (198, 198), size: size, among: others)
        let b = G.freePosition(near: (198, 198), size: size, among: others)
        #expect(a.x == b.x && a.y == b.y)
        let placed = item("new", a.x - 24, a.y - 24, size.width + 48, size.height + 48)
        #expect(G.collisions(for: placed, among: others).isEmpty)
    }

    @Test("Falls back to the anchor when nothing within maxRings is free")
    func fallsBackWhenNothingFree() {
        // One enormous blocker covers everything the short spiral can reach.
        let blocker = item("wall", -5000, -5000, 10000, 10000)
        let spot = G.freePosition(near: (100, 100), size: (50, 50), among: [blocker],
                                  step: 24, maxRings: 2)
        #expect(spot.x == 75)
        #expect(spot.y == 75)
    }
}

// MARK: - Built-in starter layouts

@Suite("Starter layouts")
struct StarterLayoutTests {

    private func items(_ template: FloorPlanTemplate) -> [G.Item] {
        template.tablesJson.enumerated().map { index, t in
            item("\(index)", t.positionX, t.positionY, t.width, t.height, rot: t.rotation)
        }
    }

    @Test("There are five starters, all flagged built-in with unique ids")
    func fiveBuiltInStarters() {
        let all = StarterLayout.all
        #expect(all.count == 5)
        #expect(all.allSatisfy { $0.template.isBuiltIn })
        #expect(Set(all.map(\.id)).count == 5)
        #expect(all.allSatisfy { !$0.template.tablesJson.isEmpty })
        #expect(all.allSatisfy { $0.template.roomsJson.count == 1 })
    }

    @Test("No starter table overlaps another")
    func noTableOverlaps() {
        for starter in StarterLayout.all {
            let all = items(starter.template)
            for table in all {
                let hits = G.collisions(for: table, among: all)
                #expect(hits.isEmpty, "\(starter.template.name): table \(table.id) overlaps \(hits)")
            }
        }
    }

    @Test("Every starter table sits inside its room, with room for chairs")
    func tablesInsideRoom() {
        let chairMargin = 24.0   // seat dots + a little air
        for starter in StarterLayout.all {
            let room = starter.template.roomsJson[0]
            let roomRight = room.positionX + TableScale.feet(room.widthFt)
            let roomBottom = room.positionY + TableScale.feet(room.heightFt)
            for table in items(starter.template) {
                let b = G.bounds(table)
                #expect(b.left - chairMargin >= room.positionX, "\(starter.template.name): \(table.id) left")
                #expect(b.top - chairMargin >= room.positionY, "\(starter.template.name): \(table.id) top")
                #expect(b.right + chairMargin <= roomRight, "\(starter.template.name): \(table.id) right")
                #expect(b.bottom + chairMargin <= roomBottom, "\(starter.template.name): \(table.id) bottom")
            }
        }
    }

    @Test("Starter geometry is on the 24pt-per-foot scale")
    func starterScale() {
        let classic = StarterLayout.all[0].template
        // 48" rounds are exactly 96pt across.
        #expect(classic.tablesJson.allSatisfy { $0.width == 96 && $0.height == 96 })
        #expect(classic.totalSeats == 80)
        #expect(classic.roomsJson[0].widthFt == 52)
    }
}

// MARK: - Occupancy-aware table sort

@Suite("Table sort occupancy")
struct TableSortOccupancyTests {

    @Test("Most open orders by open seats, uncapped first, ties by name")
    func mostOpen() {
        let tables = [makeTable("Table 2", id: "t2", capacity: 8),
                      makeTable("Table 1", id: "t1", capacity: 8),
                      makeTable("Lounge", id: "l", capacity: nil),
                      makeTable("Table 3", id: "t3", capacity: 4)]
        var guests: [Guest] = []
        for _ in 0..<6 { guests.append(makeGuest("A", tableId: "t1")) }   // 2 open
        for _ in 0..<2 { guests.append(makeGuest("B", tableId: "t2")) }   // 6 open
        for _ in 0..<4 { guests.append(makeGuest("C", tableId: "t3")) }   // 0 open

        let sorted = SeatingLogic.sortedTables(tables, by: .mostOpen, guests: guests).map(\.id)
        #expect(sorted == ["l", "t2", "t1", "t3"])
    }

    @Test("Fullest orders by fill fraction and matches the precomputed occupancy")
    func fullest() {
        let tables = [makeTable("Table 1", id: "t1", capacity: 8),
                      makeTable("Table 2", id: "t2", capacity: 4),
                      makeTable("Table 3", id: "t3", capacity: 10)]
        var guests: [Guest] = []
        for _ in 0..<4 { guests.append(makeGuest("A", tableId: "t1")) }   // 0.5
        for _ in 0..<4 { guests.append(makeGuest("B", tableId: "t2")) }   // 1.0
        for _ in 0..<1 { guests.append(makeGuest("C", tableId: "t3")) }   // 0.1

        let sorted = SeatingLogic.sortedTables(tables, by: .fullest, guests: guests).map(\.id)
        #expect(sorted == ["t2", "t1", "t3"])

        let occupancy = SeatingLogic.occupancyByTable(guests: guests)
        #expect(occupancy["t1"] == 4)
        #expect(occupancy["t2"] == 4)
        #expect(occupancy["t3"] == 1)
        #expect(occupancy["missing"] == nil)
    }

    @Test("Seated guests per table come back in last-name order")
    func seatedGuestsOrdered() {
        let guests = [makeGuest("Zed Adams", tableId: "t1"),
                      makeGuest("Amy Young", tableId: "t1"),
                      makeGuest("Bob Adams", tableId: "t1"),
                      makeGuest("Solo", tableId: "t2")]
        let byTable = SeatingLogic.seatedGuestsByTable(guests: guests)
        #expect(byTable["t1"]?.map(\.name) == ["Bob Adams", "Zed Adams", "Amy Young"])
        #expect(byTable["t2"]?.count == 1)
    }
}

// MARK: - Copy + household helpers

@Suite("Guest list copy and households")
struct GuestListHelperTests {

    @Test("Deletion message reads as one grammatical sentence in every case")
    func deletionMessageGrammar() {
        let reminder = "You'll be able to undo for a few seconds."
        #expect(SeatingLogic.deletionMessage(tableName: "Table 3", hasDietary: true, hasNotes: false)
                == "They're seated at Table 3 and have dietary notes on file. \(reminder)")
        #expect(SeatingLogic.deletionMessage(tableName: "Table 3", hasDietary: false, hasNotes: false)
                == "They're seated at Table 3. \(reminder)")
        #expect(SeatingLogic.deletionMessage(tableName: nil, hasDietary: true, hasNotes: true)
                == "They have dietary notes on file. \(reminder)")
        #expect(SeatingLogic.deletionMessage(tableName: nil, hasDietary: false, hasNotes: true)
                == "They have notes on file. \(reminder)")
        #expect(SeatingLogic.deletionMessage(tableName: nil, hasDietary: false, hasNotes: false)
                == reminder)
        // The old bug: never "They're has".
        #expect(!SeatingLogic.deletionMessage(tableName: nil, hasDietary: true, hasNotes: false)
                    .contains("They're has"))
    }

    @Test("Household filter matches imported (name-only) and linked (id) guests")
    func householdFilterMatchesBothKinds() {
        let group = GuestGroup(id: "g1", eventId: "event-1", name: "Smiths", color: nil,
                               description: nil, createdAt: nil, updatedAt: nil)
        let imported = makeGuest("Ann Smith", group: "Smiths")
        let linked = makeGuest("Bo Smith", group: nil, groupId: "g1")
        let other = makeGuest("Cy Jones", group: "Jones")

        let filter = SeatingLogic.householdFilter(named: "Smiths", groups: [group])
        let visible = SeatingLogic.filterAndSort([imported, linked, other], household: filter)
        #expect(Set(visible.map(\.name)) == ["Ann Smith", "Bo Smith"])

        let names = SeatingLogic.householdNames(guests: [imported, linked, other], groups: [group])
        #expect(names == ["Jones", "Smiths"])
    }

    @Test("Party key falls back to the group name when there is no group id")
    func partyKeyFallback() {
        #expect(SeatingLogic.partyKey(for: makeGuest("A", group: "Smiths", groupId: "g1")) == "g1")
        #expect(SeatingLogic.partyKey(for: makeGuest("B", group: "Smiths")) == "name:Smiths")
        #expect(SeatingLogic.partyKey(for: makeGuest("C", group: "  ")) == nil)
        #expect(SeatingLogic.partyKey(for: makeGuest("D")) == nil)
    }

    @Test("Sort labels no longer carry en-dashes")
    func sortLabelsAreDashFree() {
        for sort in GuestSort.allCases { #expect(!sort.label.contains("–")) }
        for sort in TableSort.allCases { #expect(!sort.label.contains("–")) }
        #expect(GuestSort.lastNameAZ.label == "Last Name (A to Z)")
    }
}
