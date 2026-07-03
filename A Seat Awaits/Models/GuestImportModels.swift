//
//  GuestImportModels.swift
//  A Seat Awaits
//
//  Request/response DTOs for the `ai-import-guests` Supabase Edge Function — the
//  AI guest extractor that mirrors the web app. It pulls EVERY person from a
//  pasted list, CSV, or Excel (.xlsx/.xls) file — primary adult, partner, and
//  children (with family-surname inference). The app holds NO AI key: it sends
//  only { eventId, text } or { eventId, fileBase64, filename }; the function
//  decides the model, prompt, plan entitlement and rate limits server-side
//  (see [[ios-architecture]], [[ai-guest-import]]). Failures surface as the
//  shared `EdgeFunctionError` so the import UI can fall back gracefully.
//

import Foundation

// MARK: - Input

/// What the user is importing: either pasted/CSV text, or a binary spreadsheet.
enum GuestImportInput: Sendable {
    case text(String)
    case file(data: Data, name: String)
}

// MARK: - Request (the ONLY fields iOS supplies)

/// Body for `ai-import-guests`. `text` for paste/CSV; `fileBase64`+`filename`
/// for Excel. Optionals are omitted from the JSON when nil.
nonisolated struct AiGuestImportRequest: Encodable, Sendable {
    let eventId: String
    let text: String?
    let fileBase64: String?
    let filename: String?
}

// MARK: - Response

/// One AI-extracted guest. `needsReview` flags single names, inferred child
/// surnames, and other ambiguities a human should confirm.
nonisolated struct AiImportedGuest: Decodable, Sendable {
    let fullName: String
    let needsReview: Bool
    let reason: String?

    private enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case needsReview = "needs_review"
        case reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fullName = try c.decode(String.self, forKey: .fullName)
        needsReview = try c.decodeIfPresent(Bool.self, forKey: .needsReview) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }
}

/// A line the AI couldn't turn into a name, with a reason (surfaced for logging;
/// not shown in the review list today).
nonisolated struct AiDroppedLine: Decodable, Sendable {
    let raw: String
    let reason: String
}

/// The structured preview returned by `ai-import-guests`.
nonisolated struct AiGuestImportResponse: Decodable, Sendable {
    let ok: Bool
    let guests: [AiImportedGuest]
    let dropped: [AiDroppedLine]
    let receivedLines: Int?
    let needsReviewCount: Int?
    let usedAi: Bool?

    private enum CodingKeys: String, CodingKey {
        case ok, guests, dropped, receivedLines, needsReviewCount, usedAi
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        guests = try c.decodeIfPresent([AiImportedGuest].self, forKey: .guests) ?? []
        dropped = try c.decodeIfPresent([AiDroppedLine].self, forKey: .dropped) ?? []
        receivedLines = try c.decodeIfPresent(Int.self, forKey: .receivedLines)
        needsReviewCount = try c.decodeIfPresent(Int.self, forKey: .needsReviewCount)
        usedAi = try c.decodeIfPresent(Bool.self, forKey: .usedAi)
    }

    /// Maps the AI response into the app's `ParsedGuest` review model. The AI is
    /// names-focused (no dietary/group), so those are left empty; `needsReview`
    /// carries the AI's per-guest confirm flag.
    func parsedGuests() -> [ParsedGuest] {
        guests.map { guest in
            ParsedGuest(
                name: guest.fullName,
                group: nil,
                dietary: nil,
                plusOneHint: nil,
                needsReview: guest.needsReview
            )
        }
    }
}
