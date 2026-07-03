//
//  FloorPlanPDFRenderer.swift
//  A Seat Awaits
//
//  Native port of the web app's server-side floor-plan PDF (a-seat-awaits:
//  server/api/events/[eventId]/floorplan/export.pdf.post.ts + floorplanExport.ts
//  + the seat-position math from useSeatPositions.ts). It draws the exact same
//  document the Nuxt server would — A4 landscape vector seating chart with a
//  branded poster frame, plus optional A4 portrait guest-list pages — using
//  Core Graphics instead of PDFKit (node). The app already holds all the data
//  locally, so the PDF is generated on-device with no server round-trip.
//
//  pdfkit and UIKit's PDF context share a top-left origin with y increasing
//  downward, so the drawing calls translate almost 1:1.
//

import UIKit

// MARK: - Brand palette (mirrors the web `BRAND` constants)

private enum PDFBrand {
    static let purple = uiColor("#43204f")
    static let purpleDark = uiColor("#371a40")
    static let purpleLight = uiColor("#6b3a7d")
    static let ink = uiColor("#1f2937")
    static let muted = uiColor("#9ca3af")
    static let subtle = uiColor("#6b7280")
}

private let pixelsPerFoot: CGFloat = 24
private let site = "aseatawaits.com"

// A4 in PostScript points (pdfkit's 'A4'), portrait.
private let a4Width: CGFloat = 595.28
private let a4Height: CGFloat = 841.89

// MARK: - Public entry

/// Renders the floor-plan PDF and returns its bytes. Safe to call off the main
/// actor (operates only on value-type model data + thread-confined UIKit types).
nonisolated enum FloorPlanPDFRenderer {

    static func render(event: Event,
                       tables: [SeatingTable],
                       guests: [Guest],
                       shapes: [DecorShape],
                       rooms: [FloorPlanRoom],
                       includeGuestList: Bool) -> Data {
        Renderer(event: event, tables: tables, guests: guests,
                 shapes: shapes, rooms: rooms,
                 includeGuestList: includeGuestList).makeData()
    }
}

// MARK: - Renderer

