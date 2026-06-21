//
//  FloorPlanGeometryTests.swift
//  A Seat AwaitsTests
//
//  Unit tests for the pure floor-plan geometry: grid snap, rotation-aware
//  bounds, alignment guides, and overlap detection.
//

import Testing
@testable import A_Seat_Awaits

private typealias G = FloorPlanGeometry

private func item(_ id: String, _ x: Double, _ y: Double,
                  _ w: Double, _ h: Double, rot: Double = 0) -> G.Item {
    G.Item(id: id, x: x, y: y, width: w, height: h, rotation: rot)
}

// MARK: - Grid snap

@Test func gridSnapRoundsToNearestLine() {
    #expect(G.snapToGrid(0, spacing: 48) == 0)
    #expect(G.snapToGrid(23, spacing: 48) == 0)
    #expect(G.snapToGrid(25, spacing: 48) == 48)
    #expect(G.snapToGrid(71, spacing: 48) == 48)
    #expect(G.snapToGrid(72, spacing: 48) == 96)
}

@Test func gridSnapBypassedWhenDisabledOrZeroSpacing() {
    #expect(G.snapToGrid(37, spacing: 48, enabled: false) == 37)
    #expect(G.snapToGrid(37, spacing: 0) == 37)
}

// MARK: - Bounds

@Test func boundsForUnrotatedMatchRectangle() {
    let b = G.bounds(item("a", 10, 20, 100, 40))
    #expect(b.left == 10)
    #expect(b.right == 110)
    #expect(b.top == 20)
    #expect(b.bottom == 60)
    #expect(b.centerX == 60)
    #expect(b.centerY == 40)
}

@Test func boundsRotated90SwapExtents() {
    // A 100×20 bar rotated 90° about its center occupies a 20×100 footprint.
    let b = G.bounds(item("a", 0, 0, 100, 20, rot: 90))
    #expect(abs((b.right - b.left) - 20) < 0.001)
    #expect(abs((b.bottom - b.top) - 100) < 0.001)
    #expect(abs(b.centerX - 50) < 0.001)
    #expect(abs(b.centerY - 10) < 0.001)
}

// MARK: - Alignment

@Test func alignmentSnapsLeftEdgesWhenClose() {
    let other = item("o", 100, 100, 50, 50)
    let dragged = item("d", 104, 300, 50, 50)   // left edge 4pt off, far below
    let result = G.alignmentSnap(dragged: dragged, others: [other], threshold: 8)
    #expect(result.x != nil)
    #expect(abs((result.x ?? -1) - 100) < 0.001)   // top-left snaps so left edges meet
    #expect(result.y == nil)                         // 200pt apart vertically: no snap
    #expect(result.guides.contains { $0.axis == .vertical })
}

@Test func alignmentSnapsCentersWhenEdgesAreFar() {
    let other = item("o", 100, 0, 100, 50)           // center x = 150
    let dragged = item("d", 131, 0, 40, 50)          // center 151, edges far from o's
    let result = G.alignmentSnap(dragged: dragged, others: [other], threshold: 8)
    #expect(result.x != nil)
    #expect(abs((result.x ?? -1) - 130) < 0.001)     // center→center: 150 - 20
}

@Test func alignmentDoesNotSnapWhenBeyondThreshold() {
    let other = item("o", 100, 100, 50, 50)
    let dragged = item("d", 400, 400, 50, 50)
    let result = G.alignmentSnap(dragged: dragged, others: [other], threshold: 8)
    #expect(result.x == nil)
    #expect(result.y == nil)
    #expect(result.guides.isEmpty)
}

@Test func alignmentIgnoresSelf() {
    let a = item("a", 100, 100, 50, 50)
    let result = G.alignmentSnap(dragged: a, others: [a], threshold: 8)
    #expect(result.x == nil)
    #expect(result.y == nil)
}

// MARK: - Collision

@Test func overlappingItemsCollide() {
    #expect(G.collides(item("a", 0, 0, 50, 50), item("b", 25, 25, 50, 50)))
}

@Test func separatedItemsDoNotCollide() {
    #expect(!G.collides(item("a", 0, 0, 50, 50), item("b", 60, 0, 50, 50)))
}

@Test func edgeTouchingItemsDoNotCollide() {
    // Sharing an edge is not an overlap.
    #expect(!G.collides(item("a", 0, 0, 50, 50), item("b", 50, 0, 50, 50)))
}

@Test func rotationChangesCollisionOutcome() {
    let bar = item("a", 0, 0, 100, 20)
    let other = item("b", 45, 40, 20, 20)
    #expect(!G.collides(bar, other))                       // horizontal bar misses
    let rotated = item("a", 0, 0, 100, 20, rot: 90)        // now a vertical bar
    #expect(G.collides(rotated, other))                    // …reaches down to it
}

@Test func collisionsListExcludesSelfAndReportsIds() {
    let dragged = item("d", 0, 0, 50, 50)
    let others = [item("d", 0, 0, 50, 50),     // same id — ignored
                  item("hit", 20, 20, 50, 50),
                  item("miss", 500, 500, 50, 50)]
    let ids = G.collisions(for: dragged, among: others)
    #expect(ids == ["hit"])
}
