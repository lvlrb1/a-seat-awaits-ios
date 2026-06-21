//
//  TablePreset.swift
//  A Seat Awaits
//
//  Real-world table sizing and the preset table types. The backend stores table
//  `width`/`height` in canvas points where 24 points == 1 foot (matching the web
//  floor-plan canvas), so every foot/inch conversion lives here. The presets are
//  mirrored 1:1 from the web `TABLE_TYPE_SPECS` so iOS- and web-authored tables
//  share identical dimensions.
//

import Foundation

/// Conversions between real-world feet/inches and canvas points (24pt = 1ft).
/// Pure value math — kept `nonisolated` so the data models that call it (which
/// are themselves `nonisolated`) don't trip the default-MainActor isolation.
nonisolated enum TableScale {
    static let pointsPerFoot: Double = 24
    static let pointsPerInch: Double = 2

    static func feet(_ ft: Double) -> Double { ft * pointsPerFoot }
    static func inches(_ inch: Double) -> Double { inch * pointsPerInch }
    static func toFeet(points: Double) -> Double { points / pointsPerFoot }

    /// Formats a feet value compactly: "4", "2.5".
    static func feetLabel(_ ft: Double) -> String {
        ft == ft.rounded() ? String(Int(ft)) : String(format: "%.1f", ft)
    }
}

/// A preset table type. Dimensions are in canvas points (24pt = 1ft).
nonisolated struct TablePreset: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let shape: TableShape
    let capacity: Int
    let width: Double
    let height: Double

    /// The seven standard banquet presets, in display order (matches the web).
    static let all: [TablePreset] = [
        TablePreset(id: "rectangle-4ft", label: "4' Rectangle", shape: .rectangle, capacity: 4,
                    width: TableScale.feet(4), height: TableScale.inches(30)),
        TablePreset(id: "rectangle-6ft", label: "6' Rectangle", shape: .rectangle, capacity: 8,
                    width: TableScale.feet(6), height: TableScale.inches(30)),
        TablePreset(id: "rectangle-8ft", label: "8' Rectangle", shape: .rectangle, capacity: 10,
                    width: TableScale.feet(8), height: TableScale.inches(30)),
        TablePreset(id: "square-48in", label: "48\" Square", shape: .square, capacity: 4,
                    width: TableScale.inches(48), height: TableScale.inches(48)),
        TablePreset(id: "round-48in", label: "48\" Round", shape: .circle, capacity: 8,
                    width: TableScale.inches(48), height: TableScale.inches(48)),
        TablePreset(id: "round-60in", label: "60\" Round", shape: .circle, capacity: 10,
                    width: TableScale.inches(60), height: TableScale.inches(60)),
        TablePreset(id: "round-72in", label: "72\" Round", shape: .circle, capacity: 12,
                    width: TableScale.inches(72), height: TableScale.inches(72)),
    ]

    /// The preset whose shape + dimensions match a table, if any (else custom).
    static func match(shape: TableShape, width: Double, height: Double) -> TablePreset? {
        all.first { $0.shape == shape && abs($0.width - width) < 0.5 && abs($0.height - height) < 0.5 }
    }
}
