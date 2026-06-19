//
//  FloorPlanView.swift
//  A Seat Awaits
//
//  The "Tables" workspace: a pannable, dot-gridded floor plan where tables can be
//  dragged to position. Round tables carry a capacity progress ring; open seats
//  glow. Tap a table to manage who's seated. An optional `assigning` mode lets a
//  guest be dropped onto any table with room — open seats pulse green, full tables
//  dim out, and a conflict-helper toast confirms the move.
//

import SwiftUI

struct FloorPlanView: View {
    @Bindable var store: SeatingStore

    /// When non-nil, the view is in "assign this guest to a seat" mode.
    let assigning: Guest?
    /// Called when assign-mode should end (after a successful assign or cancel).
    var onFinishAssigning: (() -> Void)? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var scheme

    /// Live drag offsets keyed by table id (applied on top of stored position).
    @State private var dragOffsets: [String: CGSize] = [:]
    @State private var selectedTable: SeatingTable?
    @State private var showingAddTable = false
    @State private var zoom: CGFloat = 1
    @State private var toast: String?
    @State private var pulse = false

    private let canvasSize = CGSize(width: 1000, height: 1400)

    /// EventDetailView's existing call site stays valid via these defaults.
    init(store: SeatingStore,
         assigning: Guest? = nil,
         onFinishAssigning: (() -> Void)? = nil) {
        self.store = store
        self.assigning = assigning
        self.onFinishAssigning = onFinishAssigning
    }

    private var isAssigning: Bool { assigning != nil }

    /// Live collaborator name if any, else the planner's first name.
    private var liveName: String {
        let full = appState.currentUser?.displayName ?? "Planner"
        return full.split(separator: " ").first.map(String.init) ?? full
    }

    var body: some View {
        ZStack {
            canvasBackground

            if store.tables.isEmpty {
                emptyState
            } else {
                floorPlan
            }

            overlays
        }
        .background(canvasBackground)
        .sheet(item: $selectedTable) { table in
            TableDetailSheet(store: store, table: table)
        }
        .sheet(isPresented: $showingAddTable) { AddTableView(store: store) }
        .onAppear { pulse = true }
    }

    private var canvasBackground: Color {
        scheme == .dark ? Brand.canvasDark : Color.hex("#F1F5EF")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No tables yet", systemImage: "square.on.square.dashed")
        } description: {
            Text("Add tables with the button below, then drag them into your floor plan.")
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Floor plan canvas

    private var floorPlan: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                DotGrid(dotColor: scheme == .dark ? Brand.hairlineDark : Color.hex("#D6D3CC"))
                    .frame(width: canvasSize.width, height: canvasSize.height)

                ForEach(store.tables) { table in
                    tableNode(table)
                        .position(position(for: table))
                        .gesture(isAssigning ? nil : dragGesture(for: table))
                        .onTapGesture { handleTap(table) }
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .scaleEffect(zoom, anchor: .topLeading)
            .frame(width: canvasSize.width * zoom,
                   height: canvasSize.height * zoom,
                   alignment: .topLeading)
        }
    }

    private func tableNode(_ table: SeatingTable) -> some View {
        let occupancy = store.occupancy(of: table)
        let capacity = table.capacity ?? 0
        let open = SeatingLogic.remainingSeats(table, guests: store.guests) ?? capacity
        return TableNodeView(
            table: table,
            occupancy: occupancy,
            isOverCapacity: SeatingLogic.isOverCapacity(table, guests: store.guests),
            isSelected: selectedTable?.id == table.id,
            assigning: isAssigning,
            openSeats: open,
            pulse: pulse
        )
    }

    // MARK: - Overlays (badges, banner, FAB, toast)

