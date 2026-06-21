//
//  FloorPlanExportTests.swift
//  A Seat AwaitsTests
//
//  Tests the on-device floor-plan PDF export: native rendering (valid PDF,
//  guest-list pagination, empty-plan handling) and safe filename/file saving.
//  The app generates the PDF locally with `FloorPlanPDFRenderer` — a port of the
//  web app's renderer — so there is no network path to test.
//

import Foundation
import PDFKit
import Testing
@testable import A_Seat_Awaits

// MARK: - Fixtures

private func makeEvent(name: String = "Spring Gala") -> Event {
    Event(id: "evt-1", name: name, date: "2026-06-20", location: "The Grand Hall",
          description: nil, ownerId: "owner-1", qrCodeToken: nil,
          roomWidthFt: nil, roomHeightFt: nil, slug: nil, createdAt: nil, updatedAt: nil)
}

private func makeTable(_ name: String, id: String, capacity: Int = 8,
                       shape: TableShape = .circle, x: Double = 80, y: Double = 80) -> SeatingTable {
    SeatingTable(id: id, eventId: "evt-1", name: name, capacity: capacity, shape: shape,
                 width: 120, height: 120, positionX: x, positionY: y,
                 rotation: nil, isCustom: nil, description: nil, createdAt: nil, updatedAt: nil)
}

private func makeGuest(_ name: String, tableId: String?) -> Guest {
    Guest(id: UUID().uuidString, eventId: "evt-1", name: name, email: nil,
          groupId: nil, groupName: nil, tableId: tableId, dietaryPreference: nil,
          notes: nil, createdAt: nil, updatedAt: nil)
}

private func sampleTables() -> [SeatingTable] {
    [makeTable("Table 2", id: "t2", x: 80, y: 80),
     makeTable("Table 10", id: "t10", shape: .rectangle, x: 320, y: 80),
     makeTable("Head Table", id: "t1", shape: .square, x: 80, y: 320)]
}

private func sampleGuests() -> [Guest] {
    [makeGuest("Alice Zimmerman", tableId: "t2"),
     makeGuest("Bob Anderson", tableId: "t2"),
     makeGuest("Carol Baker", tableId: "t10"),
     makeGuest("Dave Unassigned", tableId: nil)]
}

private func render(includeGuestList: Bool,
                    tables: [SeatingTable]? = nil,
                    shapes: [DecorShape] = [],
                    rooms: [FloorPlanRoom] = []) -> Data {
    FloorPlanPDFRenderer.render(
        event: makeEvent(),
        tables: tables ?? sampleTables(),
        guests: sampleGuests(),
        shapes: shapes,
        rooms: rooms,
        includeGuestList: includeGuestList
    )
}

// MARK: - Tests

@Suite struct FloorPlanExportTests {

    // MARK: Rendering

    @Test func producesValidPDF() {
        let data = render(includeGuestList: false)
        #expect(data.starts(with: Array("%PDF-".utf8)))
        let doc = PDFDocument(data: data)
        #expect(doc != nil)
        #expect(doc?.pageCount == 1) // floor plan only
    }

    @Test func guestListAddsPages() {
        let withList = PDFDocument(data: render(includeGuestList: true))
        let withoutList = PDFDocument(data: render(includeGuestList: false))
        #expect(withoutList?.pageCount == 1)
        #expect((withList?.pageCount ?? 0) >= 2) // floor plan + ≥1 guest-list page
    }

    @Test func firstPageIsLandscape() {
        let doc = PDFDocument(data: render(includeGuestList: false))
        let bounds = doc?.page(at: 0)?.bounds(for: .mediaBox)
        #expect((bounds?.width ?? 0) > (bounds?.height ?? 0)) // A4 landscape
    }

    @Test func guestListPagesArePortrait() {
        let doc = PDFDocument(data: render(includeGuestList: true))
        // Page 0 is the landscape floor plan; page 1 is the first portrait list page.
        let listBounds = doc?.page(at: 1)?.bounds(for: .mediaBox)
        #expect((listBounds?.height ?? 0) > (listBounds?.width ?? 0))
    }

    @Test func emptyFloorPlanStillRendersOnePage() {
        let data = FloorPlanPDFRenderer.render(
            event: makeEvent(), tables: [], guests: [], shapes: [], rooms: [],
            includeGuestList: false
        )
        #expect(data.starts(with: Array("%PDF-".utf8)))
        #expect(PDFDocument(data: data)?.pageCount == 1)
    }

    @Test func guestNamesAppearInTheDocument() {
        let doc = PDFDocument(data: render(includeGuestList: true))
        let text = doc?.string ?? ""
        #expect(text.contains("Anderson")) // seated guest's surname
        #expect(text.contains("Head Table"))
        // Unassigned guests are intentionally omitted from the list pages.
        #expect(!text.contains("Unassigned"))
    }

    // MARK: Filename generation

    @Test func sanitizesUnsafeFilenameCharacters() {
        #expect(FloorPlanExportFile.sanitize("Smith & Jones: Wedding!") == "Smith___Jones__Wedding_")
        #expect(FloorPlanExportFile.sanitize("Café / Soirée") == "Caf____Soir_e")
        #expect(FloorPlanExportFile.sanitize("") == "event")
        #expect(FloorPlanExportFile.sanitize("///") == "___")
    }

    @Test func temporaryURLIncludesDateAndExtension() {
        var components = DateComponents()
        components.year = 2026; components.month = 6; components.day = 20
        let date = Calendar(identifier: .gregorian).date(from: components)!

        let url = FloorPlanExportFile.temporaryURL(eventName: "My Event", date: date)
        #expect(url.lastPathComponent == "floorplan_My_Event_2026-06-20.pdf")
        #expect(url.pathExtension == "pdf")
    }

    @Test func writeReplacesStaleFileAtomically() throws {
        let first = try FloorPlanExportFile.write(Data("%PDF-1.4 first".utf8),
                                                  eventName: "Reuse Test",
                                                  date: Date(timeIntervalSince1970: 0))
        let second = try FloorPlanExportFile.write(Data("%PDF-1.4 second".utf8),
                                                   eventName: "Reuse Test",
                                                   date: Date(timeIntervalSince1970: 0))
        #expect(first == second) // same name → same path
        let onDisk = try Data(contentsOf: second)
        #expect(String(decoding: onDisk, as: UTF8.self) == "%PDF-1.4 second")
        try? FileManager.default.removeItem(at: second)
    }

    @Test func endToEndExportSavesValidFile() throws {
        let data = render(includeGuestList: true)
        let url = try FloorPlanExportFile.write(data, eventName: makeEvent().name)
        defer { try? FileManager.default.removeItem(at: url) }
        let reopened = PDFDocument(url: url)
        #expect(reopened != nil)
        #expect((reopened?.pageCount ?? 0) >= 2)
    }
}
