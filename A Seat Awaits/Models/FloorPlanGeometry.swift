//
//  FloorPlanGeometry.swift
//  A Seat Awaits
//
//  Pure, UI-free geometry for the floor-plan canvas: grid snapping, Figma-style
//  alignment guides, and overlap (collision) detection. Ported from the web
//  composables (`useAlignmentGuides`, `useCollisionDetection`) so iOS- and
//  web-authored layouts behave identically. Kept free of SwiftUI so it can be
//  unit-tested in isolation.
//
//  Conventions (all distances in canvas points, 24pt = 1ft):
//    • An item's `x`/`y` is its *un-rotated* top-left corner.
//    • `rotation` is degrees, applied about the item's center.
//    • Snap results are returned as the dragged item's new top-left, so the
//      renderer can keep treating position as the un-rotated top-left and apply
//      rotation about the center separately.
//

import Foundation

enum FloorPlanGeometry {

    /// A positioned, optionally-rotated rectangle on the canvas.
    struct Item: Equatable, Sendable {
        var id: String
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var rotation: Double = 0
    }

    /// The *visual* (rotation-aware) axis-aligned bounds of an item.
    struct Bounds: Equatable, Sendable {
        var left, right, top, bottom, centerX, centerY: Double
    }

    /// Default snap grid: 48pt = 2ft, matching the web `gridSpacing` default.
    static let defaultGridSpacing: Double = 48

    // MARK: - Grid snap

    /// Snaps a single coordinate to the nearest grid line. A non-positive
    /// spacing (or `enabled == false`) returns the value unchanged.
    static func snapToGrid(_ value: Double,
                           spacing: Double = defaultGridSpacing,
                           enabled: Bool = true) -> Double {
        guard enabled, spacing > 0 else { return value }
        return (value / spacing).rounded() * spacing
    }

    // MARK: - Bounds

    /// Smallest axis-aligned box containing the item after rotation about its
    /// center. For an un-rotated item this is just its rectangle.
    static func bounds(_ item: Item) -> Bounds {
        let cx = item.x + item.width / 2
        let cy = item.y + item.height / 2
        let rot = item.rotation * .pi / 180
        // |cos|/|sin|: the AABB extent is symmetric in the rotation's sign.
        let absCos = abs(cos(rot)), absSin = abs(sin(rot))
        let effW = item.width * absCos + item.height * absSin
        let effH = item.width * absSin + item.height * absCos
        return Bounds(left: cx - effW / 2, right: cx + effW / 2,
                      top: cy - effH / 2, bottom: cy + effH / 2,
                      centerX: cx, centerY: cy)
    }

    // MARK: - Alignment guides

    enum GuideAxis: Sendable { case vertical, horizontal }

    /// A single rendered guide line. For a vertical guide draw from
    /// `(position, start)` to `(position, end)`; for horizontal, swap the axes.
    struct Guide: Equatable, Sendable {
        var axis: GuideAxis
        var position: Double
        var start: Double
        var end: Double
    }

    /// The outcome of an alignment pass: the snapped top-left coordinate on each
    /// axis (nil when that axis didn't snap) plus the guide lines to draw.
    struct SnapResult: Equatable, Sendable {
        var x: Double?
        var y: Double?
        var guides: [Guide] = []
    }

