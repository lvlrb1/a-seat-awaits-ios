//
//  ImportAndErrorTests.swift
//  A Seat AwaitsTests
//
//  Unit tests for the pure logic added in the design-audit pass: import name
//  normalization / duplicate detection (F6) and the friendly error mapper (F10).
//

import Foundation
import Testing
@testable import A_Seat_Awaits

@Suite("Import name normalization (F6)")
struct NormalizedNameTests {

    @Test("Case and surrounding whitespace are ignored")
    func caseAndTrim() {
        #expect(GuestImportParser.normalizedName("  Olivia Brown ")
                == GuestImportParser.normalizedName("olivia brown"))
    }

    @Test("Internal whitespace runs collapse")
    func collapseSpaces() {
        #expect(GuestImportParser.normalizedName("Olivia   Brown")
                == "olivia brown")
    }

    @Test("Different names do not collide")
    func distinctNames() {
        #expect(GuestImportParser.normalizedName("Olivia Brown")
                != GuestImportParser.normalizedName("Oliver Brown"))
    }

    @Test("Duplicate detection flags an existing guest by normalized name")
    func duplicateMatch() {
        let existing = ["Olivia Brown", "Jackson Brown"]
            .map { GuestImportParser.normalizedName($0) }
        let set = Set(existing)
        #expect(set.contains(GuestImportParser.normalizedName("  olivia   brown ")))
        #expect(!set.contains(GuestImportParser.normalizedName("Layla Adams")))
    }
}

@Suite("Friendly error mapping (F10)")
struct FriendlyErrorTests {

    @Test("Offline URLError is detected and mapped to an offline message")
    func offlineDetection() {
        let err = URLError(.notConnectedToInternet)
        #expect(FriendlyError.isOffline(err))
        #expect(FriendlyError.message(for: err).localizedCaseInsensitiveContains("offline"))
    }

    @Test("SupabaseError.offline is treated as offline")
    func supabaseOffline() {
        #expect(FriendlyError.isOffline(SupabaseError.offline))
    }

    @Test("HTTP 403 maps to a permission message, never raw server text")
    func permissionMapping() {
        let raw = "permission denied for table guests"
        let message = FriendlyError.message(for: SupabaseError.http(status: 403, message: raw))
        #expect(!message.contains(raw))
        #expect(message.localizedCaseInsensitiveContains("permission"))
    }

    @Test("Server 5xx never surfaces a raw JSON-ish string")
    func serverErrorSanitized() {
        let raw = "{\"code\":\"500\",\"details\":null}"
        let message = FriendlyError.message(for: SupabaseError.http(status: 500, message: raw))
        #expect(!message.contains("{"))
    }

    @Test("Unknown default status drops JSON-shaped server text for a calm line")
    func defaultDropsJSON() {
        let raw = "{\"hint\":\"weird\"}"
        let message = FriendlyError.message(for: SupabaseError.http(status: 418, message: raw))
        #expect(!message.contains("{"))
    }
}