    @ViewBuilder
    private var overlays: some View {
        if isAssigning, let guest = assigning {
            VStack(spacing: 0) {
                assignBanner(guest)
                Spacer()
            }
            .transition(.move(edge: .top))
        } else if !store.tables.isEmpty {
            VStack {
                HStack {
                    Spacer()
                    LiveBadge(name: liveName)
                }
                Spacer()
            }
            .padding(16)
        }

        // Floating "Add Table" + zoom controls — hidden in assign mode.
        if !isAssigning {
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    zoomControl
                    Spacer()
                    FloatingButton(icon: "plus", title: "Add Table") {
                        showingAddTable = true
                    }
                }
            }
            .padding(18)
        }

        // Conflict-helper toast pinned bottom (assign mode).
        if isAssigning, let toast {
            VStack {
                Spacer()
                conflictToast(toast)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func assignBanner(_ guest: Guest) -> some View {
        HStack(spacing: 12) {
            GlassAvatar(name: guest.name)
            VStack(alignment: .leading, spacing: 2) {
                Text("SEATING")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(Brand.lilac)
                Text("\(guest.name) · tap an open seat")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Cancel") { onFinishAssigning?() }
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Brand.plum)
    }

    private var zoomControl: some View {
        VStack(spacing: 0) {
            zoomButton(icon: "plus") { zoom = min(2, zoom + 0.2) }
            Divider().frame(width: 40)
            zoomButton(icon: "minus") { zoom = max(0.5, zoom - 0.2) }
        }
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Brand.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.12), radius: 8, y: 2)
    }

    private func zoomButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(Brand.textPrimary)
                .frame(width: 40, height: 40)
        }
    }

    private func conflictToast(_ text: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.hex("#22C55E"))
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(Brand.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
    }

    // MARK: - Interaction

    private func handleTap(_ table: SeatingTable) {
        guard let guest = assigning else {
            selectedTable = table
            return
        }
        // Assign mode: only tables with room accept the guest.
        let open = SeatingLogic.remainingSeats(table, guests: store.guests)
        let hasRoom = open == nil || (open ?? 0) > 0
        guard hasRoom else { return }
        withAnimation { toast = "No conflicts. \(table.name) has room." }
        Task {
            await store.assign(guest, toTable: table.id)
            onFinishAssigning?()
        }
    }

    private func position(for table: SeatingTable) -> CGPoint {
        let baseX = table.positionX ?? 80
        let baseY = table.positionY ?? 80
        let drag = dragOffsets[table.id] ?? .zero
        // Stored position is the table's top-left; offset by half size for center.
        let x = (baseX + table.width / 2 + drag.width) * zoom
        let y = (baseY + table.height / 2 + drag.height) * zoom
        return CGPoint(x: x, y: y)
    }

    private func dragGesture(for table: SeatingTable) -> some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffsets[table.id] = CGSize(width: value.translation.width / zoom,
                                               height: value.translation.height / zoom)
            }
            .onEnded { value in
                let newX = max(0, (table.positionX ?? 80) + value.translation.width / zoom)
                let newY = max(0, (table.positionY ?? 80) + value.translation.height / zoom)
                dragOffsets[table.id] = nil
                Task { await store.updatePosition(of: table, x: newX, y: newY) }
            }
    }
}

/// A single table rendered on the floor plan: title, occupancy, capacity ring for
/// round tables, and seat dots. In assign mode, open seats glow and full tables dim.
struct TableNodeView: View {
    let table: SeatingTable
    let occupancy: Int
    let isOverCapacity: Bool
    var isSelected: Bool = false
    var assigning: Bool = false
    var openSeats: Int = 0
    var pulse: Bool = false

    @Environment(\.colorScheme) private var scheme

    private var capacity: Int { table.capacity ?? 0 }
    private var isRound: Bool { (table.shape ?? .circle) == .circle || (table.shape ?? .circle) == .oval }
    private var isFull: Bool { capacity > 0 && occupancy >= capacity }
    private var progress: Double { capacity > 0 ? Double(occupancy) / Double(capacity) : 0 }

    var body: some View {
        ZStack {
            seatDots
            if isRound { capacityRing }
            tableBody
        }
        .frame(width: table.width + 44, height: table.height + 44)
        .opacity(assigning && isFull ? 0.45 : 1)
    }

    // MARK: Body

