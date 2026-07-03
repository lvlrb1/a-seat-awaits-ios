//
//  GuestImportParser.swift
//  A Seat Awaits
//
//  On-device guest import parser. AI import now runs server-side via the
//  `ai-import-guests` Supabase Edge Function (see `GuestImportService`); this
//  pure, network-free heuristic parser is the OFFLINE FALLBACK used when that
//  call fails — it turns messy pasted/CSV text into structured `ParsedGuest`s.
//
//  Kept deliberately pure (no SwiftUI, no I/O) so it is fully unit-testable.
//
//  Handles formats such as:
//    Adams, Layla & +1 — veg
//    chris anderson (eng) table?
//    Brown, Jackson - GF, w/ partner
//    Olivia Brown — marketing
//

import Foundation

// MARK: - Parsed model

/// One structured guest extracted from a line of pasted text.
struct ParsedGuest: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// Title-cased "First Last" name.
    var name: String
    /// Optional household / group name (from parentheses or a trailing "— word").
    var group: String?
    /// Optional normalized dietary note (e.g. "Vegetarian", "Gluten-free").
    var dietary: String?
    /// A short hint about an unresolved plus-one / partner, surfaced in the UI.
    var plusOneHint: String?
    /// True when the row carries an unresolved hint (e.g. "+1"/"partner") that a
    /// human should confirm before importing.
    var needsReview: Bool

    static func == (lhs: ParsedGuest, rhs: ParsedGuest) -> Bool {
        lhs.name == rhs.name &&
        lhs.group == rhs.group &&
        lhs.dietary == rhs.dietary &&
        lhs.plusOneHint == rhs.plusOneHint &&
        lhs.needsReview == rhs.needsReview
    }
}

// MARK: - Parser

enum GuestImportParser {

    /// Parses a whole blob of text (one guest per non-empty line).
    static func parse(_ text: String) -> [ParsedGuest] {
        text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { String($0) }
            .compactMap { parseLine($0) }
    }

    /// Parses a single line into a `ParsedGuest`, or `nil` if no name survives.
    static func parseLine(_ rawLine: String) -> ParsedGuest? {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }

        // Drop a leading CSV index/quote artifacts and obvious header rows.
        if isLikelyHeader(line) { return nil }

        // 1. Pull out a parenthetical group, e.g. "(eng)".
        var group: String? = nil
        if let paren = firstParenthetical(in: line) {
            group = normalizeGroup(paren.content)
            line.removeSubrange(paren.range)
            line = line.trimmingCharacters(in: .whitespaces)
        }

        // 2. Detect plus-one / partner hints anywhere in the line.
        var detectedPlusOneHint: String? = nil
        if let hint = plusOneHint(in: line) {
            detectedPlusOneHint = hint
        }

        // 3. Split off the trailing "— note" / "- note" descriptor segment.
        //    Everything after the first dash separator is metadata (dietary,
        //    plus-one, or a group label like "marketing").
        let (head, tail) = splitOnDashSeparator(line)
        var namePart = head
        var metaSegments = tail

        // 4. Also treat comma-separated tail fragments (CSV-ish) as metadata,
        //    BUT keep the very common "Last, First" form intact.
        let commaName = extractCommaName(&namePart, extraMeta: &metaSegments)

        // 5. Normalize dietary from the metadata segments. Unrecognized free
        //    text is dropped — the row UI only surfaces name / group / dietary /
        //    plus-one, so there's nowhere faithful to keep it.
        var dietary: String? = nil
        for seg in metaSegments {
            let cleaned = seg.trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { continue }
            if let diet = normalizeDietary(cleaned) {
                dietary = dietary ?? diet
            } else if isPlusOneToken(cleaned) {
                if detectedPlusOneHint == nil { detectedPlusOneHint = displayPlusOne(cleaned) }
            } else if cleaned.lowercased().hasSuffix("table?") {
                // a "table?" scribble — ignore, it's not data we can keep.
            } else if group == nil, looksLikeGroupLabel(cleaned) {
                group = normalizeGroup(cleaned)
            }
        }

