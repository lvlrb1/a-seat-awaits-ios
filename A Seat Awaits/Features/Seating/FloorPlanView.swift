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

    /// The item currently being dragged (table, shape, or room) with its live,
    /// snap-resolved position and any alignment guides / collision state.
    @State private var activeDrag: ActiveDrag?
    @State private var selectedTable: SeatingTable?
    @State private var editingTable: SeatingTable?
    @State private var pendingDelete: SeatingTable?
    @State private var showingAddTable = false
    @State private var toast: String?
    @State private var pulse = false

    // Decorative shapes + rooms (Tier 3).
    @State private var editingShape: DecorShape?
    @State private var pendingDeleteShape: DecorShape?
    @State private var showingAddShape = false
    @State private var editingRoom: FloorPlanRoom?
    @State private var pendingDeleteRoom: FloorPlanRoom?
    @State private var showingAddRoom = false
    @State private var showingTemplates = false
    /// Opt-in snap to the 2ft grid; gentle alignment guides are always on.
    @State private var snapToGrid = false
    /// Ensures the layout is auto-framed only once, on first canvas appearance.
    @State private var didInitialFit = false

    // Tables can be viewed as a draggable canvas or a sortable list.
    @State private var mode: TablesMode = .canvas
    @State private var tableSort: TableSort = .nameAZ
    @State private var expandedTables: Set<String> = []

    // Zoom: `zoom` is the committed level; `gestureZoom` is the live pinch factor.
    @State private var zoom: CGFloat = 1
    @State private var gestureZoom: CGFloat = 1
    @State private var viewportSize: CGSize = .zero
    /// Drives the canvas scroll offset so we can frame the tables precisely —
    /// `scrollTo(id:)` reads the unscaled child position and lands wrong once the
    /// canvas is scaled (and enlarged by a room).
    @State private var scrollPosition = ScrollPosition()

    enum TablesMode { case canvas, list }

    /// Which kind of canvas item a drag is moving — they persist differently.
    enum ItemKind { case table, shape, room }

    /// Live state for the one item being dragged: its snapped top-left, the
    /// alignment guides to draw, and whether it currently overlaps something.
    private struct ActiveDrag {
        let id: String
        let kind: ItemKind
        var topLeft: CGPoint
        var size: CGSize
        var guides: [FloorPlanGeometry.Guide]
        var colliding: Bool
    }

    private let canvasSize = CGSize(width: 1000, height: 1400)
    private let minZoom: CGFloat = 0.4
    private let maxZoom: CGFloat = 2.5

    /// EventDetailView's existing call site stays valid via these defaults.
    init(store: SeatingStore,
         assigning: Guest? = nil,
         onFinishAssigning: (() -> Void)? = nil) {
        self.store = store
        self.assigning = assigning
        self.onFinishAssigning = onFinishAssigning
    }

    private var isAssigning: Bool { assigning != nil }

    /// Whether the signed-in user may rearrange / edit the floor plan. Viewers
    /// get a read-only canvas (no drag, no add menu, no edit/delete actions).
    private var canEdit: Bool { store.canEdit }

    /// Live collaborator name if any, else the planner's first name.
    private var liveName: String {
        let full = appState.currentUser?.displayName ?? "Planner"
        return full.split(separator: " ").first.map(String.init) ?? full
    }

    /// The mode bar (canvas/list toggle + live badge or sort) only makes sense
    /// once there are tables and we're not steering a guest to a seat.
    private var showsModeBar: Bool { !isAssigning && !store.tables.isEmpty }

    /// List view is forced back to the canvas while assigning a guest.
    private var effectiveMode: TablesMode { isAssigning ? .canvas : mode }

    var body: some View {
        ZStack {
            canvasBackground

            VStack(spacing: 0) {
                if showsModeBar { modeBar }
                contentArea
            }

            overlays
        }
        .background(canvasBackground)
        .sheet(item: $selectedTable) { table in
            TableDetailSheet(store: store, table: table)
        }
        .sheet(item: $editingTable) { table in
            AddTableView(store: store, editing: table)
        }
        .sheet(isPresented: $showingAddTable) { AddTableView(store: store) }
        .sheet(item: $editingShape) { shape in
            AddShapeView(store: store, editing: shape)
        }
        .sheet(isPresented: $showingAddShape) { AddShapeView(store: store) }
        .sheet(item: $editingRoom) { room in
            AddRoomView(store: store, editing: room)
        }
        .sheet(isPresented: $showingAddRoom) { AddRoomView(store: store) }
        .sheet(isPresented: $showingTemplates) { TemplatesView(store: store) }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "table")?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete table", role: .destructive) {
                if let table = pendingDelete { Task { await store.deleteTable(table) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Guests at this table will become unassigned.")
        }
        .confirmationDialog("Delete \(pendingDeleteShape?.name ?? "shape")?",
                            isPresented: Binding(get: { pendingDeleteShape != nil },
                                                 set: { if !$0 { pendingDeleteShape = nil } }),
                            titleVisibility: .visible) {
            Button("Delete shape", role: .destructive) {
                if let shape = pendingDeleteShape { Task { await store.deleteShape(shape) } }
                pendingDeleteShape = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteShape = nil }
        }
        .confirmationDialog("Delete \(pendingDeleteRoom?.name ?? "room")?",
                            isPresented: Binding(get: { pendingDeleteRoom != nil },
                                                 set: { if !$0 { pendingDeleteRoom = nil } }),
                            titleVisibility: .visible) {
            Button("Delete room", role: .destructive) {
                if let room = pendingDeleteRoom { Task { await store.deleteRoom(room) } }
                pendingDeleteRoom = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteRoom = nil }
        } message: {
            Text("Tables stay put — only the room boundary is removed.")
        }
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

    // MARK: - Content router (canvas vs list)

    /// Anything that should make the canvas render rather than the empty state.
    private var hasCanvasContent: Bool {
        !store.tables.isEmpty || !store.shapes.isEmpty || !store.rooms.isEmpty
    }

    @ViewBuilder
    private var contentArea: some View {
        if !hasCanvasContent {
            emptyState
        } else if effectiveMode == .list {
            tableList
        } else {
            floorPlanContainer
        }
    }

    // MARK: - Mode bar

    private var modeBar: some View {
        HStack(spacing: 12) {
            viewModeToggle
            Spacer(minLength: 8)
            if !canEdit {
                ViewOnlyBadge()
            } else if mode == .list {
                sortMenu
            } else {
                LiveBadge(name: liveName)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Brand.card)
        .overlay(Brand.hairline.frame(height: 1), alignment: .bottom)
    }

    private var viewModeToggle: some View {
        HStack(spacing: 3) {
            modeToggleButton(.canvas, icon: "square.grid.2x2", label: "Canvas")
            modeToggleButton(.list, icon: "list.bullet", label: "List")
        }
        .padding(3)
        .background(Brand.control, in: Capsule())
    }

    private func modeToggleButton(_ value: TablesMode, icon: String, label: String) -> some View {
        let selected = mode == value
        return Button {
            withAnimation(.snappy(duration: 0.2)) { mode = value }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(selected ? Brand.accent : Brand.textSecondary)
                .frame(width: 46, height: 30)
                .background {
                    if selected {
                        Capsule()
                            .fill(Brand.card)
                            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.12), radius: 3, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) view")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort tables", selection: $tableSort) {
                ForEach(TableSort.allCases) { sort in
                    Label(sort.label, systemImage: sort.systemImage).tag(sort)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 13, weight: .bold))
                Text(tableSort.label)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Brand.accent)
        }
    }

    // MARK: - Floor plan canvas

    private var floorPlanContainer: some View {
        GeometryReader { geo in
            floorPlan
                .onAppear {
                    viewportSize = geo.size
                    maybeInitialFit()
                }
                .onChange(of: geo.size) { _, size in
                    viewportSize = size
                    maybeInitialFit()
                }
                // Tables may arrive after the canvas first appears (a room can
                // render the canvas with no tables yet); fit once they do.
                .onChange(of: store.tables.count) { _, _ in
                    maybeInitialFit()
                }
        }
    }

    /// On the first canvas appearance, frame the whole layout so tables that
    /// were authored at far-flung coordinates are visible right away.
    private func maybeInitialFit() {
        guard !didInitialFit, viewportSize.width > 0, !store.tables.isEmpty else { return }
        didInitialFit = true
        fitToLayout(animated: false)
    }

    private var floorPlan: some View {
        let content = contentRect
        return ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                DotGrid(dotColor: scheme == .dark ? Brand.hairlineDark : Color.hex("#D6D3CC"))
                    .frame(width: content.width, height: content.height)

                // Back-to-front: rooms, then decorative shapes, then tables.
                ForEach(store.rooms) { room in roomLayer(room) }
                ForEach(store.shapes) { shape in shapeLayer(shape) }
                ForEach(store.tables) { table in
                    tableNode(table)
                        .position(tableCenter(table))
                        .id(table.id)
                        .gesture((isAssigning || !canEdit) ? nil : dragGesture(forTable: table))
                        .onTapGesture { handleTap(table) }
                        .contextMenu { if !isAssigning { tableContextMenu(table) } }
                }

                // Alignment guides on top of everything, in canvas space.
                guideOverlay
            }
            .frame(width: content.width, height: content.height, alignment: .topLeading)
            .scaleEffect(effectiveZoom, anchor: .topLeading)
            .frame(width: content.width * effectiveZoom,
                   height: content.height * effectiveZoom,
                   alignment: .topLeading)
            .gesture(magnifyGesture)
        }
        .scrollPosition($scrollPosition)
    }

    /// The scrollable canvas rectangle in absolute coordinates. It grows to
    /// enclose every item — including web-authored tables at negative or
    /// far-flung coordinates — with a generous margin so there's always room to
    /// pan and reposition. Items are rendered at `coordinate - contentRect.origin`
    /// so the box always starts at the ScrollView's (0,0).
    private var contentRect: CGRect {
        let pad: CGFloat = 240
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        func include(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
            minX = min(minX, CGFloat(x)); minY = min(minY, CGFloat(y))
            maxX = max(maxX, CGFloat(x + w)); maxY = max(maxY, CGFloat(y + h))
        }
        for t in store.tables { include(t.positionX ?? 80, t.positionY ?? 80, t.width, t.height) }
        for s in store.shapes { include(s.positionX ?? 120, s.positionY ?? 120, s.width, s.height) }
        for r in store.rooms { include(r.positionX, r.positionY, r.widthPoints, r.heightPoints) }

        guard minX <= maxX else { return CGRect(origin: .zero, size: canvasSize) }
        let originX = minX - pad, originY = minY - pad
        let width = max(canvasSize.width, (maxX - minX) + pad * 2)
        let height = max(canvasSize.height, (maxY - minY) + pad * 2)
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    // MARK: - Room + shape layers

    @ViewBuilder
    private func roomLayer(_ room: FloorPlanRoom) -> some View {
        let size = CGSize(width: room.widthPoints, height: room.heightPoints)
        // The room fill is non-interactive (canvas pans over it); only the name
        // chip is hittable, so the gestures below effectively bind to the chip.
        RoomNodeView(room: room)
            .frame(width: size.width, height: size.height)
            .position(center(id: room.id,
                             baseX: room.positionX, baseY: room.positionY,
                             width: size.width, height: size.height))
            .id(room.id)
            .gesture((isAssigning || !canEdit) ? nil : dragGesture(forRoom: room))
            .onTapGesture { if !isAssigning && canEdit { editingRoom = room } }
            .contextMenu { if !isAssigning && canEdit { roomContextMenu(room) } }
    }

    @ViewBuilder
    private func shapeLayer(_ shape: DecorShape) -> some View {
        let side = max(shape.width, shape.height) + 36
        ShapeNodeView(shape: shape, isColliding: activeDrag?.id == shape.id && activeDrag?.colliding == true)
            .frame(width: side, height: side)
            .position(center(id: shape.id,
                             baseX: shape.positionX ?? 120, baseY: shape.positionY ?? 120,
                             width: shape.width, height: shape.height))
            .id(shape.id)
            .gesture((isAssigning || !canEdit) ? nil : dragGesture(forShape: shape))
            .onTapGesture { if !isAssigning && canEdit { editingShape = shape } }
            .contextMenu { if !isAssigning && canEdit { shapeContextMenu(shape) } }
    }

    /// Pink dashed guide lines for whatever the active drag is snapping to,
    /// shifted into content-rect space to match the items.
    @ViewBuilder
    private var guideOverlay: some View {
        if let guides = activeDrag?.guides, !guides.isEmpty {
            let content = contentRect
            Canvas { context, _ in
                let ox = content.origin.x, oy = content.origin.y
                for guide in guides {
                    var path = Path()
                    switch guide.axis {
                    case .vertical:
                        path.move(to: CGPoint(x: guide.position - ox, y: guide.start - oy))
                        path.addLine(to: CGPoint(x: guide.position - ox, y: guide.end - oy))
                    case .horizontal:
                        path.move(to: CGPoint(x: guide.start - ox, y: guide.position - oy))
                        path.addLine(to: CGPoint(x: guide.end - ox, y: guide.position - oy))
                    }
                    context.stroke(path, with: .color(Brand.alignmentGuide),
                                   style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
            }
            .frame(width: content.width, height: content.height)
            .allowsHitTesting(false)
        }
    }

    /// Committed zoom combined with the live pinch factor, clamped to range.
    private var effectiveZoom: CGFloat { clampZoom(zoom * gestureZoom) }

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        min(maxZoom, max(minZoom, value))
    }

    private func setZoom(_ value: CGFloat) {
        withAnimation(.snappy(duration: 0.2)) {
            zoom = clampZoom(value)
            gestureZoom = 1
        }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { gestureZoom = $0 }
            .onEnded { value in
                zoom = clampZoom(zoom * value)
                gestureZoom = 1
            }
    }

    /// Zooms and scrolls so the spread of tables fills the viewport, centering on
    /// the tables' bounding box — never the room. The offset is computed in the
    /// canvas's *scaled* coordinate space (`scrollPosition.scrollTo(point:)`),
    /// which lands precisely even when a room has enlarged the canvas. The scroll
    /// is deferred one runloop so it's applied after the new zoom has resized the
    /// content.
    private func fitToLayout(animated: Bool = true) {
        guard !store.tables.isEmpty, viewportSize.width > 0 else { return }

        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for table in store.tables {
            let x = CGFloat(table.positionX ?? 80)
            let y = CGFloat(table.positionY ?? 80)
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x + table.width)
            maxY = max(maxY, y + table.height)
        }

        let pad: CGFloat = 80
        let contentW = max(1, (maxX - minX) + pad * 2)
        let contentH = max(1, (maxY - minY) + pad * 2)
        let fit = clampZoom(min(viewportSize.width / contentW, viewportSize.height / contentH))

        // Tables' center in unscaled canvas coords (relative to the content box).
        let origin = contentRect.origin
        let centerX = (minX + maxX) / 2 - origin.x
        let centerY = (minY + maxY) / 2 - origin.y

        if animated {
            setZoom(fit)
        } else {
            zoom = fit
            gestureZoom = 1
        }

        // The new zoom resizes the scaled content; scroll after it commits so the
        // offset lands in the final coordinate space. The point is the canvas's
        // top-leading: the tables' scaled center minus half the viewport.
        DispatchQueue.main.async {
            let point = CGPoint(x: max(0, centerX * fit - viewportSize.width / 2),
                                y: max(0, centerY * fit - viewportSize.height / 2))
            if animated {
                withAnimation(.easeInOut(duration: 0.35)) { scrollPosition.scrollTo(point: point) }
            } else {
                scrollPosition.scrollTo(point: point)
            }
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
            pulse: pulse,
            isColliding: activeDrag?.id == table.id && activeDrag?.colliding == true
        )
    }

    // MARK: - Table list

    private var sortedTables: [SeatingTable] {
        SeatingLogic.sortedTables(store.tables, by: tableSort, guests: store.guests)
    }

    private var tableList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(sortedTables) { table in
                    tableListRow(table)
                }
            }
            .padding(16)
            // Clear the floating "Add Table" button.
            .padding(.bottom, 80)
        }
        .background(canvasBackground)
    }

    private func tableListRow(_ table: SeatingTable) -> some View {
        let occupancy = store.occupancy(of: table)
        let capacity = table.capacity ?? 0
        let expanded = expandedTables.contains(table.id)
        return VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { toggleExpanded(table.id) }
            } label: {
                tableRowHeader(table, occupancy: occupancy, capacity: capacity, expanded: expanded)
            }
            .buttonStyle(.plain)

            if expanded {
                tableRowDetail(table)
            }
        }
        .brandCard()
    }

    private func tableRowHeader(_ table: SeatingTable,
                                occupancy: Int,
                                capacity: Int,
                                expanded: Bool) -> some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(Brand.plumChipFill)
                Image(systemName: (table.shape ?? .circle).systemImage)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.plum)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(table.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
                Text(rowSubtitle(table))
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            occupancyPill(occupancy: occupancy, capacity: capacity)

            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Brand.slate400)
                .rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .padding(14)
        .contentShape(Rectangle())
    }

    private func rowSubtitle(_ table: SeatingTable) -> String {
        let type = table.matchingPreset?.label ?? (table.shape ?? .circle).label
        let w = TableScale.feetLabel(table.widthFeet)
        let size = table.isRound ? "\(w) ft round"
                                 : "\(w) × \(TableScale.feetLabel(table.heightFeet)) ft"
        return "\(type) · \(size)"
    }

    @ViewBuilder
    private func occupancyPill(occupancy: Int, capacity: Int) -> some View {
        if capacity <= 0 {
            TagPill.neutral("\(occupancy) seated")
        } else if occupancy > capacity {
            TagPill(text: "\(occupancy)/\(capacity)", fg: Brand.danger, bg: Brand.danger.opacity(0.12))
        } else if occupancy >= capacity {
            TagPill.seated("\(occupancy)/\(capacity)")
        } else {
            TagPill.open("\(occupancy)/\(capacity)")
        }
    }

    @ViewBuilder
    private func tableRowDetail(_ table: SeatingTable) -> some View {
        let seated = store.guests
            .filter { $0.tableId == table.id }
            .sorted { $0.lastNameKey < $1.lastNameKey }

        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Brand.hairline).frame(height: 1)

            if seated.isEmpty {
                Text("No one seated here yet.")
                    .font(.system(size: 14))
                    .foregroundStyle(Brand.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                ForEach(seated) { guest in
                    HStack(spacing: 10) {
                        InitialsAvatar(name: guest.name, size: 32)
                        Text(guest.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Brand.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if canEdit {
                            Button {
                                Task { await store.assignWithUndo(guest, toTable: nil) }
                            } label: {
                                Text("Unseat")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Brand.warningText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
            }

            // Open the full sheet (rename, resize, bulk-assign, delete).
            Button { selectedTable = table } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.badge.gearshape")
                    Text(canEdit ? "Manage seating" : "View table")
                }
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Brand.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .background(Brand.hairline.frame(height: 1), alignment: .top)
        }
    }

    private func toggleExpanded(_ id: String) {
        if expandedTables.contains(id) {
            expandedTables.remove(id)
        } else {
            expandedTables.insert(id)
        }
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
        }

        // Floating "Add Table" + zoom controls — hidden in assign mode. The zoom
        // cluster only applies to the canvas, not the list.
        if !isAssigning {
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    if effectiveMode == .canvas { zoomControl }
                    Spacer()
                    if canEdit { addMenu }
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

    /// One floating button that adds any kind of canvas item, keeping the three
    /// "add" paths in a single, predictable spot.
    private var addMenu: some View {
        Menu {
            Button { showingAddTable = true } label: { Label("Table", systemImage: "tablecells") }
            Button { showingAddShape = true } label: { Label("Shape", systemImage: "square.on.circle") }
            Button { showingAddRoom = true } label: { Label("Room", systemImage: "square.dashed") }
            Divider()
            Button { showingTemplates = true } label: { Label("Templates…", systemImage: "square.grid.3x3.square") }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 17, weight: .heavy))
                Text("Add").font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(height: 52)
            .background(Brand.primaryFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Brand.plum.opacity(scheme == .dark ? 0.4 : 0.6), radius: 15, x: 0, y: 12)
        }
        .accessibilityLabel("Add table, shape, or room")
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
            zoomButton(icon: "arrow.up.left.and.arrow.down.right",
                       action: { fitToLayout() },
                       accessibility: "Fit to layout")
            Divider().frame(width: 40)
            zoomButton(icon: "plus", action: { setZoom(zoom + 0.2) }, accessibility: "Zoom in")
            // Current zoom percent — tap to snap back to 100%.
            Button { setZoom(1) } label: {
                Text("\(Int((effectiveZoom * 100).rounded()))%")
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Brand.textSecondary)
                    .frame(width: 44, height: 28)
            }
            .accessibilityLabel("Reset zoom to 100%")
            zoomButton(icon: "minus", action: { setZoom(zoom - 0.2) }, accessibility: "Zoom out")
        }
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Brand.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.12), radius: 8, y: 2)
    }

    private func zoomButton(icon: String,
                            action: @escaping () -> Void,
                            accessibility: String) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(Brand.textPrimary)
                .frame(width: 40, height: 40)
        }
        .accessibilityLabel(accessibility)
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

    @ViewBuilder
    private func tableContextMenu(_ table: SeatingTable) -> some View {
        Button { selectedTable = table } label: {
            Label(canEdit ? "Manage seating" : "View table", systemImage: "person.2")
        }
        if canEdit {
            Button { editingTable = table } label: { Label("Edit table", systemImage: "pencil") }
            Button { Task { await store.duplicateTable(table) } } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            if !table.isRound {
                Button { Task { await store.updateRotation(of: table, to: table.rotationDegrees + 15) } } label: {
                    Label("Rotate 15°", systemImage: "rotate.right")
                }
            }
            Divider()
            Button(role: .destructive) { pendingDelete = table } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

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
            await store.assignWithUndo(guest, toTable: table.id)
            onFinishAssigning?()
        }
    }

    @ViewBuilder
    private func shapeContextMenu(_ shape: DecorShape) -> some View {
        Button { editingShape = shape } label: { Label("Edit shape", systemImage: "pencil") }
        Button { Task { await store.duplicateShape(shape) } } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        if !shape.isRound {
            Button { Task { await store.updateShapeRotation(of: shape, to: shape.rotationDegrees + 15) } } label: {
                Label("Rotate 15°", systemImage: "rotate.right")
            }
        }
        Divider()
        Button(role: .destructive) { pendingDeleteShape = shape } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func roomContextMenu(_ room: FloorPlanRoom) -> some View {
        Button { editingRoom = room } label: { Label("Edit room", systemImage: "pencil") }
        Divider()
        Button(role: .destructive) { pendingDeleteRoom = room } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Positioning + drag (tables, shapes, rooms share one path)

    /// An item's center *within the content rect*, following the live drag when
    /// it's the one being moved. Absolute coordinates are shifted by the content
    /// origin so off-canvas items land inside the scrollable box. Coordinates
    /// stay in canvas space — `scaleEffect` does the visual zoom, so we must NOT
    /// multiply by zoom here.
    private func center(id: String, baseX: Double, baseY: Double,
                        width: Double, height: Double) -> CGPoint {
        let origin = contentRect.origin
        if let drag = activeDrag, drag.id == id {
            return CGPoint(x: drag.topLeft.x + drag.size.width / 2 - origin.x,
                           y: drag.topLeft.y + drag.size.height / 2 - origin.y)
        }
        return CGPoint(x: baseX + width / 2 - origin.x, y: baseY + height / 2 - origin.y)
    }

    private func tableCenter(_ table: SeatingTable) -> CGPoint {
        center(id: table.id, baseX: table.positionX ?? 80, baseY: table.positionY ?? 80,
               width: table.width, height: table.height)
    }

    private func tableItem(_ t: SeatingTable) -> FloorPlanGeometry.Item {
        FloorPlanGeometry.Item(id: t.id, x: t.positionX ?? 80, y: t.positionY ?? 80,
                               width: t.width, height: t.height, rotation: t.rotationDegrees)
    }
    private func shapeItem(_ s: DecorShape) -> FloorPlanGeometry.Item {
        FloorPlanGeometry.Item(id: s.id, x: s.positionX ?? 120, y: s.positionY ?? 120,
                               width: s.width, height: s.height, rotation: s.rotationDegrees)
    }
    private func roomItem(_ r: FloorPlanRoom) -> FloorPlanGeometry.Item {
        FloorPlanGeometry.Item(id: r.id, x: r.positionX, y: r.positionY,
                               width: r.widthPoints, height: r.heightPoints, rotation: 0)
    }

    /// Everything a dragged item can snap its edges/center to (rooms included).
    private var alignmentItems: [FloorPlanGeometry.Item] {
        store.tables.map(tableItem) + store.shapes.map(shapeItem) + store.rooms.map(roomItem)
    }
    /// Only seatable footprints flag a collision (rooms are containers).
    private var collisionItems: [FloorPlanGeometry.Item] {
        store.tables.map(tableItem) + store.shapes.map(shapeItem)
    }

    /// Resolves a raw finger translation into a grid- + alignment-snapped drag,
    /// computing the guide lines and collision state along the way.
    private func resolveDrag(id: String, kind: ItemKind,
                             baseX: Double, baseY: Double,
                             width: Double, height: Double, rotation: Double,
                             translation: CGSize) -> ActiveDrag {
        let z = max(0.01, Double(effectiveZoom))
        // `translation` comes from a default `.local` gesture that lives INSIDE
        // `.scaleEffect(zoom)`, so SwiftUI already reports it in unscaled canvas
        // units (a finger move of D screen points reads as D/zoom here). We add
        // it straight to the base position — dividing by zoom again would apply
        // the zoom correction twice and make the item race ahead of the finger.
        // No 0-clamp: the canvas grows to fit, so items may live at negative or
        // far coordinates (web-authored layouts do) and stay freely draggable.
        var tlx = baseX + Double(translation.width)
        var tly = baseY + Double(translation.height)
        tlx = FloorPlanGeometry.snapToGrid(tlx, enabled: snapToGrid)
        tly = FloorPlanGeometry.snapToGrid(tly, enabled: snapToGrid)

        let others = alignmentItems.filter { $0.id != id }
        let dragged = FloorPlanGeometry.Item(id: id, x: tlx, y: tly,
                                             width: width, height: height, rotation: rotation)
        // Keep the screen-space engage distance constant across zoom levels.
        let snap = FloorPlanGeometry.alignmentSnap(dragged: dragged, others: others, threshold: 8 / z)
        if let sx = snap.x { tlx = sx }
        if let sy = snap.y { tly = sy }

        var colliding = false
        if kind != .room {
            let resolved = FloorPlanGeometry.Item(id: id, x: tlx, y: tly,
                                                  width: width, height: height, rotation: rotation)
            colliding = !FloorPlanGeometry.collisions(for: resolved,
                                                      among: collisionItems.filter { $0.id != id }).isEmpty
        }

        return ActiveDrag(id: id, kind: kind, topLeft: CGPoint(x: tlx, y: tly),
                          size: CGSize(width: width, height: height),
                          guides: snap.guides, colliding: colliding)
    }

    private func dragGesture(forTable table: SeatingTable) -> some Gesture {
        DragGesture()
            .onChanged { value in
                activeDrag = resolveDrag(id: table.id, kind: .table,
                                         baseX: table.positionX ?? 80, baseY: table.positionY ?? 80,
                                         width: table.width, height: table.height,
                                         rotation: table.rotationDegrees, translation: value.translation)
            }
            .onEnded { value in
                let d = resolveDrag(id: table.id, kind: .table,
                                    baseX: table.positionX ?? 80, baseY: table.positionY ?? 80,
                                    width: table.width, height: table.height,
                                    rotation: table.rotationDegrees, translation: value.translation)
                // Commit the new position and drop the drag together, in one
                // render pass, so the table never snaps back to its old spot.
                store.updatePosition(of: table, x: d.topLeft.x, y: d.topLeft.y)
                activeDrag = nil
            }
    }

    private func dragGesture(forShape shape: DecorShape) -> some Gesture {
        DragGesture()
            .onChanged { value in
                activeDrag = resolveDrag(id: shape.id, kind: .shape,
                                         baseX: shape.positionX ?? 120, baseY: shape.positionY ?? 120,
                                         width: shape.width, height: shape.height,
                                         rotation: shape.rotationDegrees, translation: value.translation)
            }
            .onEnded { value in
                let d = resolveDrag(id: shape.id, kind: .shape,
                                    baseX: shape.positionX ?? 120, baseY: shape.positionY ?? 120,
                                    width: shape.width, height: shape.height,
                                    rotation: shape.rotationDegrees, translation: value.translation)
                store.updateShapePosition(of: shape, x: d.topLeft.x, y: d.topLeft.y)
                activeDrag = nil
            }
    }

    private func dragGesture(forRoom room: FloorPlanRoom) -> some Gesture {
        DragGesture()
            .onChanged { value in
                activeDrag = resolveDrag(id: room.id, kind: .room,
                                         baseX: room.positionX, baseY: room.positionY,
                                         width: room.widthPoints, height: room.heightPoints,
                                         rotation: 0, translation: value.translation)
            }
            .onEnded { value in
                let d = resolveDrag(id: room.id, kind: .room,
                                    baseX: room.positionX, baseY: room.positionY,
                                    width: room.widthPoints, height: room.heightPoints,
                                    rotation: 0, translation: value.translation)
                store.updateRoomPosition(of: room, x: d.topLeft.x, y: d.topLeft.y)
                activeDrag = nil
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
    var isColliding: Bool = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var capacity: Int { table.capacity ?? 0 }
    private var isRound: Bool { (table.shape ?? .circle) == .circle || (table.shape ?? .circle) == .oval }
    private var isFull: Bool { capacity > 0 && occupancy >= capacity }
    private var seatRingColor: Color { .dynamic(Brand.seatRing, Brand.seatRingDark) }

    var body: some View {
        // Square frame so rotated rectangles never clip. The label rotates with
        // the body so it has the full table width to breathe in.
        let side = max(table.width, table.height) + 56
        return ZStack {
            seatDots
            tableBody
            label
        }
        .rotationEffect(.degrees(table.rotationDegrees))
        .frame(width: side, height: side)
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

    /// Selection/assign highlight color, or nil when none. A live collision
    /// during a drag always wins so the overlap reads at a glance.
    private var highlightColor: Color? {
        if isColliding { return Brand.collisionStroke }
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
                .truncationMode(.tail)

            if assigning {
                Text(isFull ? "Full" : "\(openSeats) open")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isFull ? Brand.slate400 : Brand.success)
            } else if capacity > 0 {
                Text("\(occupancy)/\(capacity)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(occupancyColor)
            }
        }
        // Clamp the label to the table body so long names ellipsize instead of
        // spilling past the edges.
        .frame(maxWidth: max(table.width - 16, 40))
    }

    private var occupancyColor: Color {
        isOverCapacity ? Brand.danger : Brand.textSecondary
    }

    // MARK: Seat dots

    @ViewBuilder
    private var seatDots: some View {
        let count = max(capacity, 0)
        if count > 0 {
            let offsets = seatOffsets(count: count)
            ZStack {
                ForEach(0..<count, id: \.self) { index in
                    seatDot(at: index, offset: offsets[index])
                }
            }
        }
    }

    /// Seat-center offsets from the table center. Round tables seat on an ellipse;
    /// rectangles seat along their two long edges and squares along all four, so
    /// chairs hug the perimeter without ever landing inside the body.
    private func seatOffsets(count: Int) -> [CGPoint] {
        guard count > 0 else { return [] }
        let outset: CGFloat = assigning ? 20 : 14   // table edge → seat center
        let w = table.width, h = table.height

        switch table.shape ?? .circle {
        case .circle, .oval:
            return (0..<count).map { i in
                let angle = (Double(i) / Double(count)) * 2 * .pi - .pi / 2
                return CGPoint(x: CGFloat(cos(angle)) * (w / 2 + outset),
                               y: CGFloat(sin(angle)) * (h / 2 + outset))
            }
        case .rectangle:
            return rectEdgeOffsets(count: count, w: w, h: h, outset: outset, allFourSides: false)
        case .square:
            return rectEdgeOffsets(count: count, w: w, h: h, outset: outset, allFourSides: true)
        }
    }

    /// Even spacing of `k` seat centers along a segment of `length`, inset from the
    /// corners so chairs never poke past the ends. A single seat sits centered.
    private func edgePositions(_ k: Int, length: CGFloat) -> [CGFloat] {
        guard k > 0 else { return [] }
        let inset: CGFloat = 18
        let usable = max(length - 2 * inset, 0)
        if k == 1 { return [0] }
        return (0..<k).map { -usable / 2 + usable * CGFloat($0) / CGFloat(k - 1) }
    }

    /// Lay seats along a rectangle's edges. Rectangles use only the two long
    /// sides (banquet style); squares split evenly across all four.
    private func rectEdgeOffsets(count: Int, w: CGFloat, h: CGFloat,
                                 outset: CGFloat, allFourSides: Bool) -> [CGPoint] {
        var pts: [CGPoint] = []
        if allFourSides {
            // top, bottom, left, right — distribute as evenly as possible.
            let top = (count + 3) / 4, bottom = (count + 1) / 4
            let left = (count + 2) / 4, right = count / 4
            for x in edgePositions(top, length: w) { pts.append(CGPoint(x: x, y: -(h / 2 + outset))) }
            for x in edgePositions(bottom, length: w) { pts.append(CGPoint(x: x, y: h / 2 + outset)) }
            for y in edgePositions(left, length: h) { pts.append(CGPoint(x: -(w / 2 + outset), y: y)) }
            for y in edgePositions(right, length: h) { pts.append(CGPoint(x: w / 2 + outset, y: y)) }
        } else {
            let isWide = w >= h
            let longLen = isWide ? w : h
            let perp = (isWide ? h : w) / 2 + outset
            let n1 = (count + 1) / 2, n2 = count - n1
            for p in edgePositions(n1, length: longLen) {
                pts.append(isWide ? CGPoint(x: p, y: -perp) : CGPoint(x: -perp, y: p))
            }
            for p in edgePositions(n2, length: longLen) {
                pts.append(isWide ? CGPoint(x: p, y: perp) : CGPoint(x: perp, y: p))
            }
        }
        return pts
    }

    @ViewBuilder
    private func seatDot(at index: Int, offset: CGPoint) -> some View {
        let filled = index < occupancy
        let dx = offset.x
        let dy = offset.y

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
                        // Reduce Motion: hold a static highlight instead of looping (A11y-3).
                        .scaleEffect(reduceMotion ? 1.15 : (pulse ? 1.15 : 0.9))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                                   value: pulse)
                    Circle().fill(Brand.success)
                        .frame(width: 22, height: 22)
                        .overlay(Image(systemName: "plus")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(.white))
                }
                .offset(x: dx, y: dy)
            }
        } else {
            // Chair: a hollow mauve ring. A seated chair fills its center with a
            // solid plum dot — mirrors the web floor plan.
            ZStack {
                Circle()
                    .fill(Brand.card)
                    .frame(width: 24, height: 24)
                Circle()
                    .strokeBorder(seatRingColor, lineWidth: 2)
                    .frame(width: 24, height: 24)
                if filled {
                    Circle()
                        .fill(Brand.accent)
                        .frame(width: 11, height: 11)
                }
            }
            .offset(x: dx, y: dy)
        }
    }
}

