//
//  ImportDedupeTests.swift
//  A Seat AwaitsTests
//
//  Duplicate detection for guest imports: diacritic and punctuation folding in
//  `normalizedName`, and in-list deduplication via `duplicateFlags`.
//

import Foundation
import Testing
@testable import A_Seat_Awaits

@Suite("Import duplicate detection: folding")
struct ImportNameFoldingTests {

    @Test("Diacritics fold away")
    func diacritics() {
        #expect(GuestImportParser.normalizedName("José Núñez") == GuestImportParser.normalizedName("Jose Nunez"))
        #expect(GuestImportParser.normalizedName("Zoë Müller") == "zoe muller")
    }

    @Test("Apostrophes and periods are stripped")
    func punctuation() {
        #expect(GuestImportParser.normalizedName("O'Brien") == GuestImportParser.normalizedName("OBrien"))
        #expect(GuestImportParser.normalizedName("Dr. J. Smith") == "dr j smith")
        // Curly apostrophes too.
        #expect(GuestImportParser.normalizedName("O’Brien") == "obrien")
    }

    @Test("Hyphens join words rather than gluing them together")
    func hyphens() {
        #expect(GuestImportParser.normalizedName("Smith-Jones") == "smith jones")
        #expect(GuestImportParser.normalizedName("Mary-Kate Olsen") == GuestImportParser.normalizedName("Mary Kate Olsen"))
    }

    @Test("Distinct names still differ")
    func distinct() {
        #expect(GuestImportParser.normalizedName("Olivia Brown") != GuestImportParser.normalizedName("Olivier Brown"))
    }
}

@Suite("Import duplicate detection: in-list")
struct ImportDuplicateFlagsTests {

    @Test("A repeated name in the same paste is flagged from the second copy on")
    func repeatedInList() {
        let flags = GuestImportParser.duplicateFlags(
            for: ["Olivia Brown", "Layla Adams", "olivia   brown", "Olívia Brown"],
            existing: [])
        #expect(flags == [false, false, true, true])
    }

    @Test("Existing guests flag the first copy too")
    func existingGuests() {
        let existing: Set<String> = [GuestImportParser.normalizedName("Olivia Brown")]
        let flags = GuestImportParser.duplicateFlags(for: ["Olivia Brown", "Layla Adams"], existing: existing)
        #expect(flags == [true, false])
    }

    @Test("Blank names are never flagged")
    func blanks() {
        let flags = GuestImportParser.duplicateFlags(for: ["", "   ", ""], existing: [])
        #expect(flags == [false, false, false])
    }
}
