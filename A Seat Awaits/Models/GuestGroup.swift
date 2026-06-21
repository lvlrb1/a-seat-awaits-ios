//
//  GuestGroup.swift
//  A Seat Awaits
//
//  Mirrors the `guest_groups` table.
//

import Foundation
import SwiftUI

nonisolated struct GuestGroup: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let eventId: String
    var name: String
    var color: String?
    var description: String?
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, color, description
        case eventId = "event_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Parses the stored hex color (e.g. "#7C3AED"), falling back to brand purple.
    /// `@MainActor` because the `Brand` palette is main-actor isolated; this is a
    /// view-display helper, so that's where it's used anyway.
    @MainActor var swiftUIColor: Color {
        Color(hex: color) ?? Brand.purple
    }
}

extension Color {
    /// Creates a color from a `#RRGGBB` or `#RRGGBBAA` hex string.
    init?(hex: String?) {
        guard let hex else { return nil }
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        switch s.count {
        case 6:
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
            a = 1
        case 8:
            r = Double((value & 0xFF000000) >> 24) / 255
            g = Double((value & 0x00FF0000) >> 16) / 255
            b = Double((value & 0x0000FF00) >> 8) / 255
            a = Double(value & 0x000000FF) / 255
        default:
            return nil
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