    /// Snaps `dragged` against every item in `others` (edges + centers) and,
    /// optionally, a room's center mid-lines. `threshold` is the engagement
    /// distance in *world* points — the caller is expected to divide its screen
    /// threshold by the current zoom so snapping feels consistent at any scale.
    ///
    /// Returns the snapped top-left for whichever axes engaged, plus the guide
    /// lines spanning the dragged item and its match (padded for legibility).
    static func alignmentSnap(dragged: Item,
                              others: [Item],
                              roomSize: (width: Double, height: Double)? = nil,
                              threshold: Double = 8,
                              guidePadding: Double = 24) -> SnapResult {
        let drag = bounds(dragged)
        let halfVisW = (drag.right - drag.left) / 2
        let halfVisH = (drag.bottom - drag.top) / 2

        // Convert "where the visual edge/center should land" into a new top-left.
        func topLeftX(visualLeft target: Double) -> Double { target + halfVisW - dragged.width / 2 }
        func topLeftX(visualRight target: Double) -> Double { target - halfVisW - dragged.width / 2 }
        func topLeftX(center target: Double) -> Double { target - dragged.width / 2 }
        func topLeftY(visualTop target: Double) -> Double { target + halfVisH - dragged.height / 2 }
        func topLeftY(visualBottom target: Double) -> Double { target - halfVisH - dragged.height / 2 }
        func topLeftY(center target: Double) -> Double { target - dragged.height / 2 }

        struct Candidate { var topLeft: Double; var distance: Double; var line: Double; var lo: Double; var hi: Double }
        var bestX: Candidate?
        var bestY: Candidate?

        func considerX(dragEdge: Double, target: Double, topLeft: Double, line: Double, span: (Double, Double)) {
            let d = abs(dragEdge - target)
            guard d < threshold else { return }
            if bestX == nil || d < bestX!.distance {
                bestX = Candidate(topLeft: topLeft, distance: d, line: line, lo: span.0, hi: span.1)
            }
        }
        func considerY(dragEdge: Double, target: Double, topLeft: Double, line: Double, span: (Double, Double)) {
            let d = abs(dragEdge - target)
            guard d < threshold else { return }
            if bestY == nil || d < bestY!.distance {
                bestY = Candidate(topLeft: topLeft, distance: d, line: line, lo: span.0, hi: span.1)
            }
        }

        for item in others where item.id != dragged.id {
            let b = bounds(item)
            let xSpan = (min(drag.top, b.top), max(drag.bottom, b.bottom))
            let ySpan = (min(drag.left, b.left), max(drag.right, b.right))

            // Vertical alignments (X position): edge-to-edge + center + opposite edges.
            considerX(dragEdge: drag.left,  target: b.left,  topLeft: topLeftX(visualLeft: b.left),   line: b.left,  span: xSpan)
            considerX(dragEdge: drag.right, target: b.right, topLeft: topLeftX(visualRight: b.right), line: b.right, span: xSpan)
            considerX(dragEdge: drag.centerX, target: b.centerX, topLeft: topLeftX(center: b.centerX), line: b.centerX, span: xSpan)
            considerX(dragEdge: drag.left,  target: b.right, topLeft: topLeftX(visualLeft: b.right),  line: b.right, span: xSpan)
            considerX(dragEdge: drag.right, target: b.left,  topLeft: topLeftX(visualRight: b.left),  line: b.left,  span: xSpan)

            // Horizontal alignments (Y position).
            considerY(dragEdge: drag.top,    target: b.top,    topLeft: topLeftY(visualTop: b.top),       line: b.top,    span: ySpan)
            considerY(dragEdge: drag.bottom, target: b.bottom, topLeft: topLeftY(visualBottom: b.bottom), line: b.bottom, span: ySpan)
            considerY(dragEdge: drag.centerY, target: b.centerY, topLeft: topLeftY(center: b.centerY),    line: b.centerY, span: ySpan)
            considerY(dragEdge: drag.top,    target: b.bottom, topLeft: topLeftY(visualTop: b.bottom),    line: b.bottom, span: ySpan)
            considerY(dragEdge: drag.bottom, target: b.top,    topLeft: topLeftY(visualBottom: b.top),    line: b.top,    span: ySpan)
        }

        // Room center mid-lines (the layout's natural focal point).
        if let room = roomSize {
            let roomCenterX = room.width / 2
            let roomCenterY = room.height / 2
            considerX(dragEdge: drag.centerX, target: roomCenterX,
                      topLeft: topLeftX(center: roomCenterX), line: roomCenterX,
                      span: (min(drag.top, 0), max(drag.bottom, room.height)))
            considerY(dragEdge: drag.centerY, target: roomCenterY,
                      topLeft: topLeftY(center: roomCenterY), line: roomCenterY,
                      span: (min(drag.left, 0), max(drag.right, room.width)))
        }

        var result = SnapResult()
        if let bestX {
            result.x = bestX.topLeft
            result.guides.append(Guide(axis: .vertical, position: bestX.line,
                                       start: bestX.lo - guidePadding, end: bestX.hi + guidePadding))
        }
        if let bestY {
            result.y = bestY.topLeft
            result.guides.append(Guide(axis: .horizontal, position: bestY.line,
                                       start: bestY.lo - guidePadding, end: bestY.hi + guidePadding))
        }
        return result
    }

    // MARK: - Collision

    /// The four corners of an item's rotated rectangle (about its center).
    private static func corners(_ item: Item) -> [(x: Double, y: Double)] {
        let cx = item.x + item.width / 2
        let cy = item.y + item.height / 2
        let hw = item.width / 2, hh = item.height / 2
        let r = item.rotation * .pi / 180
        let c = cos(r), s = sin(r)
        return [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].map { dx, dy in
            (x: cx + dx * c - dy * s, y: cy + dx * s + dy * c)
        }
    }

    /// Whether two items' footprints overlap. Uses a fast AABB reject, then the
    /// Separating Axis Theorem for the rotated case so spinning a rectangle
    /// doesn't report phantom overlaps from its un-rotated bounding box.
    static func collides(_ a: Item, _ b: Item) -> Bool {
        let ba = bounds(a), bb = bounds(b)
        // AABB quick reject on the visual bounds.
        if ba.right <= bb.left || ba.left >= bb.right ||
           ba.bottom <= bb.top || ba.top >= bb.bottom { return false }
        // Axis-aligned pair: the AABB test above is exact.
        if a.rotation == 0 && b.rotation == 0 { return true }

        let ca = corners(a), cb = corners(b)
        let r1 = a.rotation * .pi / 180, r2 = b.rotation * .pi / 180
        let axes = [(cos(r1), sin(r1)), (-sin(r1), cos(r1)),
                    (cos(r2), sin(r2)), (-sin(r2), cos(r2))]
        for (ax, ay) in axes {
            var min1 = Double.greatestFiniteMagnitude, max1 = -Double.greatestFiniteMagnitude
            var min2 = Double.greatestFiniteMagnitude, max2 = -Double.greatestFiniteMagnitude
            for p in ca { let proj = p.x * ax + p.y * ay; min1 = min(min1, proj); max1 = max(max1, proj) }
            for p in cb { let proj = p.x * ax + p.y * ay; min2 = min(min2, proj); max2 = max(max2, proj) }
            if max1 < min2 || max2 < min1 { return false }   // gap on this axis → no overlap
        }
        return true
    }

    /// IDs of every item that `item` overlaps within `others` (excluding itself).
    static func collisions(for item: Item, among others: [Item]) -> [String] {
        others.filter { $0.id != item.id && collides(item, $0) }.map(\.id)
    }
}