/// A room boundary drawn behind the tables: a tinted, outlined rectangle with a
/// name chip in its corner. The large fill is non-interactive so the canvas
/// still pans over it; only the chip is hittable, so the drag / tap / context
/// gestures attached by `roomLayer` effectively bind to the chip.
struct RoomNodeView: View {
    let room: FloorPlanRoom

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let fill = scheme == .dark ? Color.white.opacity(0.03) : Color.hex(room.colorHex).opacity(0.5)
        let stroke = scheme == .dark ? Color.white.opacity(0.4) : Brand.slate500.opacity(0.55)
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(stroke, style: StrokeStyle(lineWidth: 2, dash: [10, 6])))
            .allowsHitTesting(false)
            .overlay(alignment: .topLeading) { nameChip }
            .accessibilityElement()
            .accessibilityLabel("Room \(room.name)")
    }

    private var nameChip: some View {
        let label = "\(room.name)  ·  \(TableScale.feetLabel(room.widthFt))×\(TableScale.feetLabel(room.heightFt)) ft"
        return Text(label)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Brand.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Brand.card.opacity(0.92), in: Capsule())
            .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
            .padding(8)
            .contentShape(Capsule())
    }
}

/// A decorative object (stage, dance floor, bar, …): a filled, outlined shape
/// with a centered name label. Rotates about its center like a table; turns red
/// while a drag has it overlapping another item.
struct ShapeNodeView: View {
    let shape: DecorShape
    var isColliding: Bool = false

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            body(for: shape.type)
                .frame(width: shape.width, height: shape.height)
                .rotationEffect(.degrees(shape.rotationDegrees))
            Text(shape.name)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Brand.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func body(for type: TableShape) -> some View {
        let fill = scheme == .dark ? Color.hex("#11203A") : Brand.slate100
        let stroke = isColliding ? Brand.collisionStroke
                                 : (scheme == .dark ? Color.white.opacity(0.45) : Brand.slate400)
        let lineWidth: CGFloat = isColliding ? 3 : 1.5
        switch type {
        case .circle, .oval:
            Ellipse().fill(fill)
                .overlay(Ellipse().strokeBorder(stroke, lineWidth: lineWidth))
                .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.08), radius: 6, y: 3)
        case .square, .rectangle:
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(stroke, lineWidth: lineWidth))
                .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.08), radius: 6, y: 3)
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
