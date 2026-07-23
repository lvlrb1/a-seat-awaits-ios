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
    /// The canvas item (table/shape/room) the user has tapped to select. Only the
    /// selected item can be dragged — everything else lets the canvas pan — so a
    /// move is always deliberate, never a side effect of scrolling to look around.
    @State private var selectedItemID: String?
    /// Bumped each time a drag newly engages an alignment guide, to fire a light
    /// "snap" haptic. Paired with `lastGuideSig` to detect the transition.
    @State private var snapTick = 0
    @State private var lastGuideSig = ""
    /// The item being rotated by a live two-finger twist, with its in-flight
    /// angle and the 15° detent it's locked to (nil while between detents).
    @State private var activeRotation: ActiveRotation?
    /// Bumped each time the twist locks onto a new 15° detent, for a click haptic.
    @State private var rotateSnapTick = 0
    /// Set the moment a two-finger twist engages while a one-finger drag is
    /// live: the twist owns the item from then on, and the drag is dead until
    /// every finger lifts — otherwise the leading finger's arc would keep
    /// dragging the item (or replay as a jump when the twist ends first).
    @State private var dragSuppressedByTwist = false

    private struct ActiveRotation: Equatable {
        let id: String
        var degrees: Double
        var detent: Double?
    }
    @State private var selectedTable: SeatingTable?
    @State private var showingAddTable = false
    @State private var toast: AssignToast?
    @State private var pulse = false
    /// Bumped when an assign-mode tap lands on a full table, to fire an error haptic.
    @State private var errorTick = 0
    /// Arms the delete confirmation for whatever canvas item is selected.
    @State private var confirmingDelete = false

    /// Feedback pinned above the tab bar while assigning: green confirmation
    /// when a guest lands, amber warning when the tapped table has no room.
    private struct AssignToast: Equatable {
        let text: String
        let isSuccess: Bool
    }

    // Decorative shapes + rooms (Tier 3).
    @State private var editingShape: DecorShape?
    @State private var showingAddShape = false
    @State private var editingRoom: FloorPlanRoom?
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
    /// Live content offset of the canvas, tracked so pinch-zoom can keep the point
    /// under the fingers anchored (focal-point zoom, the way Figma/Freeform feel).
    @State private var scrollOffset: CGPoint = .zero
    /// References captured when a pinch begins: the focal point (in scaled-content
    /// coordinates), the zoom, and the offset — the anchors focal zoom maths against.
    @State private var pinchStart: PinchStart?

    private struct PinchStart {
        let anchor: CGPoint
        let zoom: CGFloat
        let offset: CGPoint
    }

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
        /// When the drag first engaged — pairs with the end translation to tell
        /// a sloppy tap (short + tiny) apart from a deliberate small nudge.
        var startedAt: Date = .distantPast
    }

    private let canvasSize = CGSize(width: 1000, height: 1400)
    private let minZoom: CGFloat = 0.2
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
        .confirmationDialog(deleteDialogTitle,
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteDialogMessage)
        }
        .sensoryFeedback(.error, trigger: errorTick)
        .onAppear { pulse = true }
        // Selection only makes sense on an editable canvas — clear it when the
        // context changes out from under it.
        .onChange(of: isAssigning) { _, _ in selectedItemID = nil }
        .onChange(of: mode) { _, _ in selectedItemID = nil }
    }

    private var canvasBackground: Color {
        scheme == .dark ? Brand.canvasDark : Color.hex("#F1F5EF")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No tables yet", systemImage: "square.on.square.dashed")
        } description: {
            Text(canEdit
                 ? "Add a table to start laying out your floor plan, then drag everything into place."
                 : "Tables will appear here once the planner adds them.")
        } actions: {
            if canEdit {
                Button { showingAddTable = true } label: {
                    Label("Add a Table", systemImage: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.primaryFill)

                Button { showingTemplates = true } label: {
                    Text("Start from a template")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.accent)
                }
                .buttonStyle(.plain)
            }
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
        // Computed once per render pass: a drag re-evaluates this body on every
        // finger move, so per-item recomputation here multiplies into the frame
        // budget fast.
        let content = contentRect
        let origin = content.origin
        let occupancy = occupancyByTable
        return ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                DotGrid(dotColor: scheme == .dark ? Brand.hairlineDark : Color.hex("#D6D3CC"))
                    // Equatable: the dot field (tens of thousands of fills) must
                    // not re-render on every drag/pinch frame.
                    .equatable()
                    .frame(width: content.width, height: content.height)
                    .contentShape(Rectangle())
                    // One handler covers both: a tap dismisses the selection
                    // instantly (no double-tap-disambiguation delay), and a
                    // quick second tap steps the zoom.
                    .onTapGesture { location in handleCanvasTap(at: location) }

                // Back-to-front: rooms, then decorative shapes, then tables.
                ForEach(store.rooms) { room in roomLayer(room, origin: origin) }
                ForEach(store.shapes) { shape in shapeLayer(shape, origin: origin) }
                ForEach(store.tables) { table in
                    tableNode(table, occupancy: occupancy[table.id, default: 0])
                        .floorPlanSelected(selectedItemID == table.id,
                                           dragging: activeDrag?.id == table.id)
                        .position(tableCenter(table, origin: origin))
                        .id(table.id)
                        .onTapGesture { handleTableTap(table) }
                        .gesture(canMove(table.id) ? dragGesture(forTable: table) : nil)
                        .simultaneousGesture(canTwist(table) ? twistGesture(forTable: table) : nil)
                }

                // Rotate handle for the selected item (web-canvas parity).
                rotationHandleOverlay(origin: origin)

                // Alignment guides on top of everything, in canvas space.
                guideOverlay(content: content)
            }
            .frame(width: content.width, height: content.height, alignment: .topLeading)
            .coordinateSpace(name: Self.canvasSpace)
            .scaleEffect(effectiveZoom, anchor: .topLeading)
            .frame(width: content.width * effectiveZoom,
                   height: content.height * effectiveZoom,
                   alignment: .topLeading)
            // No zooming while an item is mid-drag/twist — a stray second
            // finger would otherwise rescale the canvas under the move.
            .gesture(activeDrag == nil && activeRotation == nil ? magnifyGesture : nil)
        }
        .scrollPosition($scrollPosition)
        // Mirror the live content offset so focal-point pinch zoom can anchor on it.
        .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, new in
            scrollOffset = new
        }
        // While a drag or twist is in flight, freeze the canvas so the move never
        // fights the pan — you're either scrolling or repositioning, never both.
        .scrollDisabled(activeDrag != nil || activeRotation != nil)
        // Light tap when a tap lands on a table to select it.
        .sensoryFeedback(trigger: selectedItemID) { _, new in
            new != nil ? .selection : nil
        }
        // A firmer tap when a move begins (pickup) and a crisp one when it lands.
        .sensoryFeedback(trigger: activeDrag?.id) { old, new in
            if old == nil && new != nil { return .impact(weight: .medium) }
            if old != nil && new == nil { return .impact(flexibility: .solid, intensity: 0.7) }
            return nil
        }
        // A subtle click each time the dragged item snaps onto an alignment guide.
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: snapTick)
        // …and each time a two-finger twist locks onto a 15° detent.
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: rotateSnapTick)
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

        // The canvas must stay larger than the viewport even fully zoomed out, or
        // the dotted floor shrinks to a small patch and the rest reads as "cut
        // off." `viewport / minZoom` is the content size that exactly fills the
        // screen at the most-zoomed-out level; we keep at least that, plus a margin.
        let z = max(minZoom, 0.01)
        let fillW = viewportSize.width / z * 1.3
        let fillH = viewportSize.height / z * 1.3

        guard minX <= maxX else {
            let w = max(canvasSize.width, fillW), h = max(canvasSize.height, fillH)
            return CGRect(origin: .zero, size: CGSize(width: w, height: h))
        }
        // Origin stays anchored to the items' top-left (with a margin) so it only
        // shifts when the spread itself changes — moving a table never makes the
        // whole canvas jump. The box just grows down/right to fill the screen.
        let originX = minX - pad, originY = minY - pad
        let width = max(canvasSize.width, (maxX - minX) + pad * 2, fillW)
        let height = max(canvasSize.height, (maxY - minY) + pad * 2, fillH)
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    // MARK: - Room + shape layers

    @ViewBuilder
    private func roomLayer(_ room: FloorPlanRoom, origin: CGPoint) -> some View {
        let size = CGSize(width: room.widthPoints, height: room.heightPoints)
        // The room fill is non-interactive (canvas pans over it); only the name
        // chip is hittable, so the gestures below effectively bind to the chip.
        RoomNodeView(room: room, isSelected: selectedItemID == room.id)
            .frame(width: size.width, height: size.height)
            .floorPlanSelected(selectedItemID == room.id, dragging: activeDrag?.id == room.id)
            .position(center(id: room.id,
                             baseX: room.positionX, baseY: room.positionY,
                             width: size.width, height: size.height,
                             origin: origin))
            .id(room.id)
            .onTapGesture { handleRoomTap(room) }
            .gesture(canMove(room.id) ? dragGesture(forRoom: room) : nil)
    }

    private func shapeLayer(_ shape: DecorShape, origin: CGPoint) -> some View {
        let side = max(shape.width, shape.height) + 36
        let liveTwist = activeRotation?.id == shape.id
        var display = shape
        if liveTwist, let degrees = activeRotation?.degrees { display.rotation = degrees }
        return ShapeNodeView(shape: display,
                             isColliding: activeDrag?.id == shape.id && activeDrag?.colliding == true,
                             isSelected: selectedItemID == shape.id,
                             liveRotating: liveTwist)
            .frame(width: side, height: side)
            .floorPlanSelected(selectedItemID == shape.id, dragging: activeDrag?.id == shape.id)
            .position(center(id: shape.id,
                             baseX: shape.positionX ?? 120, baseY: shape.positionY ?? 120,
                             width: shape.width, height: shape.height,
                             origin: origin))
            .id(shape.id)
            .onTapGesture { handleShapeTap(shape) }
            .gesture(canMove(shape.id) ? dragGesture(forShape: shape) : nil)
            .simultaneousGesture(canTwist(shape) ? twistGesture(forShape: shape) : nil)
    }

    /// Pink dashed guide lines for whatever the active drag is snapping to,
    /// shifted into content-rect space to match the items.
    @ViewBuilder
    private func guideOverlay(content: CGRect) -> some View {
        if let guides = activeDrag?.guides, !guides.isEmpty {
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

    /// Committed zoom combined with the live pinch factor. Deliberately NOT
    /// hard-clamped: a live pinch may rubber-band past the limits (see
    /// `rubberBandZoom`); every committed setter clamps before storing.
    private var effectiveZoom: CGFloat { zoom * gestureZoom }

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        min(maxZoom, max(minZoom, value))
    }

    /// Soft-clamps a raw pinch zoom: inside the range it passes straight
    /// through; past a limit the overshoot is damped hard, so the canvas
    /// stretches a little and resists like a rubber band instead of stopping
    /// dead. The gesture's end animates back to the clamped level.
    private func rubberBandZoom(_ raw: CGFloat) -> CGFloat {
        if raw > maxZoom { return maxZoom * pow(raw / maxZoom, 0.35) }
        if raw < minZoom { return minZoom * pow(raw / minZoom, 0.35) }
        return raw
    }

    private func setZoom(_ value: CGFloat) {
        withAnimation(.snappy(duration: 0.2)) {
            zoom = clampZoom(value)
            gestureZoom = 1
        }
    }

    /// The scroll offset that keeps the canvas point under `focal` (a point in the
    /// scaled-content space) fixed as the zoom goes `from` → `to`. Both offset and
    /// focal share the content's top-left origin, so the algebra is just:
    /// O₁ = O₀ + focal · (to/from − 1).
    private func anchoredOffset(focal: CGPoint, from z0: CGFloat, to z1: CGFloat,
                                offset: CGPoint) -> CGPoint {
        let ratio = z1 / z0
        return CGPoint(x: offset.x + focal.x * (ratio - 1),
                       y: offset.y + focal.y * (ratio - 1))
    }

    /// Zoom to an absolute level while keeping the viewport's center fixed — so the
    /// +/−/reset buttons zoom into the middle of what you're looking at, not a corner.
    private func zoomCentered(to value: CGFloat) {
        let z1 = clampZoom(value)
        guard viewportSize.width > 0, z1 != zoom else { setZoom(value); return }
        let focal = CGPoint(x: scrollOffset.x + viewportSize.width / 2,
                            y: scrollOffset.y + viewportSize.height / 2)
        let target = anchoredOffset(focal: focal, from: zoom, to: z1, offset: scrollOffset)
        withAnimation(.snappy(duration: 0.2)) { zoom = z1; gestureZoom = 1 }
        // Apply the offset after the zoom resizes the content, so it lands in the
        // final coordinate space.
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.2)) { scrollPosition.scrollTo(point: target) }
        }
    }

    /// Two-finger pinch with focal-point anchoring: the spot under your fingers
    /// stays put as the canvas scales, the way Figma/Freeform/Keynote feel. We pin
    /// the focal point captured at the pinch's start and move the scroll offset to
    /// compensate each frame, instead of letting the canvas grow from a corner.
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? {
                    let s = PinchStart(anchor: value.startLocation, zoom: zoom, offset: scrollOffset)
                    pinchStart = s
                    return s
                }()
                let zPrev = effectiveZoom
                let z1 = rubberBandZoom(start.zoom * value.magnification)
                gestureZoom = z1 / start.zoom   // effectiveZoom == z1
                // Anchor incrementally against the LIVE offset, not the pinch's
                // start offset: the scroll view still pans with two fingers, and
                // an absolute target would clobber that pan every frame — the
                // canvas would shimmer and fight the fingers. Off the live
                // offset, pan and zoom compose. `focal` is the pinched point in
                // unscaled canvas units, so O₁ = O + focal·(z₁ − z₀) keeps it
                // fixed on screen.
                let focal = CGPoint(x: start.anchor.x / start.zoom,
                                    y: start.anchor.y / start.zoom)
                scrollPosition.scrollTo(point: CGPoint(x: scrollOffset.x + focal.x * (z1 - zPrev),
                                                       y: scrollOffset.y + focal.y * (z1 - zPrev)))
            }
            .onEnded { value in
                defer { pinchStart = nil }
                guard let start = pinchStart else { gestureZoom = 1; return }
                let raw = start.zoom * value.magnification
                let settled = clampZoom(raw)
                if rubberBandZoom(raw) == settled {
                    // Ended inside the range — commit with no visual change.
                    zoom = settled
                    gestureZoom = 1
                } else {
                    // Ended stretched past a limit — spring back to the clamped
                    // level, keeping the pinch's focal point anchored.
                    let zPrev = effectiveZoom
                    let focal = CGPoint(x: start.anchor.x / start.zoom,
                                        y: start.anchor.y / start.zoom)
                    let target = CGPoint(x: scrollOffset.x + focal.x * (settled - zPrev),
                                         y: scrollOffset.y + focal.y * (settled - zPrev))
                    withAnimation(.spring(duration: 0.3)) {
                        zoom = settled
                        gestureZoom = 1
                    }
                    DispatchQueue.main.async {
                        withAnimation(.spring(duration: 0.3)) {
                            scrollPosition.scrollTo(point: target)
                        }
                    }
                }
            }
    }

    /// The previous empty-canvas tap, kept just long enough to recognize a
    /// double-tap by hand (time + distance) instead of via a sequenced
    /// `onTapGesture(count: 2)` — which would hold every single tap hostage
    /// for the disambiguation interval and make deselection feel laggy.
    @State private var lastCanvasTap: (time: Date, point: CGPoint)?

    /// One handler for taps on the empty canvas: the first tap clears the
    /// selection immediately; a second tap within 0.35s and ~60 screen points
    /// steps the zoom (the Maps/Photos double-tap rhythm).
    private func handleCanvasTap(at point: CGPoint) {
        let now = Date()
        if let last = lastCanvasTap,
           now.timeIntervalSince(last.time) < 0.35,
           hypot(point.x - last.point.x, point.y - last.point.y) * effectiveZoom < 60 {
            lastCanvasTap = nil
            handleDoubleTapZoom(at: point)
            return
        }
        lastCanvasTap = (now, point)
        if selectedItemID != nil { deselect() }
    }

    /// Double-tap zoom, anchored on the tapped canvas point: it steps up
    /// through comfortable working levels (100% → 200%) and, once fully zoomed
    /// in, drops back out to frame the whole layout — the Maps/Photos rhythm.
    private func handleDoubleTapZoom(at canvasPoint: CGPoint) {
        if zoom >= 2 * 0.98 {
            fitToLayout()
        } else if zoom >= 1 * 0.98 {
            zoomAnchored(to: 2, canvasPoint: canvasPoint)
        } else {
            zoomAnchored(to: 1, canvasPoint: canvasPoint)
        }
    }

    /// Zoom to an absolute level while keeping the given *unscaled* canvas
    /// point fixed on screen — the tap target stays put as the canvas grows.
    private func zoomAnchored(to value: CGFloat, canvasPoint: CGPoint) {
        let z1 = clampZoom(value)
        guard viewportSize.width > 0, z1 != zoom else { return }
        // Into scaled-content space, where `anchoredOffset` does its algebra.
        let focal = CGPoint(x: canvasPoint.x * zoom, y: canvasPoint.y * zoom)
        let target = anchoredOffset(focal: focal, from: zoom, to: z1, offset: scrollOffset)
        withAnimation(.snappy(duration: 0.25)) { zoom = z1; gestureZoom = 1 }
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.25)) { scrollPosition.scrollTo(point: target) }
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

    /// Seated-guest counts per table, computed in one pass over the guest list.
    /// The canvas body re-evaluates on every drag frame, so deriving occupancy /
    /// open seats / over-capacity per table from this map keeps that work
    /// O(guests) instead of O(tables × guests) per frame.
    private var occupancyByTable: [String: Int] {
        var counts: [String: Int] = [:]
        for guest in store.guests {
            if let id = guest.tableId { counts[id, default: 0] += 1 }
        }
        return counts
    }

    private func tableNode(_ table: SeatingTable, occupancy: Int) -> some View {
        let capacity = table.capacity ?? 0
        let open = capacity > 0 ? max(0, capacity - occupancy) : capacity
        // Follow the live twist angle while this table is being rotated.
        let liveTwist = activeRotation?.id == table.id
        var display = table
        if liveTwist, let degrees = activeRotation?.degrees { display.rotation = degrees }
        return TableNodeView(
            table: display,
            occupancy: occupancy,
            isOverCapacity: capacity > 0 && occupancy > capacity,
            isSelected: selectedItemID == table.id,
            assigning: isAssigning,
            openSeats: open,
            pulse: pulse,
            isColliding: activeDrag?.id == table.id && activeDrag?.colliding == true,
            liveRotating: liveTwist
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

        // Bottom controls — hidden in assign mode. A selected canvas item swaps the
        // zoom/add cluster for its contextual toolbar so the focus stays on it.
        if !isAssigning {
            VStack {
                Spacer()
                if effectiveMode == .canvas, canEdit, let item = selectedCanvasItem {
                    selectionToolbar(item)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    HStack(alignment: .bottom) {
                        if effectiveMode == .canvas { zoomControl }
                        Spacer()
                        if canEdit { addMenu }
                    }
                }
            }
            .padding(18)
            .animation(.snappy(duration: 0.2), value: selectedItemID)
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

    // MARK: - Selection toolbar

    /// The kind of item currently selected on the canvas, resolved fresh from the
    /// store so its name/occupancy stay live while the toolbar is up.
    private enum SelectedItem {
        case table(SeatingTable), shape(DecorShape), room(FloorPlanRoom)
    }

    private var selectedCanvasItem: SelectedItem? {
        guard let id = selectedItemID else { return nil }
        if let t = store.tables.first(where: { $0.id == id }) { return .table(t) }
        if let s = store.shapes.first(where: { $0.id == id }) { return .shape(s) }
        if let r = store.rooms.first(where: { $0.id == id }) { return .room(r) }
        return nil
    }

    /// A contextual bar for the selected item: it names the item, teaches the
    /// drag-to-move gesture, and offers the item's primary action plus Done —
    /// with a quick-action row (rotate / duplicate / delete) underneath so common
    /// edits never require the full sheet.
    private func selectionToolbar(_ item: SelectedItem) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: selectionIcon(item))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Brand.accent)
                    .frame(width: 42, height: 42)
                    .background(Brand.accent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(selectionTitle(item))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                        .lineLimit(1)
                    Text(selectionSubtitle(item))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Brand.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button { selectionPrimaryAction(item) } label: {
                    Text(selectionPrimaryLabel(item))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 42)
                        .background(Brand.primaryFill,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Button { deselect() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Brand.textSecondary)
                        .frame(width: 42, height: 42)
                        .background(Brand.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .accessibilityLabel("Deselect")
            }

            quickActionRow(item)
        }
        .padding(10)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Brand.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.14), radius: 16, y: 8)
    }

    /// Duplicate / delete for the selected item (rooms only offer delete — no
    /// duplicate API). Rotation happens directly on the canvas, via the rotate
    /// handle or a two-finger twist.
    @ViewBuilder
    private func quickActionRow(_ item: SelectedItem) -> some View {
        HStack(spacing: 8) {
            if selectionCanDuplicate(item) {
                quickAction(icon: "plus.square.on.square", label: "Duplicate") {
                    duplicateSelection(item)
                }
            }
            quickAction(icon: "trash", label: "Delete", tint: Brand.danger) {
                confirmingDelete = true
            }
        }
    }

    private func quickAction(icon: String, label: String,
                             tint: Color? = nil,
                             action: @escaping () -> Void) -> some View {
        let fg = tint ?? Brand.textPrimary
        return Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .bold))
                Text(label).font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(tint == nil ? Brand.control : fg.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func selectionCanRotate(_ item: SelectedItem) -> Bool {
        switch item {
        case .table(let t): return !t.isRound
        case .shape(let s): return s.type == .square || s.type == .rectangle
        case .room: return false
        }
    }

    private func selectionCanDuplicate(_ item: SelectedItem) -> Bool {
        if case .room = item { return false }
        return true
    }

    private func duplicateSelection(_ item: SelectedItem) {
        switch item {
        case .table(let t): Task { await store.duplicateTable(t) }
        case .shape(let s): Task { await store.duplicateShape(s) }
        case .room: break
        }
    }

    private var deleteDialogTitle: String {
        guard let item = selectedCanvasItem else { return "Delete item?" }
        return "Delete \(selectionTitle(item))?"
    }

    private var deleteDialogMessage: String {
        if case .table = selectedCanvasItem {
            return "Guests at this table will become unassigned."
        }
        return "This removes it from the floor plan."
    }

    private func performDelete() {
        guard let item = selectedCanvasItem else { return }
        deselect()
        switch item {
        case .table(let t): Task { await store.deleteTable(t) }
        case .shape(let s): Task { await store.deleteShape(s) }
        case .room(let r): Task { await store.deleteRoom(r) }
        }
    }

    private func selectionIcon(_ item: SelectedItem) -> String {
        switch item {
        case .table: return "tablecells"
        case .shape: return "square.on.circle"
        case .room: return "square.dashed"
        }
    }

    private func selectionTitle(_ item: SelectedItem) -> String {
        switch item {
        case .table(let t): return t.name
        case .shape(let s): return s.name
        case .room(let r): return r.name
        }
    }

    private func selectionSubtitle(_ item: SelectedItem) -> String {
        let move = selectionCanRotate(item) ? "Drag or twist" : "Drag to move"
        if case .table(let t) = item, let capacity = t.capacity, capacity > 0 {
            return "\(move) · \(store.occupancy(of: t))/\(capacity) seated"
        }
        return move
    }

    private func selectionPrimaryLabel(_ item: SelectedItem) -> String {
        if case .table = item { return "Manage" }
        return "Edit"
    }

    private func selectionPrimaryAction(_ item: SelectedItem) {
        switch item {
        case .table(let t): selectedTable = t
        case .shape(let s): editingShape = s
        case .room(let r): editingRoom = r
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
            zoomButton(icon: "arrow.up.left.and.arrow.down.right",
                       action: { fitToLayout() },
                       accessibility: "Fit to layout")
            Divider().frame(width: 40)
            zoomButton(icon: "plus", action: { zoomCentered(to: zoom + 0.2) }, accessibility: "Zoom in")
            // Current zoom percent — tap to snap back to 100%.
            Button { zoomCentered(to: 1) } label: {
                Text("\(Int((effectiveZoom * 100).rounded()))%")
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Brand.textSecondary)
                    .frame(width: 44, height: 28)
            }
            .accessibilityLabel("Reset zoom to 100%")
            zoomButton(icon: "minus", action: { zoomCentered(to: zoom - 0.2) }, accessibility: "Zoom out")
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

    private func conflictToast(_ toast: AssignToast) -> some View {
        HStack(spacing: 11) {
            Image(systemName: toast.isSuccess ? "checkmark.circle" : "exclamationmark.triangle.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(toast.isSuccess ? Color.hex("#22C55E") : Brand.warningDark)
            Text(toast.text)
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

    /// Only the selected item is draggable, and only on an editable, non-assign
    /// canvas — so a move is always a deliberate "tap to pick, then drag."
    private func canMove(_ id: String) -> Bool {
        canEdit && !isAssigning && selectedItemID == id
    }

    private func selectItem(_ id: String) {
        guard selectedItemID != id else { return }
        withAnimation(.snappy(duration: 0.18)) { selectedItemID = id }
    }

    private func deselect() {
        withAnimation(.snappy(duration: 0.18)) { selectedItemID = nil }
    }

    /// Tap behaviour for a table: assign-mode drop, view-only peek, or the
    /// select-then-open flow when editing (first tap selects, second opens).
    private func handleTableTap(_ table: SeatingTable) {
        if isAssigning { handleTap(table); return }
        guard canEdit else { selectedTable = table; return }
        if selectedItemID == table.id {
            selectedTable = table
        } else {
            selectItem(table.id)
        }
    }

    private func handleShapeTap(_ shape: DecorShape) {
        guard !isAssigning, canEdit else { return }
        if selectedItemID == shape.id { editingShape = shape } else { selectItem(shape.id) }
    }

    private func handleRoomTap(_ room: FloorPlanRoom) {
        guard !isAssigning, canEdit else { return }
        if selectedItemID == room.id { editingRoom = room } else { selectItem(room.id) }
    }

    private func handleTap(_ table: SeatingTable) {
        guard let guest = assigning else {
            selectedTable = table
            return
        }
        // Assign mode: only tables with room accept the guest. A full table
        // answers with an error haptic and a short-lived warning toast, so the
        // tap never just dies silently.
        let open = SeatingLogic.remainingSeats(table, guests: store.guests)
        let hasRoom = open == nil || (open ?? 0) > 0
        guard hasRoom else {
            errorTick &+= 1
            withAnimation { toast = AssignToast(text: "\(table.name) is full — tap a table with open seats.",
                                                isSuccess: false) }
            Task {
                try? await Task.sleep(for: .seconds(2.4))
                if toast?.isSuccess == false {
                    withAnimation { toast = nil }
                }
            }
            return
        }
        withAnimation { toast = AssignToast(text: "No conflicts. \(table.name) has room.",
                                            isSuccess: true) }
        Task {
            await store.assignWithUndo(guest, toTable: table.id)
            onFinishAssigning?()
        }
    }


    // MARK: - Positioning + drag (tables, shapes, rooms share one path)

    /// An item's center *within the content rect*, following the live drag when
    /// it's the one being moved. Absolute coordinates are shifted by the content
    /// origin (passed in by the caller — computing `contentRect` per item would
    /// go quadratic on drag frames) so off-canvas items land inside the
    /// scrollable box. Coordinates stay in canvas space — `scaleEffect` does the
    /// visual zoom, so we must NOT multiply by zoom here.
    private func center(id: String, baseX: Double, baseY: Double,
                        width: Double, height: Double, origin: CGPoint) -> CGPoint {
        if let drag = activeDrag, drag.id == id {
            return CGPoint(x: drag.topLeft.x + drag.size.width / 2 - origin.x,
                           y: drag.topLeft.y + drag.size.height / 2 - origin.y)
        }
        return CGPoint(x: baseX + width / 2 - origin.x, y: baseY + height / 2 - origin.y)
    }

    private func tableCenter(_ table: SeatingTable, origin: CGPoint) -> CGPoint {
        center(id: table.id, baseX: table.positionX ?? 80, baseY: table.positionY ?? 80,
               width: table.width, height: table.height, origin: origin)
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

    /// Drag-to-move for the *selected* item. Selection (a tap) is what arms the
    /// move, so this is a plain one-finger drag — immediate and direct, no hold.
    /// Unselected items carry no drag gesture, so a pan over them scrolls the
    /// canvas instead and a move is never accidental. Fires a light haptic each
    /// time the item snaps onto an alignment guide.
    private func moveGesture(id: String, kind: ItemKind,
                             baseX: Double, baseY: Double,
                             width: Double, height: Double, rotation: Double,
                             commit: @escaping (CGPoint) -> Void,
                             tapFallback: @escaping () -> Void) -> some Gesture {
        // The gesture reports in unscaled canvas units (it lives inside
        // `.scaleEffect`), so screen-point thresholds are divided by zoom —
        // otherwise pickup would need a 2pt move at min zoom and a 25pt one
        // fully zoomed in. 4 screen points engages the move early enough that
        // the item never visibly pops to catch up with the finger.
        let z = max(0.01, effectiveZoom)
        return DragGesture(minimumDistance: 4 / z)
            .onChanged { value in
                if activeRotation != nil { dragSuppressedByTwist = true }
                guard !dragSuppressedByTwist else {
                    activeDrag = nil
                    return
                }
                var d = resolveDrag(id: id, kind: kind, baseX: baseX, baseY: baseY,
                                    width: width, height: height, rotation: rotation,
                                    translation: value.translation)
                d.startedAt = activeDrag?.startedAt ?? value.time
                noteSnapHaptic(d.guides)
                activeDrag = d
            }
            .onEnded { value in
                defer { lastGuideSig = "" }
                if activeRotation != nil { dragSuppressedByTwist = true }
                guard !dragSuppressedByTwist, let drag = activeDrag else {
                    dragSuppressedByTwist = false
                    activeDrag = nil
                    return
                }
                // A short, tiny drag is a sloppy tap, not a move — honor the
                // tap so opening an item never demands a perfectly still finger.
                let screenDistance = hypot(value.translation.width, value.translation.height) * z
                if screenDistance < 8, value.time.timeIntervalSince(drag.startedAt) < 0.3 {
                    activeDrag = nil
                    tapFallback()
                    return
                }
                // Commit the new position and drop the drag together, in one render
                // pass, so the item never flashes back to its old spot.
                let d = resolveDrag(id: id, kind: kind, baseX: baseX, baseY: baseY,
                                    width: width, height: height, rotation: rotation,
                                    translation: value.translation)
                commit(CGPoint(x: d.topLeft.x, y: d.topLeft.y))
                activeDrag = nil
            }
    }

    /// Bumps `snapTick` (driving a light haptic) the moment a drag engages a new
    /// set of alignment guides — i.e. when the item visibly snaps into line.
    private func noteSnapHaptic(_ guides: [FloorPlanGeometry.Guide]) {
        let sig = guides.map { "\($0.axis)|\(Int($0.position))" }.sorted().joined(separator: ",")
        guard sig != lastGuideSig else { return }
        if !guides.isEmpty { snapTick &+= 1 }
        lastGuideSig = sig
    }

    private func dragGesture(forTable table: SeatingTable) -> some Gesture {
        moveGesture(id: table.id, kind: .table,
                    baseX: table.positionX ?? 80, baseY: table.positionY ?? 80,
                    width: table.width, height: table.height, rotation: table.rotationDegrees,
                    commit: { p in store.updatePosition(of: table, x: p.x, y: p.y) },
                    tapFallback: { handleTableTap(table) })
    }

    private func dragGesture(forShape shape: DecorShape) -> some Gesture {
        moveGesture(id: shape.id, kind: .shape,
                    baseX: shape.positionX ?? 120, baseY: shape.positionY ?? 120,
                    width: shape.width, height: shape.height, rotation: shape.rotationDegrees,
                    commit: { p in store.updateShapePosition(of: shape, x: p.x, y: p.y) },
                    tapFallback: { handleShapeTap(shape) })
    }

    private func dragGesture(forRoom room: FloorPlanRoom) -> some Gesture {
        moveGesture(id: room.id, kind: .room,
                    baseX: room.positionX, baseY: room.positionY,
                    width: room.widthPoints, height: room.heightPoints, rotation: 0,
                    commit: { p in store.updateRoomPosition(of: room, x: p.x, y: p.y) },
                    tapFallback: { handleRoomTap(room) })
    }

    // MARK: - Two-finger rotate (tables + shapes)

    /// Twist only works on the selected item (same arming rule as drag), and
    /// only where rotation means anything — a circle spun 40° looks identical.
    private func canTwist(_ table: SeatingTable) -> Bool {
        canMove(table.id) && !table.isRound
    }

    private func canTwist(_ shape: DecorShape) -> Bool {
        canMove(shape.id) && (shape.type == .square || shape.type == .rectangle)
    }

    /// Soft detents every 15°: within 4° of one, the angle locks onto it (and a
    /// click haptic fires via `rotateSnapTick`); otherwise the twist is free.
    private func detentAngle(_ raw: Double) -> (degrees: Double, detent: Double?) {
        let nearest = (raw / 15).rounded() * 15
        return abs(raw - nearest) <= 4 ? (nearest, nearest) : (raw, nil)
    }

    /// Two-finger twist on the selected item: rotates live from the item's
    /// committed angle, clicks onto 15° detents, and commits like a drag —
    /// synchronously, so the item never flashes back to its old angle.
    private func twistGesture(id: String, base: Double,
                              commit: @escaping (Double) -> Void) -> some Gesture {
        RotateGesture()
            .onChanged { value in
                let resolved = detentAngle(base + value.rotation.degrees)
                if let detent = resolved.detent, detent != activeRotation?.detent {
                    rotateSnapTick &+= 1
                }
                activeRotation = ActiveRotation(id: id, degrees: resolved.degrees,
                                                detent: resolved.detent)
            }
            .onEnded { value in
                let resolved = detentAngle(base + value.rotation.degrees)
                commit(resolved.degrees)
                activeRotation = nil
            }
    }

    private func twistGesture(forTable table: SeatingTable) -> some Gesture {
        twistGesture(id: table.id, base: table.rotationDegrees) { degrees in
            store.commitRotation(of: table, to: degrees)
        }
    }

    private func twistGesture(forShape shape: DecorShape) -> some Gesture {
        twistGesture(id: shape.id, base: shape.rotationDegrees) { degrees in
            store.commitShapeRotation(of: shape, to: degrees)
        }
    }

    // MARK: - Rotate handle (web-canvas parity)

    /// Names the unscaled canvas space so the handle's drag can do its angle
    /// math in the same coordinates the items are positioned in.
    private static let canvasSpace = "floorPlanCanvas"

    /// The visible rotate affordance from the web canvas: a stem + knob rising
    /// from the selected item's top edge. Dragging the knob spins the item
    /// about its center, sharing the twist gesture's live state, 15° detents,
    /// and synchronous commit. Hidden while the item itself is being dragged.
    @ViewBuilder
    private func rotationHandleOverlay(origin: CGPoint) -> some View {
        if canEdit, !isAssigning, activeDrag == nil, let item = selectedCanvasItem {
            switch item {
            case .table(let t) where !t.isRound:
                rotationHandle(id: t.id,
                               center: tableCenter(t, origin: origin),
                               size: CGSize(width: t.width, height: t.height),
                               base: t.rotationDegrees) { store.commitRotation(of: t, to: $0) }
            case .shape(let s) where s.type == .square || s.type == .rectangle:
                rotationHandle(id: s.id,
                               center: center(id: s.id,
                                              baseX: s.positionX ?? 120, baseY: s.positionY ?? 120,
                                              width: s.width, height: s.height,
                                              origin: origin),
                               size: CGSize(width: s.width, height: s.height),
                               base: s.rotationDegrees) { store.commitShapeRotation(of: s, to: $0) }
            default:
                EmptyView()
            }
        }
    }

    private func rotationHandle(id: String, center: CGPoint, size: CGSize,
                                base: Double, commit: @escaping (Double) -> Void) -> some View {
        let live = activeRotation?.id == id ? (activeRotation?.degrees ?? base) : base
        let clearance: CGFloat = 32     // clears the chair ring around the body
        let stemLength: CGFloat = 18
        let knob: CGFloat = 16
        let stemBase = size.height / 2 + clearance

        return ZStack {
            // Stem rising from just past the chair ring up to the knob.
            Rectangle()
                .fill(Brand.accent)
                .frame(width: 1.5, height: stemLength)
                .offset(y: -(stemBase + stemLength / 2))
                .allowsHitTesting(false)

            // The knob — small to look at, generous to grab.
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Brand.card)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Brand.accent, lineWidth: 2))
                .frame(width: knob, height: knob)
                .contentShape(Circle().scale(2.8))
                .offset(y: -(stemBase + stemLength + knob / 2))
                .gesture(knobDrag(id: id, center: center, commit: commit))
        }
        .rotationEffect(.degrees(live))
        .position(center)
        // VoiceOver rotates via the rotation stepper in the item's edit sheet.
        .accessibilityHidden(true)
    }

    /// Dragging the knob: the item's angle follows the finger's bearing from
    /// the item center (the knob rides at "up", hence the +90°).
    private func knobDrag(id: String, center: CGPoint,
                          commit: @escaping (Double) -> Void) -> some Gesture {
        DragGesture(coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                let resolved = detentAngle(knobAngle(value.location, around: center))
                if let detent = resolved.detent, detent != activeRotation?.detent {
                    rotateSnapTick &+= 1
                }
                activeRotation = ActiveRotation(id: id, degrees: resolved.degrees,
                                                detent: resolved.detent)
            }
            .onEnded { value in
                let resolved = detentAngle(knobAngle(value.location, around: center))
                commit(resolved.degrees)
                activeRotation = nil
            }
    }

    private func knobAngle(_ location: CGPoint, around center: CGPoint) -> Double {
        Angle(radians: atan2(location.y - center.y, location.x - center.x)).degrees + 90
    }
}

private extension View {
    /// The "selected / moving" look for a floor-plan item: a gentle lift with a
    /// soft shadow, floated above its neighbors. Grows a touch more while actively
    /// dragging so the held item reads as picked up.
    func floorPlanSelected(_ selected: Bool, dragging: Bool) -> some View {
        let active = selected || dragging
        return scaleEffect(dragging ? 1.06 : (selected ? 1.03 : 1), anchor: .center)
            .shadow(color: .black.opacity(active ? 0.22 : 0),
                    radius: active ? 16 : 0, x: 0, y: active ? 10 : 0)
            .zIndex(active ? 1 : 0)
            .animation(.snappy(duration: 0.18), value: active)
            .animation(.snappy(duration: 0.12), value: dragging)
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
    /// True while a two-finger twist is driving the angle — the rotation must
    /// track the fingers 1:1, so the settle animation is suppressed.
    var liveRotating: Bool = false

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
        .animation(liveRotating ? nil : .snappy(duration: 0.25), value: table.rotationDegrees)
        .frame(width: side, height: side)
        .opacity(assigning && isFull ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(assigning
                           ? (isFull ? "Full — no open seats" : "Double tap to seat the guest here")
                           : "Double tap to select")
    }

    private var accessibilityText: String {
        guard capacity > 0 else { return "\(table.name), \(occupancy) seated" }
        return "\(table.name), \(occupancy) of \(capacity) seated"
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
    var isSelected: Bool = false

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let fill = scheme == .dark ? Color.white.opacity(0.03) : Color.hex(room.colorHex).opacity(0.5)
        let stroke = isSelected ? Brand.accent
                                : (scheme == .dark ? Color.white.opacity(0.4) : Brand.slate500.opacity(0.55))
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(stroke, style: StrokeStyle(lineWidth: isSelected ? 3 : 2,
                                                         dash: isSelected ? [] : [10, 6])))
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
    var isSelected: Bool = false
    /// True while a two-finger twist is driving the angle (see TableNodeView).
    var liveRotating: Bool = false

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            body(for: shape.type)
                .frame(width: shape.width, height: shape.height)
                .rotationEffect(.degrees(shape.rotationDegrees))
                .animation(liveRotating ? nil : .snappy(duration: 0.25), value: shape.rotationDegrees)
            Text(shape.name)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Brand.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(shape.name), decoration")
    }

    @ViewBuilder
    private func body(for type: TableShape) -> some View {
        let fill = scheme == .dark ? Color.hex("#11203A") : Brand.slate100
        let stroke = isColliding ? Brand.collisionStroke
                                 : isSelected ? Brand.accent
                                 : (scheme == .dark ? Color.white.opacity(0.45) : Brand.slate400)
        let lineWidth: CGFloat = (isColliding || isSelected) ? 3 : 1.5
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
/// Equatable so callers can attach `.equatable()`: the canvas spans the whole
/// (large) content rect and fills tens of thousands of dots, which must render
/// once — not on every drag/pinch frame of the floor plan.
struct DotGrid: View, Equatable {
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
