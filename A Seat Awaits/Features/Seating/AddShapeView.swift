//
//  AddShapeView.swift
//  A Seat Awaits
//
//  The decorative-object form, used to create and edit a "shape" — a stage,
//  dance floor, bar, gift table, and the like. Shapes carry no seats; they give
//  the floor plan landmarks. Size is entered in feet (24pt = 1ft) and round
//  shapes drop their rotation control, mirroring the table form's conventions.
//

import SwiftUI

struct AddShapeView: View {
    @Bindable var store: SeatingStore
    @Environment(\.dismiss) private var dismiss

    /// When non-nil the form edits this shape; otherwise it creates a new one.
    private let editing: DecorShape?

    @State private var name: String
    @State private var type: TableShape
    @State private var widthFt: Double
    @State private var lengthFt: Double
    @State private var rotation: Double
    @State private var note: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmingDelete = false
    @State private var initialSignature = ""
    @FocusState private var numericFocused: Bool

    /// Where the canvas would like a new shape centered (see AddTableView).
    private let suggestedPosition: CGPoint?
    /// Called with the freshly-created shape so the canvas can select it.
    private let onCreated: ((DecorShape) -> Void)?

    /// A few common landmarks to seed the name quickly.
    private let nameSuggestions = ["Dance Floor", "Stage", "Bar", "DJ Booth",
                                   "Gift Table", "Cake Table", "Buffet", "Entrance"]

    init(store: SeatingStore,
         editing: DecorShape? = nil,
         suggestedPosition: CGPoint? = nil,
         onCreated: ((DecorShape) -> Void)? = nil) {
        self.store = store
        self.editing = editing
        self.suggestedPosition = suggestedPosition
        self.onCreated = onCreated
        if let s = editing {
            _name = State(initialValue: s.name)
            _type = State(initialValue: s.type)
            _widthFt = State(initialValue: TableScale.toFeet(points: s.width))
            _lengthFt = State(initialValue: TableScale.toFeet(points: s.height))
            _rotation = State(initialValue: s.rotationDegrees)
            _note = State(initialValue: s.description ?? "")
        } else {
            let size = DecorShape.defaultSize(for: .rectangle)
            _name = State(initialValue: "")
            _type = State(initialValue: .rectangle)
            _widthFt = State(initialValue: TableScale.toFeet(points: size.width))
            _lengthFt = State(initialValue: TableScale.toFeet(points: size.height))
            _rotation = State(initialValue: 0)
            _note = State(initialValue: "")
        }
    }

    private var isEditing: Bool { editing != nil }
    private var isRound: Bool { type == .circle || type == .oval }
    /// Circle/square size from a single dimension (length follows width).
    private var usesSingleDimension: Bool { type == .circle || type == .square }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    private var signature: String {
        "\(name)|\(type.rawValue)|\(widthFt)|\(lengthFt)|\(rotation)|\(note)"
    }
    private var isDirty: Bool { !initialSignature.isEmpty && signature != initialSignature }

    var body: some View {
        NavigationStack {
            Form {
                detailsSection
                if !isEditing { suggestionsSection }
                sizeSection
                if !isRound { rotationSection }
                if let errorMessage { errorSection(errorMessage) }
                if isEditing { manageSection }
            }
            .navigationTitle(isEditing ? "Edit Shape" : "Add Shape")
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
                Button("Delete Shape", role: .destructive) {
                    if let editing { Task { await store.deleteShapeWithUndo(editing); dismiss() } }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var manageSection: some View {
        Section {
            Button {
                if let editing { Task { await store.duplicateShape(editing); dismiss() } }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .disabled(isSaving)
            Button(role: .destructive) { confirmingDelete = true } label: {
                Label("Delete shape", systemImage: "trash")
            }
            .disabled(isSaving)
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            TextField("Name (e.g. Dance Floor, Stage)", text: $name)
            Picker("Shape", selection: $type) {
                ForEach(TableShape.allCases) { s in
                    Label(s.label, systemImage: s.systemImage).tag(s)
                }
            }
            .onChange(of: type) { _, newValue in
                // Re-seed the size from the type's default while creating, so a
                // wide rectangle and a square pick sensible footprints.
                guard !isEditing else { return }
                let size = DecorShape.defaultSize(for: newValue)
                widthFt = TableScale.toFeet(points: size.width)
                lengthFt = TableScale.toFeet(points: size.height)
            }
            TextField("Description (optional)", text: $note, axis: .vertical)
                .lineLimit(1...4)
        }
    }

    private var suggestionsSection: some View {
        Section("Quick names") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(nameSuggestions, id: \.self) { suggestion in
                        Button { name = suggestion } label: {
                            Text(suggestion)
                                .scaledFont(size: 13, weight: .bold)
                                .foregroundStyle(Brand.accent)
                                .padding(.horizontal, 13)
                                .frame(height: 34)
                                .background(Brand.accent.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private var sizeSection: some View {
        Section("Size") {
            if usesSingleDimension {
                dimensionField(type == .circle ? "Diameter (ft)" : "Side (ft)", value: $widthFt)
            } else {
                dimensionField("Width (ft)", value: $widthFt)
                dimensionField("Length (ft)", value: $lengthFt)
            }
        }
    }

    private var rotationSection: some View {
        Section("Rotation") {
            Stepper(value: $rotation, in: 0...345, step: 15) {
                Text("\(Int(rotation))°")
                    .scaledFont(size: 16, weight: .semibold)
                    .monospacedDigit()
            }
            .accessibilityLabel("Rotation")
            .accessibilityValue("\(Int(rotation)) degrees")
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
        let widthPx = TableScale.feet(max(0.5, widthFt))
        let heightPx = TableScale.feet(max(0.5, usesSingleDimension ? widthFt : lengthFt))
        let description = note.nilIfBlank

        if let editing {
            let updated = await store.updateShape(editing, name: finalName, type: type,
                                                  width: widthPx, height: heightPx,
                                                  description: description)
            // Rotation lives on its own patch; persist it if the user changed it.
            if updated != nil && !isRound && rotation != editing.rotationDegrees {
                await store.updateShapeRotation(of: editing, to: rotation)
            }
            if updated != nil {
                dismiss()
            } else {
                errorMessage = store.errorMessage ?? "Couldn't save changes."
                store.errorMessage = nil
            }
        } else {
            // Land the shape where the planner is looking, on the nearest
            // clear spot (see AddTableView).
            let anchor = suggestedPosition.map { (x: Double($0.x), y: Double($0.y)) }
                ?? store.defaultPlacementAnchor
            let spot = FloorPlanGeometry.freePosition(near: anchor,
                                                      size: (widthPx, heightPx),
                                                      among: store.placementObstacles)
            do {
                let created = try await store.addShape(name: finalName, type: type,
                                                       width: widthPx, height: heightPx,
                                                       positionX: spot.x, positionY: spot.y,
                                                       description: description)
                if !isRound && rotation != 0 {
                    await store.updateShapeRotation(of: created, to: rotation)
                }
                dismiss()
                onCreated?(created)
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
        }
    }
}
