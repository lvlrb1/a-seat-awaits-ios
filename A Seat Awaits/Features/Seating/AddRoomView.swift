//
//  AddRoomView.swift
//  A Seat Awaits
//
//  The room form, used to create and edit a floor-plan room — a labelled
//  boundary (banquet hall, tent, patio) drawn behind the tables to anchor the
//  layout in real space. Size is entered in feet.
//

import SwiftUI

struct AddRoomView: View {
    @Bindable var store: SeatingStore
    @Environment(\.dismiss) private var dismiss

    /// When non-nil the form edits this room; otherwise it creates a new one.
    private let editing: FloorPlanRoom?

    @State private var name: String
    @State private var widthFt: Double
    @State private var heightFt: Double
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmingDelete = false
    @State private var initialSignature = ""
    @FocusState private var numericFocused: Bool

    /// Where the canvas would like a new room centered (see AddTableView).
    private let suggestedPosition: CGPoint?
    /// Called with the freshly-created room so the canvas can select it.
    private let onCreated: ((FloorPlanRoom) -> Void)?

    init(store: SeatingStore,
         editing: FloorPlanRoom? = nil,
         suggestedPosition: CGPoint? = nil,
         onCreated: ((FloorPlanRoom) -> Void)? = nil) {
        self.store = store
        self.editing = editing
        self.suggestedPosition = suggestedPosition
        self.onCreated = onCreated
        if let r = editing {
            _name = State(initialValue: r.name)
            _widthFt = State(initialValue: r.widthFt)
            _heightFt = State(initialValue: r.heightFt)
        } else {
            _name = State(initialValue: "Main Room")
            _widthFt = State(initialValue: 50)
            _heightFt = State(initialValue: 80)
        }
    }

    private var isEditing: Bool { editing != nil }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    private var signature: String { "\(name)|\(widthFt)|\(heightFt)" }
    private var isDirty: Bool { !initialSignature.isEmpty && signature != initialSignature }

    var body: some View {
        NavigationStack {
            Form {
                detailsSection
                sizeSection
                if let errorMessage { errorSection(errorMessage) }
                if isEditing { deleteSection }
            }
            .navigationTitle(isEditing ? "Edit Room" : "Add Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        HStack(spacing: 6) {
                            if isSaving { ProgressView().controlSize(.small) }
                            Text(isEditing ? "Save" : "Add")
                        }
                    }
                    .disabled(isSaving || !canSave)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { numericFocused = false }
                }
            }
            .interactiveDismissDisabled(isSaving || isDirty)
            .onAppear { if initialSignature.isEmpty { initialSignature = signature } }
            .confirmationDialog("Delete \(name)?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete Room", role: .destructive) {
                    if let editing { Task { await store.deleteRoomWithUndo(editing); dismiss() } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Tables stay put. Only the room boundary is removed.")
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) { confirmingDelete = true } label: {
                Label("Delete room", systemImage: "trash")
            }
            .disabled(isSaving)
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            TextField("Name (e.g. Ballroom, Tent)", text: $name)
        }
    }

    private var sizeSection: some View {
        Section("Dimensions") {
            dimensionField("Width (ft)", value: $widthFt)
            dimensionField("Length (ft)", value: $heightFt)
            Text("\(TableScale.feetLabel(widthFt)) × \(TableScale.feetLabel(heightFt)) ft")
                .scaledFont(size: 13)
                .foregroundStyle(Brand.textSecondary)
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(Brand.danger)
                .font(.footnote)
        }
    }

    private func dimensionField(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad)
                .focused($numericFocused)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let finalName = name.trimmingCharacters(in: .whitespaces)
        let w = max(1, widthFt)
        let h = max(1, heightFt)

        if let editing {
            let updated = await store.updateRoom(editing, name: finalName,
                                                 widthFt: w, heightFt: h)
            if updated != nil {
                dismiss()
            } else {
                errorMessage = store.errorMessage ?? "Couldn't save changes."
                store.errorMessage = nil
            }
        } else {
            // Center the room on what the planner is looking at, but never on
            // top of another room (a two-foot gap keeps their outlines apart).
            let size = (width: TableScale.feet(w), height: TableScale.feet(h))
            let anchor: (x: Double, y: Double)
            if let suggestedPosition {
                anchor = (Double(suggestedPosition.x), Double(suggestedPosition.y))
            } else if store.rooms.isEmpty {
                anchor = (size.width / 2, size.height / 2)
            } else {
                anchor = store.defaultPlacementAnchor
            }
            let spot = FloorPlanGeometry.freePosition(near: anchor, size: size,
                                                      among: store.roomObstacles,
                                                      clearance: 48, step: 48)
            do {
                let created = try await store.addRoom(name: finalName, widthFt: w, heightFt: h,
                                                      positionX: spot.x, positionY: spot.y)
                dismiss()
                onCreated?(created)
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
        }
    }
}