// `nonisolated` so the renderer can run entirely off the main actor (it only
// touches value-type model data + thread-confined UIKit types). Without this,
// the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting would infer
// this class as @MainActor, making its init / makeData() / byLastName
// main-actor-isolated and unreachable from the nonisolated `render` entry point.
private nonisolated final class Renderer {
    let event: Event
    let tables: [SeatingTable]
    let guests: [Guest]
    let shapes: [DecorShape]
    let rooms: [FloorPlanRoom]
    let includeGuestList: Bool

    /// Tables grouped with their guests for the list pages: tables ascending by
    /// name (natural order), guests ascending by last then first name.
    let listTables: [(name: String, guests: [String])]

    /// Active Core Graphics context for the page being drawn.
    private var cg: CGContext!

    init(event: Event, tables: [SeatingTable], guests: [Guest],
         shapes: [DecorShape], rooms: [FloorPlanRoom], includeGuestList: Bool) {
        self.event = event
        self.tables = tables
        self.guests = guests
        self.shapes = shapes
        self.rooms = rooms
        self.includeGuestList = includeGuestList
        self.listTables = Renderer.buildListTables(tables: tables, guests: guests)
    }

    // Page rects: landscape floor plan, portrait guest list.
    private let landscape = CGRect(x: 0, y: 0, width: a4Height, height: a4Width)
    private let portrait = CGRect(x: 0, y: 0, width: a4Width, height: a4Height)

    func makeData() -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "\(event.name) — Seating Chart",
            kCGPDFContextAuthor as String: "A Seat Awaits",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: landscape, format: format)

        return renderer.pdfData { pdf in
            pdf.beginPage(withBounds: landscape, pageInfo: [:])
            cg = pdf.cgContext
            drawFloorplanPage()

            if includeGuestList {
                drawGuestListPages(pdf)
            }
        }
    }

    // MARK: - Data shaping (port of getFloorplanExportData ordering)

    private static func buildListTables(tables: [SeatingTable],
                                        guests: [Guest]) -> [(name: String, guests: [String])] {
        // Bucket guests by table id.
        var byTable: [String: [Guest]] = [:]
        for guest in guests {
            guard let id = guest.tableId else { continue }
            byTable[id, default: []].append(guest)
        }

        let sortedTables = tables.sorted { natural($0.name, $1.name) == .orderedAscending }

        return sortedTables.map { table in
            let names = (byTable[table.id] ?? [])
                .sorted(by: byLastName)
                .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Guest" : $0.name }
            return (name: table.name, guests: names)
        }
    }

    /// Last name ascending, then first name — matching the web `byLastName`.
    private static func byLastName(_ a: Guest, _ b: Guest) -> Bool {
        let last = natural(a.lastNameKey, b.lastNameKey)
        if last != .orderedSame { return last == .orderedAscending }
        return natural(a.firstNameKey, b.firstNameKey) == .orderedAscending
    }

    /// Numeric-aware comparison so "Table 2" precedes "Table 10".
    private static func natural(_ a: String, _ b: String) -> ComparisonResult {
        a.localizedStandardCompare(b)
    }

    // ========================================================================
    // MARK: Page 1 — vector floor plan
    // ========================================================================

    private func drawFloorplanPage() {
        let pageW = landscape.width
        let pageH = landscape.height
        let margin: CGFloat = 30

        // Soft paper wash.
        fill(rect: CGRect(x: 0, y: 0, width: pageW, height: pageH), color: uiColor("#fdfcfe"))

        drawPosterFrame(pageW: pageW, pageH: pageH)

        let innerW = pageW - margin * 2

        // Eyebrow.
        draw("SEATING CHART", x: margin, y: 30, width: innerW,
             font: helvetica(8.5, bold: true), color: PDFBrand.purpleLight,
             align: .center, kern: 3.5)

        // Serif title.
        draw(event.name, x: margin, y: 42, width: innerW,
             font: times(27, .bold), color: PDFBrand.purpleDark, align: .center)

        var headerBottom: CGFloat = 74
        let subtitle = [formatEventDate(event.date), event.location ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: "   ·   ")
        if !subtitle.isEmpty {
            draw(subtitle, x: margin, y: headerBottom, width: innerW,
                 font: times(11, .italic), color: PDFBrand.subtle, align: .center)
            headerBottom += 16
        }

        drawOrnamentDivider(cx: pageW / 2, cy: headerBottom + 6, halfLen: 70)

        let drawTop = headerBottom + 20
        let drawBottom = pageH - 46
        let drawLeft = margin + 6
        let drawRight = pageW - margin - 6
        drawVectorFloorplan(areaX: drawLeft, areaY: drawTop,
                            areaW: drawRight - drawLeft, areaH: drawBottom - drawTop)

        drawFooter(pageW: pageW, pageH: pageH, margin: margin, bottomMargin: 24)
    }

    private func drawPosterFrame(pageW: CGFloat, pageH: CGFloat) {
        let inset: CGFloat = 16
        stroke(rect: CGRect(x: inset, y: inset, width: pageW - inset * 2, height: pageH - inset * 2),
               color: PDFBrand.purple, lineWidth: 1)
        let inner = inset + 4
        stroke(rect: CGRect(x: inner, y: inner, width: pageW - inner * 2, height: pageH - inner * 2),
               color: PDFBrand.purpleLight.withAlphaComponent(0.35), lineWidth: 0.5)
    }

    private func drawOrnamentDivider(cx: CGFloat, cy: CGFloat, halfLen: CGFloat) {
        let gap: CGFloat = 9
        cg.saveGState()
        cg.setStrokeColor(PDFBrand.purpleLight.withAlphaComponent(0.7).cgColor)
        cg.setLineWidth(0.75)
        cg.move(to: CGPoint(x: cx - halfLen, y: cy)); cg.addLine(to: CGPoint(x: cx - gap, y: cy))
        cg.move(to: CGPoint(x: cx + gap, y: cy)); cg.addLine(to: CGPoint(x: cx + halfLen, y: cy))
        cg.strokePath()
        cg.restoreGState()

        let d: CGFloat = 3
        cg.setFillColor(PDFBrand.purple.cgColor)
        cg.move(to: CGPoint(x: cx, y: cy - d))
        cg.addLine(to: CGPoint(x: cx + d, y: cy))
        cg.addLine(to: CGPoint(x: cx, y: cy + d))
        cg.addLine(to: CGPoint(x: cx - d, y: cy))
        cg.closePath()
        cg.fillPath()
    }

    // MARK: Vector floor plan

    private struct BBox { var minX, minY, maxX, maxY: CGFloat }

    private func itemBounds(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, rotationDeg: CGFloat) -> BBox {
        let cx = x + w / 2, cy = y + h / 2
        let rad = rotationDeg * .pi / 180
        let cos = Foundation.cos(rad), sin = Foundation.sin(rad)
        let corners = [(-w/2, -h/2), (w/2, -h/2), (w/2, h/2), (-w/2, h/2)]
        var b = BBox(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)
        for (px, py) in corners {
            let rx = cx + px * cos - py * sin
            let ry = cy + px * sin + py * cos
            b.minX = min(b.minX, rx); b.minY = min(b.minY, ry)
            b.maxX = max(b.maxX, rx); b.maxY = max(b.maxY, ry)
        }
        return b
    }

    private func computeBounds() -> BBox? {
        struct Item { var x, y, w, h, rot: CGFloat }
        var items: [Item] = []
        for t in tables {
            items.append(Item(x: CGFloat(t.positionX ?? 0), y: CGFloat(t.positionY ?? 0),
                              w: CGFloat(t.width), h: CGFloat(t.height), rot: CGFloat(t.rotationDegrees)))
        }
        for s in shapes {
            items.append(Item(x: CGFloat(s.positionX ?? 0), y: CGFloat(s.positionY ?? 0),
                              w: CGFloat(s.width), h: CGFloat(s.height), rot: CGFloat(s.rotationDegrees)))
        }
        for r in rooms {
            items.append(Item(x: CGFloat(r.positionX), y: CGFloat(r.positionY),
                              w: CGFloat(r.widthFt) * pixelsPerFoot, h: CGFloat(r.heightFt) * pixelsPerFoot, rot: 0))
        }
        guard !items.isEmpty else { return nil }

        let pad: CGFloat = 38
        var b = BBox(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)
        for it in items {
            let ib = itemBounds(x: it.x, y: it.y, w: it.w, h: it.h, rotationDeg: it.rot)
            b.minX = min(b.minX, ib.minX - pad); b.minY = min(b.minY, ib.minY - pad)
            b.maxX = max(b.maxX, ib.maxX + pad); b.maxY = max(b.maxY, ib.maxY + pad)
        }
        return b
    }

    private func drawVectorFloorplan(areaX: CGFloat, areaY: CGFloat, areaW: CGFloat, areaH: CGFloat) {
        guard let bounds = computeBounds() else {
            draw("No tables or shapes to display.", x: areaX, y: areaY + areaH / 2, width: areaW,
                 font: helvetica(11), color: PDFBrand.muted, align: .center)
            return
        }

        let contentW = bounds.maxX - bounds.minX
        let contentH = bounds.maxY - bounds.minY
        let scale = min(areaW / contentW, areaH / contentH, 3)
        let scaledW = contentW * scale, scaledH = contentH * scale
        let offsetX = areaX + (areaW - scaledW) / 2
        let offsetY = areaY + (areaH - scaledH) / 2

        let tx = { (wx: CGFloat) in offsetX + (wx - bounds.minX) * scale }
        let ty = { (wy: CGFloat) in offsetY + (wy - bounds.minY) * scale }
        let ts = { (s: CGFloat) in s * scale }

        // 1) Rooms — dashed outlines with labels.
        for room in rooms {
            let rx = tx(CGFloat(room.positionX))
            let ry = ty(CGFloat(room.positionY))
            let rw = ts(CGFloat(room.widthFt) * pixelsPerFoot)
            let rh = ts(CGFloat(room.heightFt) * pixelsPerFoot)

            cg.saveGState()
            cg.setLineDash(phase: 0, lengths: [4, 3])
            cg.setLineWidth(0.75)
            cg.setStrokeColor(uiColor("#94a3b8").cgColor)
            cg.stroke(CGRect(x: rx, y: ry, width: rw, height: rh))
            cg.restoreGState()

            if !room.name.isEmpty {
                let fontSize = max(5, min(8, ts(14)))
                draw(room.name, x: rx + 4, y: ry + 3, width: rw - 8,
                     font: helvetica(fontSize), color: uiColor("#94a3b8"))
            }
        }

        // 2) Shapes.
        for shape in shapes { drawShape(shape, tx: tx, ty: ty, ts: ts) }

        // 3) Tables.
        for table in tables { drawTable(table, tx: tx, ty: ty, ts: ts) }
    }

    private func drawShape(_ shape: DecorShape,
                           tx: (CGFloat) -> CGFloat, ty: (CGFloat) -> CGFloat, ts: (CGFloat) -> CGFloat) {
        let px = CGFloat(shape.positionX ?? 0), py = CGFloat(shape.positionY ?? 0)
        let cx = tx(px + CGFloat(shape.width) / 2)
        let cy = ty(py + CGFloat(shape.height) / 2)
        let w = ts(CGFloat(shape.width)), h = ts(CGFloat(shape.height))
        let isRound = shape.isRound

        cg.saveGState()
        if shape.rotationDegrees != 0 {
            cg.translateBy(x: cx, y: cy)
            cg.rotate(by: CGFloat(shape.rotationDegrees) * .pi / 180)
            cg.translateBy(x: -cx, y: -cy)
        }

        // Drop shadow.
        let shadow = PDFBrand.ink.withAlphaComponent(0.06)
        if isRound {
            fillEllipse(CGRect(x: cx + 1.5 - w/2, y: cy + 2 - h/2, width: w, height: h), color: shadow)
        } else {
            fillRoundedRect(CGRect(x: cx - w/2 + 1.5, y: cy - h/2 + 2, width: w, height: h), radius: 3, color: shadow)
        }

        // Body.
        let body = CGRect(x: cx - w/2, y: cy - h/2, width: w, height: h)
        if isRound {
            fillStrokeEllipse(body, fill: uiColor("#eef2f7"), stroke: uiColor("#cbd5e1"), lineWidth: 0.9)
        } else {
            fillStrokeRoundedRect(body, radius: 3, fill: uiColor("#eef2f7"), stroke: uiColor("#cbd5e1"), lineWidth: 0.9)
        }
        cg.restoreGState()

        // Label — unrotated, centered.
        if !shape.name.isEmpty {
            let fontSize = max(5, min(9, ts(12)))
            draw(shape.name, x: cx - w/2 + 4, y: cy - fontSize / 2, width: w - 8,
                 font: helvetica(fontSize, bold: true), color: uiColor("#475569"), align: .center)
        }
    }

    private func drawTable(_ table: SeatingTable,
                           tx: (CGFloat) -> CGFloat, ty: (CGFloat) -> CGFloat, ts: (CGFloat) -> CGFloat) {
        let px = CGFloat(table.positionX ?? 0), py = CGFloat(table.positionY ?? 0)
        let cx = tx(px + CGFloat(table.width) / 2)
        let cy = ty(py + CGFloat(table.height) / 2)
        let w = ts(CGFloat(table.width)), h = ts(CGFloat(table.height))
        let rotation = CGFloat(table.rotationDegrees)
        let shape = (table.shape ?? .circle)
        let isRound = shape == .circle || shape == .oval

        let seats = computeSeatPositions(shape: shape.rawValue, capacity: table.capacity ?? 0,
                                         tableWidth: CGFloat(table.width), tableHeight: CGFloat(table.height))
        let chairSize = max(6, min(15, ts(15)))

        cg.saveGState()
        cg.translateBy(x: cx, y: cy)
        if rotation != 0 { cg.rotate(by: rotation * .pi / 180) }

        // Chairs first.
        for seat in seats {
            drawChair(x: ts(seat.x), y: ts(seat.y), size: chairSize, angleDeg: seat.angle)
        }

        // Table body shadow.
        let shadow = PDFBrand.ink.withAlphaComponent(0.08)
        if isRound {
            fillEllipse(CGRect(x: 1.5 - w/2, y: 2.2 - h/2, width: w, height: h), color: shadow)
        } else {
            fillRoundedRect(CGRect(x: -w/2 + 1.5, y: -h/2 + 2.2, width: w, height: h), radius: 4, color: shadow)
        }

        // Table body.
        let body = CGRect(x: -w/2, y: -h/2, width: w, height: h)
        if isRound {
            fillStrokeEllipse(body, fill: .white, stroke: uiColor("#5b6472"), lineWidth: 1.1)
        } else {
            fillStrokeRoundedRect(body, radius: 4, fill: .white, stroke: uiColor("#5b6472"), lineWidth: 1.1)
        }

        // Label (rotates with the table, as in the web export).
        let labelSize = max(5, min(10, ts(13)))
        draw(table.name, x: -w/2 + 2, y: -labelSize / 2, width: w - 4,
             font: helvetica(labelSize, bold: true), color: uiColor("#1e293b"), align: .center)

        cg.restoreGState()
    }

    /// Top-down chair glyph centered at (x, y); the backrest faces `angleDeg`.
    private func drawChair(x: CGFloat, y: CGFloat, size: CGFloat, angleDeg: CGFloat) {
        let fill = UIColor.white
        let stroke = uiColor("#aab0bd")
        let lw = max(0.4, size * 0.07)

        cg.saveGState()
        cg.translateBy(x: x, y: y)
        cg.rotate(by: angleDeg * .pi / 180)

        // Backrest (outer edge).
        fillStrokeRoundedRect(CGRect(x: size * 0.28, y: -size * 0.55, width: size * 0.24, height: size * 1.1),
                              radius: size * 0.12, fill: fill, stroke: stroke, lineWidth: lw)
        // Seat cushion.
        fillStrokeRoundedRect(CGRect(x: -size * 0.55, y: -size * 0.48, width: size * 0.92, height: size * 0.96),
                              radius: size * 0.16, fill: fill, stroke: stroke, lineWidth: lw)
        cg.restoreGState()
    }

    // MARK: Seat positions (port of useSeatPositions.ts)

    private struct SeatPos { var x, y, angle: CGFloat }

    private func computeSeatPositions(shape: String, capacity: Int,
                                      tableWidth: CGFloat, tableHeight: CGFloat) -> [SeatPos] {
        guard capacity > 0 else { return [] }
        let seatSize: CGFloat = 16
        let sparseOffset: CGFloat = capacity <= 2 ? 6 : 0
        let seatOffset = seatSize / 2 + 4 + sparseOffset

        if shape == "circle" || shape == "oval" {
            let aspect = max(tableWidth, tableHeight) / min(tableWidth, tableHeight)
            let flatBoost: CGFloat = aspect > 2 ? 8 : 0
            return circularSeats(cap: capacity, tw: tableWidth, th: tableHeight, off: seatOffset + flatBoost)
        }
        if shape == "rectangle" {
            return tableHeight > tableWidth
                ? verticalSideSeats(cap: capacity, tw: tableWidth, off: seatOffset)
                : horizontalSideSeats(cap: capacity, th: tableHeight, off: seatOffset)
        }
        // square
        return horizontalSideSeats(cap: capacity, th: tableHeight, off: seatOffset)
    }

    private func circularSeats(cap: Int, tw: CGFloat, th: CGFloat, off: CGFloat) -> [SeatPos] {
        let rx = tw / 2 + off, ry = th / 2 + off
        return (0..<cap).map { i in
            let a = (CGFloat(i) * 2 * .pi / CGFloat(cap)) - .pi / 2
            let x = Foundation.cos(a) * rx
            let y = Foundation.sin(a) * ry
            return SeatPos(x: x, y: y, angle: atan2(y, x) * 180 / .pi)
        }
    }

    private func horizontalSideSeats(cap: Int, th: CGFloat, off: CGFloat) -> [SeatPos] {
        let halfH = th / 2 + off, gap: CGFloat = 28
        let perSide = Int(ceil(Double(cap) / 2))
        var seats: [SeatPos] = []
        var placed = 0

        let topN = min(perSide, cap - placed)
        let topStart = -CGFloat(topN - 1) * gap / 2
        for i in 0..<max(0, topN) { seats.append(SeatPos(x: topStart + CGFloat(i) * gap, y: -halfH, angle: -90)); placed += 1 }

        let botN = min(perSide, cap - placed)
        let botStart = -CGFloat(botN - 1) * gap / 2
        for i in 0..<max(0, botN) { seats.append(SeatPos(x: botStart + CGFloat(i) * gap, y: halfH, angle: 90)); placed += 1 }

        return seats
    }

    private func verticalSideSeats(cap: Int, tw: CGFloat, off: CGFloat) -> [SeatPos] {
        let halfW = tw / 2 + off, gap: CGFloat = 28
        let perSide = Int(ceil(Double(cap) / 2))
        var seats: [SeatPos] = []
        var placed = 0

        let leftN = min(perSide, cap - placed)
        let leftStart = -CGFloat(leftN - 1) * gap / 2
        for i in 0..<max(0, leftN) { seats.append(SeatPos(x: -halfW, y: leftStart + CGFloat(i) * gap, angle: 180)); placed += 1 }

        let rightN = min(perSide, cap - placed)
        let rightStart = -CGFloat(rightN - 1) * gap / 2
        for i in 0..<max(0, rightN) { seats.append(SeatPos(x: halfW, y: rightStart + CGFloat(i) * gap, angle: 0)); placed += 1 }

        return seats
    }

    // ========================================================================
    // MARK: Pages 2+ — guest list (port of buildGuestListPages)
    // ========================================================================

    private func drawGuestListPages(_ pdf: UIGraphicsPDFRendererContext) {
        let marginX: CGFloat = 54
        let marginTop: CGFloat = 54
        let marginBottom: CGFloat = 52
        let cols = 3
        let gutter: CGFloat = 24

        let headStep: CGFloat = 18
        let nameStep: CGFloat = 13
        let blockGap: CGFloat = 18

        let pageW = portrait.width
        let pageH = portrait.height
        let contentBottom = pageH - marginBottom
        let colW = (pageW - marginX * 2 - gutter * CGFloat(cols - 1)) / CGFloat(cols)
        let colX = { (c: Int) in marginX + CGFloat(c) * (colW + gutter) }

        var firstPage = true

        func drawHeader() -> CGFloat {
            let cw = pageW - marginX * 2
            drawPosterFrame(pageW: pageW, pageH: pageH)

            draw(event.name.uppercased(), x: marginX, y: marginTop, width: cw,
                 font: times(26, .bold), color: PDFBrand.purpleDark, align: .center, kern: 2)

            var yy = marginTop + 32
            let subtitle = [formatEventDate(event.date), event.location ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: "   ·   ")
            if !subtitle.isEmpty {
                draw(subtitle, x: marginX, y: yy, width: cw,
                     font: times(11.5, .italic), color: PDFBrand.subtle, align: .center)
                yy += 17
            }
            drawOrnamentDivider(cx: pageW / 2, cy: yy + 7, halfLen: 64)
            return yy + 26
        }

        func startPage() -> CGFloat {
            if !firstPage { drawFooter(pageW: pageW, pageH: pageH, margin: marginX, bottomMargin: marginBottom) }
            firstPage = false
            pdf.beginPage(withBounds: portrait, pageInfo: [:])
            cg = pdf.cgContext
            return drawHeader()
        }

        var gridTop = startPage()
        var col = 0
        var y = gridTop

        func advanceColumn() {
            col += 1
            if col >= cols { gridTop = startPage(); col = 0 }
            y = gridTop
        }

        func drawHeading(_ title: String, continued: Bool) {
            let text = "\(title.uppercased())\(continued ? "  (CONT.)" : "")"
            let font = times(12.5, .bold)
            let headH = measureHeight(text, width: colW, font: font, kern: 1.2, align: .center)
            draw(text, x: colX(col), y: y, width: colW, font: font,
                 color: PDFBrand.purpleDark, align: .center, kern: 1.2, singleLine: false)
            y += max(headStep, headH + 5)
        }

        func drawName(_ text: String, italic: Bool = false) {
            let font = italic ? times(10, .italic) : times(10, .roman)
            let color = italic ? PDFBrand.muted : uiColor("#3b3640")
            draw(text, x: colX(col), y: y, width: colW, font: font, color: color, align: .center)
            y += nameStep
        }

        func drawBlock(_ title: String, _ names: [String]) {
            if y + headStep + nameStep * 2 > contentBottom { advanceColumn() }
            drawHeading(title, continued: false)

            if names.isEmpty {
                drawName("No guests assigned", italic: true)
            } else {
                for name in names {
                    if y + nameStep > contentBottom {
                        advanceColumn()
                        drawHeading(title, continued: true)
                    }
                    drawName(name)
                }
            }
            y += blockGap
        }

        if listTables.isEmpty {
            draw("No tables have been added yet.", x: marginX, y: gridTop + 20, width: pageW - marginX * 2,
                 font: times(11, .italic), color: PDFBrand.muted, align: .center, singleLine: false)
        } else {
            for table in listTables { drawBlock(table.name, table.guests) }
        }

        drawFooter(pageW: pageW, pageH: pageH, margin: marginX, bottomMargin: marginBottom)
    }

    // ========================================================================
    // MARK: Footer
    // ========================================================================

    private func drawFooter(pageW: CGFloat, pageH: CGFloat, margin: CGFloat, bottomMargin: CGFloat) {
        let textY = pageH - bottomMargin - 10
        let contentW = pageW - margin * 2
        let text = "A Seat Awaits  ·  \(site)"
        let font = helvetica(7)
        let textW = measureWidth(text, font: font)
        let startX = margin + (contentW - textW) / 2
        draw(text, x: startX, y: textY, width: textW + 2, font: font, color: PDFBrand.muted)
    }

    // ========================================================================
    // MARK: Drawing primitives
    // ========================================================================

    private func fill(rect: CGRect, color: UIColor) {
        cg.setFillColor(color.cgColor); cg.fill(rect)
    }

    private func stroke(rect: CGRect, color: UIColor, lineWidth: CGFloat) {
        cg.setStrokeColor(color.cgColor); cg.setLineWidth(lineWidth); cg.stroke(rect)
    }

    private func fillEllipse(_ rect: CGRect, color: UIColor) {
        cg.setFillColor(color.cgColor); cg.fillEllipse(in: rect)
    }

    private func fillRoundedRect(_ rect: CGRect, radius: CGFloat, color: UIColor) {
        cg.addPath(UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath)
        cg.setFillColor(color.cgColor); cg.fillPath()
    }

    private func fillStrokeEllipse(_ rect: CGRect, fill: UIColor, stroke: UIColor, lineWidth: CGFloat) {
        cg.addEllipse(in: rect)
        cg.setFillColor(fill.cgColor); cg.setStrokeColor(stroke.cgColor); cg.setLineWidth(lineWidth)
        cg.drawPath(using: .fillStroke)
    }

    private func fillStrokeRoundedRect(_ rect: CGRect, radius: CGFloat, fill: UIColor, stroke: UIColor, lineWidth: CGFloat) {
        cg.addPath(UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath)
        cg.setFillColor(fill.cgColor); cg.setStrokeColor(stroke.cgColor); cg.setLineWidth(lineWidth)
        cg.drawPath(using: .fillStroke)
    }

    // MARK: Text

    private func draw(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat,
                      font: UIFont, color: UIColor, align: NSTextAlignment = .left,
                      kern: CGFloat = 0, singleLine: Bool = true) {
        guard !text.isEmpty else { return }
        let para = NSMutableParagraphStyle()
        para.alignment = align
        if singleLine { para.lineBreakMode = .byTruncatingTail }
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        if kern != 0 { attrs[.kern] = kern }
        let string = NSAttributedString(string: text, attributes: attrs)
        let height = singleLine ? ceil(font.lineHeight) + 2 : 100_000
        string.draw(with: CGRect(x: x, y: y, width: width, height: height),
                    options: [.usesLineFragmentOrigin], context: nil)
    }

    private func measureHeight(_ text: String, width: CGFloat, font: UIFont, kern: CGFloat, align: NSTextAlignment) -> CGFloat {
        let para = NSMutableParagraphStyle(); para.alignment = align
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]
        if kern != 0 { attrs[.kern] = kern }
        let string = NSAttributedString(string: text, attributes: attrs)
        let rect = string.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return ceil(rect.height)
    }

    private func measureWidth(_ text: String, font: UIFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    // MARK: Fonts (map pdfkit's Helvetica/Times faces to iOS)

    private func helvetica(_ size: CGFloat, bold: Bool = false) -> UIFont {
        UIFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size)
            ?? (bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
    }

    private enum TimesStyle { case roman, bold, italic }

    private func times(_ size: CGFloat, _ style: TimesStyle) -> UIFont {
        let candidates: [String]
        switch style {
        case .roman: candidates = ["TimesNewRomanPSMT", "Times-Roman"]
        case .bold: candidates = ["TimesNewRomanPS-BoldMT", "Times-Bold"]
        case .italic: candidates = ["TimesNewRomanPS-ItalicMT", "Times-Italic"]
        }
        for name in candidates {
            if let font = UIFont(name: name, size: size) { return font }
        }
        switch style {
        case .roman: return .systemFont(ofSize: size)
        case .bold: return .boldSystemFont(ofSize: size)
        case .italic: return UIFont.italicSystemFont(ofSize: size)
        }
    }

    // MARK: Date

    private func formatEventDate(_ date: String?) -> String {
        guard let date, !date.isEmpty else { return "" }
        let parsed = Renderer.parseDate(date)
        guard let parsed else { return "" }
        return Renderer.longFormatter.string(from: parsed)
    }

    private static func parseDate(_ date: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: date) { return d }
        let iso2 = ISO8601DateFormatter()
        if let d = iso2.date(from: date) { return d }
        return dateOnly.date(from: String(date.prefix(10)))
    }

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let longFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f
    }()
}

// MARK: - Hex color

private func uiColor(_ hex: String) -> UIColor {
    var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
    var value: UInt64 = 0
    Scanner(string: s).scanHexInt64(&value)
    let r = CGFloat((value >> 16) & 0xff) / 255
    let g = CGFloat((value >> 8) & 0xff) / 255
    let b = CGFloat(value & 0xff) / 255
    return UIColor(red: r, green: g, blue: b, alpha: 1)
}