        // 6. Resolve the name. Prefer the "Last, First" extraction if found.
        let resolvedName = commaName ?? titleCasedName(stripTrailingNoise(namePart))
        let finalName = resolvedName.trimmingCharacters(in: .whitespaces)
        guard !finalName.isEmpty, hasLetter(finalName) else { return nil }

        // 7. needsReview when a companion is referenced but un-named — i.e. a
        //    "partner"/"guest" we'd need a human to name. A bare numeric "+1"
        //    is a known party size, so it's surfaced as an annotation but does
        //    not block import.
        let needsReview = detectedPlusOneHint.map { hint in
            let l = hint.lowercased()
            return l.contains("partner") || l.contains("guest")
        } ?? false

        return ParsedGuest(
            name: finalName,
            group: group?.nilIfBlank,
            dietary: dietary,
            plusOneHint: detectedPlusOneHint,
            needsReview: needsReview
        )
    }

    // MARK: - Name handling

    /// If `part` is in "Last, First" form, returns the recombined "First Last"
    /// and strips it out. Otherwise returns nil and leaves `part` untouched.
    /// Trailing comma fragments that are clearly metadata are pushed to `extraMeta`.
    private static func extractCommaName(_ part: inout String, extraMeta: inout [String]) -> String? {
        guard part.contains(",") else { return nil }
        let comps = part.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard comps.count >= 2 else { return nil }

        let last = comps[0]
        let firstField = comps[1]

        // "Last, First" requires both halves to look like name words.
        guard isNameWord(last), isNameWord(firstWordOf(firstField)) else {
            // Not a name reversal — treat the whole thing as name + meta tail.
            part = comps[0]
            extraMeta.append(contentsOf: comps.dropFirst())
            return nil
        }

        // The first name field may itself carry a "& +1" suffix; keep only the
        // leading name word, push the rest to metadata.
        let firstWords = firstField.split(separator: " ").map(String.init)
        var nameWords: [String] = []
        var trailing: [String] = []
        for (i, w) in firstWords.enumerated() {
            if i == 0 || (isNameWord(w) && trailing.isEmpty && !w.contains("+") && w != "&") {
                nameWords.append(w)
            } else {
                trailing.append(w)
            }
        }
        if !trailing.isEmpty { extraMeta.append(trailing.joined(separator: " ")) }
        // Any further comma fields are metadata.
        if comps.count > 2 { extraMeta.append(contentsOf: comps.dropFirst(2)) }

        let recombined = (nameWords + [last]).joined(separator: " ")
        return titleCasedName(stripTrailingNoise(recombined))
    }

    private static func firstWordOf(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }

    /// A normalized key for duplicate detection: lowercased, trimmed, with runs
    /// of whitespace collapsed to a single space (F6).
    static func normalizedName(_ name: String) -> String {
        name.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Title-cases each word of a name ("chris anderson" → "Chris Anderson").
    static func titleCasedName(_ name: String) -> String {
        name
            .split(separator: " ")
            .map { word -> String in
                let w = String(word)
                guard let first = w.first else { return w }
                return String(first).uppercased() + w.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    /// Removes trailing scribbles like "& +1", "w/ partner", "table?".
    private static func stripTrailingNoise(_ s: String) -> String {
        var out = s
        for token in ["& +1", "&+1", "+1", "w/ partner", "w/partner", "and guest", "& guest", "table?"] {
            if let r = out.range(of: token, options: [.caseInsensitive, .backwards]) {
                out.removeSubrange(r)
            }
        }
        return out
            .trimmingCharacters(in: CharacterSet(charactersIn: " &-,"))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Group handling

    private struct Parenthetical { let content: String; let range: Range<String.Index> }

    private static func firstParenthetical(in s: String) -> Parenthetical? {
        guard let open = s.firstIndex(of: "("),
              let close = s[open...].firstIndex(of: ")") else { return nil }
        let content = String(s[s.index(after: open)..<close])
        return Parenthetical(content: content, range: open..<s.index(after: close))
    }

    /// Expands common abbreviations and title-cases a group label.
    static func normalizeGroup(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let expansions: [String: String] = [
            "eng": "Engineering",
            "mktg": "Marketing",
            "ops": "Operations",
            "hr": "HR",
            "exec": "Executive",
            "sales": "Sales",
        ]
        let key = trimmed.lowercased()
        if let exp = expansions[key] { return exp }
        if key == "hr" { return "HR" }
        return titleCasedName(trimmed)
    }

    /// A trailing single-word descriptor like "marketing"/"eng" reads as a group
    /// label rather than a dietary note.
    private static func looksLikeGroupLabel(_ s: String) -> Bool {
        let words = s.split(separator: " ")
        guard words.count <= 2 else { return false }
        guard hasLetter(s) else { return false }
        // Must not be a recognized dietary token (already handled before this).
        return normalizeDietary(s) == nil && !isPlusOneToken(s)
    }

    // MARK: - Dietary handling

    /// Normalizes a dietary token to a canonical label, or nil if unrecognized.
    static func normalizeDietary(_ raw: String) -> String? {
        let key = raw
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,;"))
        switch key {
        case "veg", "vegetarian": return "Vegetarian"
        case "vegan": return "Vegan"
        case "gf", "gluten-free", "gluten free", "glutenfree", "no gluten": return "Gluten-free"
        case "df", "dairy-free", "dairy free", "no dairy", "lactose-free": return "Dairy-free"
        case "nf", "nut-free", "nut free", "no nuts": return "Nut-free"
        case "halal": return "Halal"
        case "kosher": return "Kosher"
        case "pescatarian", "pesc": return "Pescatarian"
        case "shellfish", "no shellfish", "shellfish allergy": return "Shellfish allergy"
        default: return nil
        }
    }

    // MARK: - Plus-one handling

    private static func plusOneHint(in line: String) -> String? {
        let lower = line.lowercased()
        if lower.contains("+1") || lower.contains("plus one") || lower.contains("plus-one") {
            return "Confirm +1 name"
        }
        if lower.contains("w/ partner") || lower.contains("w/partner") || lower.contains("with partner") || lower.contains("+ partner") {
            return "Confirm partner name"
        }
        if lower.contains("and guest") || lower.contains("& guest") || lower.contains("+ guest") {
            return "Confirm guest name"
        }
        return nil
    }

    private static func isPlusOneToken(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.contains("+1") || lower.contains("partner") ||
               lower.contains("plus one") || lower.contains("plus-one") ||
               lower == "guest" || lower.contains("and guest") || lower.contains("& guest")
    }

    private static func displayPlusOne(_ s: String) -> String {
        let lower = s.lowercased()
        if lower.contains("partner") { return "Confirm partner name" }
        if lower.contains("guest") { return "Confirm guest name" }
        return "Confirm +1 name"
    }

    // MARK: - Splitting helpers

    /// Splits a line into (name-head, [meta-segments]) on the first em/en/hyphen
    /// "— " separator. Returns the whole line as head when no separator exists.
    private static func splitOnDashSeparator(_ line: String) -> (String, [String]) {
        // Try em/en dashes first (used in the spec), then " - " hyphen.
        for sep in ["—", "–", " - "] {
            if let r = line.range(of: sep) {
                let head = String(line[..<r.lowerBound])
                let tailRaw = String(line[r.upperBound...])
                // Tail may carry several comma-separated notes.
                let segs = tailRaw.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                return (head.trimmingCharacters(in: .whitespaces), segs)
            }
        }
        return (line, [])
    }

    // MARK: - Token predicates

    private static func isNameWord(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        // Letters, optional internal hyphen/apostrophe. No digits, no "+".
        return t.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" || $0 == "." } && t.contains(where: { $0.isLetter })
    }

    private static func hasLetter(_ s: String) -> Bool { s.contains(where: { $0.isLetter }) }

    private static func isLikelyHeader(_ line: String) -> Bool {
        let lower = line.lowercased()
        let headerSignals = ["name,", "first name", "last name", "full name", "guest name", "email,"]
        return headerSignals.contains { lower.hasPrefix($0) }
    }
}

// MARK: - Aggregate counts for the review summary

extension Array where Element == ParsedGuest {
    var householdCount: Int {
        Set(compactMap { $0.group?.nilIfBlank }).count
    }
    var dietaryCount: Int {
        filter { $0.dietary?.nilIfBlank != nil }.count
    }
    var needsReviewCount: Int {
        filter { $0.needsReview }.count
    }
}