    private var tableBody: some View {
        Group {
            switch table.shape ?? .circle {
            case .circle, .oval:
                Ellipse().fill(Brand.card)
            case .square, .rectangle:
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.card)
            }
        }
        .frame(width: table.width, height: table.height)
        .overlay { borderOverlay }
        .overlay { label }
        .shadow(color: bodyShadow, radius: 10, y: 4)
    }

    @ViewBuilder
    private var borderOverlay: some View {
        let highlight = highlightColor
        let radius: CGFloat = 14
        Group {
            if isRound {
                // Ring is drawn separately; only the selection / assign highlight here.
                if let highlight {
                    Ellipse().strokeBorder(highlight, lineWidth: 3)
                } else if !assigning {
                    Ellipse().strokeBorder(Brand.slate200, lineWidth: 1.5)
                }
            } else {
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                if let highlight {
                    shape.strokeBorder(highlight, lineWidth: 3)
                } else {
                    shape.strokeBorder(Brand.slate200, lineWidth: 1.5)
                }
            }
        }
    }

    /// Selection/assign highlight color, or nil when none.
    private var highlightColor: Color? {
        if assigning {
            return isFull ? nil : Brand.success
        }
        return isSelected ? Brand.accent : nil
    }

    private var bodyShadow: Color {
        if assigning && !isFull { return Brand.success.opacity(0.35) }
        if isSelected { return Brand.plum.opacity(0.35) }
        return .black.opacity(scheme == .dark ? 0 : 0.12)
    }

    private var label: some View {
        VStack(spacing: 2) {
            Text(table.name)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isSelected ? Brand.accent : Brand.textPrimary)
                .lineLimit(1)

            if assigning {
                Text(isFull ? "Full" : "\(openSeats) open")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isFull ? Brand.slate400 : Brand.success)
            } else if capacity > 0 {
                Text("\(occupancy) / \(capacity)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(occupancyColor)
            }
        }
        .padding(.horizontal, 6)
    }

    private var occupancyColor: Color {
        if isOverCapacity { return Brand.danger }
        if isFull { return Brand.success }
        if occupancy > 0 { return Brand.warningText }
        return Brand.textSecondary
    }

    // MARK: Capacity ring (round tables only)

    private var capacityRing: some View {
        let ringColor = isFull ? Brand.success : Brand.accent
        let size = max(table.width, table.height) + 16
        return ZStack {
            Circle().stroke(Brand.ringTrack, lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(ringColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }

    // MARK: Seat dots

    @ViewBuilder
    private var seatDots: some View {
        let count = max(capacity, 0)
        if count > 0 {
            ZStack {
                ForEach(0..<count, id: \.self) { index in
                    seatDot(at: index, count: count)
                }
            }
        }
    }

    @ViewBuilder
    private func seatDot(at index: Int, count: Int) -> some View {
        let angle = (Double(index) / Double(max(count, 1))) * 2 * .pi - .pi / 2
        let rx = table.width / 2 + (assigning ? 18 : 12)
        let ry = table.height / 2 + (assigning ? 18 : 12)
        let filled = index < occupancy
        let dx = CGFloat(cos(angle)) * rx
        let dy = CGFloat(sin(angle)) * ry

        if assigning {
            if filled {
                // Filled seat: solid plum dot.
                Circle().fill(Brand.plum)
                    .frame(width: 16, height: 16)
                    .offset(x: dx, y: dy)
            } else {
                // Open seat: large glowing green circle with a "+".
                ZStack {
                    Circle().fill(Brand.success.opacity(0.22))
                        .frame(width: 32, height: 32)
                        .scaleEffect(pulse ? 1.15 : 0.9)
                        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
                    Circle().fill(Brand.success)
                        .frame(width: 22, height: 22)
                        .overlay(Image(systemName: "plus")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(.white))
                }
                .offset(x: dx, y: dy)
            }
        } else {
            Circle()
                .fill(filled ? Brand.plum : Brand.success.opacity(0.85))
                .frame(width: 9, height: 9)
                .shadow(color: filled ? .clear : Brand.success.opacity(0.9),
                        radius: filled ? 0 : 3)
                .offset(x: dx, y: dy)
        }
    }
}

/// Subtle dotted background grid for the floor-plan canvas (~20pt spacing).
struct DotGrid: View {
    var spacing: CGFloat = 20
    var dotColor: Color = .gray.opacity(0.18)

    var body: some View {
        Canvas { context, size in
            let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 2.2, height: 2.2))
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    context.fill(dot.offsetBy(dx: x, dy: y), with: .color(dotColor))
                    x += spacing
                }
                y += spacing
            }
        }
    }
}
