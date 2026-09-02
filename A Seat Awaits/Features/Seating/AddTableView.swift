//
//  AddTableView.swift
//  A Seat Awaits
//
//  The table form, used to both create and edit a table. A preset picker mirrors
//  the web's standard banquet types; choosing "Custom" reveals width/length in
//  feet. Non-round tables gain a 15°-snapping rotation control, and editing warns
//  when the new capacity falls below the guests already seated.
//

import SwiftUI

struct AddTableView: View {
    @Bindable var store: SeatingStore
    @Environment(\.dismiss) private var dismiss

    /// When non-nil the form edits this table; otherwise it creates a new one.
    private let editing: SeatingTable?

    @State private var name: String
    @State private var shape: TableShape
    @State private var capacity: Int
    @State private var widthFt: Double
    @State private var lengthFt: Double
    @State private var note: String
    @State private var rotation: Double
    /// Set when the planner explicitly chose "Custom" even though the current
    /// dimensions happen to match a preset. The selected preset is otherwise
    /// derived from the live shape/capacity/size so it can never drift.
    @State private var forceCustom: Bool
    @State private var didSetDefaultName = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// The form's values when it opened; anything different means the planner
    /// has typed something worth protecting from an accidental swipe-down.
    @State private var initialSignature = ""
    @FocusState private var numericFocused: Bool

    /// Where the canvas would like a new table centered (its viewport middle,
    /// in canvas coordinates). Nil when opened from somewhere without a canvas.
    private let suggestedPosition: CGPoint?
    /// Called with the freshly-created table so the canvas can select it and
    /// scroll it into view.
    private let onCreated: ((SeatingTable) -> Void)?

    init(store: SeatingStore,
         editing: SeatingTable? = nil,
         suggestedPosition: CGPoint? = nil,
         onCreated: ((SeatingTable) -> Void)? = nil) {
        self.store = store
        self.editing = editing
        self.suggestedPosition = suggestedPosition
        self.onCreated = onCreated
        if let t = editing {
            _name = State(initialValue: t.name)
            _shape = State(initialValue: t.shape ?? .circle)
            _capacity = State(initialValue: t.capacity ?? 0)
            _widthFt = State(initialValue: t.widthFeet)
            _lengthFt = State(initialValue: t.heightFeet)
            _note = State(initialValue: t.description ?? "")
            _rotation = State(initialValue: t.rotationDegrees)
            _forceCustom = State(initialValue: t.matchingPreset == nil)
        } else {
            let preset = TablePreset.all.first { $0.id == "round-60in" } ?? TablePreset.all[0]
            _name = State(initialValue: "")
            _shape = State(initialValue: preset.shape)
            _capacity = State(initialValue: preset.capacity)
            _widthFt = State(initialValue: TableScale.toFeet(points: preset.width))
            _lengthFt = State(initialValue: TableScale.toFeet(points: preset.height))
            _note = State(initialValue: "")
            _rotation = State(initialValue: 0)
            _forceCustom = State(initialValue: false)
        }
    }

    private var isEditing: Bool { editing != nil }
    private var isRound: Bool { shape == .circle || shape == .oval }
    /// Round + square tables size from a single dimension (length follows width).
    private var usesSingleDimension: Bool { shape == .circle || shape == .square }

    /// The preset matching the live shape/capacity/size, if any.
    private var currentPresetID: String? {
        let heightFt = usesSingleDimension ? widthFt : lengthFt
        return TablePreset.all.first {
            $0.shape == shape && $0.capacity == capacity &&
            abs(TableScale.feet(widthFt) - $0.width) < 0.5 &&
            abs(TableScale.feet(heightFt) - $0.height) < 0.5
        }?.id
    }

    /// The currently highlighted preset (nil == custom).
    private var selectedPresetID: String? { forceCustom ? nil : currentPresetID }

    private var seatedCount: Int {
        guard let editing else { return 0 }
        return store.guests.filter { $0.tableId == editing.id }.count
    }
    private var lowersBelowSeated: Bool { isEditing && capacity < seatedCount }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    private var signature: String {
        "\(name)|\(shape.rawValue)|\(capacity)|\(widthFt)|\(lengthFt)|\(note)|\(rotation)|\(forceCustom)"
    }
    private var isDirty: Bool { !initialSignature.isEmpty && signature != initialSignature }

    var body: some View {
        NavigationStack {
            Form {
                presetSection
                detailsSection
                sizeSection
                if !isRound { rotationSection }
                if lowersBelowSeated { capacityWarningSection }
                if let errorMessage { errorSection(errorMessage) }
            }
            .navigationTitle(isEditing ? "Edit Table" : "Add Table")
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
            .onAppear {
                if !isEditing && name.isEmpty && !didSetDefaultName {
                    name = "Table \(store.tables.count + 1)"
                    didSetDefaultName = true
                }
                if initialSignature.isEmpty { initialSignature = signature }
            }
        }
        // Match the table detail/assign sheets: full-height page sheet on iPad
        // instead of the small centered form-sheet card.
        .presentationSizing(.page)
    }

    // MARK: - Sections

    private var presetSection: some View {
        Section("Table type") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(TablePreset.all) { preset in
                        presetChip(preset)
                    }
                    customChip
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            TextField("Name (e.g. Table 1, Head Table)", text: $name)
            TextField("Description (optional)", text: $note, axis: .vertical)
                .lineLimit(1...4)
        }
    }

    private var sizeSection: some View {
        Section("Shape & seats") {
            Picker("Shape", selection: $shape) {
                ForEach(TableShape.allCases) { s in
                    Label(s.label, systemImage: s.systemImage).tag(s)
                }
            }

            Stepper("Seats: \(capacity)", value: $capacity, in: 1...30)

            if usesSingleDimension {
                dimensionField(shape == .circle ? "Diameter (ft)" : "Side (ft)", value: $widthFt)
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

    private var capacityWarningSection: some View {
        Section {
            Label("This table already has \(seatedCount) guest\(seatedCount == 1 ? "" : "s") seated, which is more than the \(capacity) seats you've set. No one will be unseated, but the table will show as over capacity.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Brand.warningText)
                .font(.footnote)
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(Brand.danger)
                .font(.footnote)
        }
    }

    // MARK: - Building blocks

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

    private func presetChip(_ preset: TablePreset) -> some View {
        let selected = selectedPresetID == preset.id
        return Button {
            applyPreset(preset)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: preset.shape.systemImage)
                    .scaledFont(size: 19, weight: .semibold)
                Text(preset.label)
                    .scaledFont(size: 12, weight: .bold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("\(preset.capacity) seats")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(selected ? Brand.accent : Brand.textSecondary)
            }
            .frame(width: 96, height: 84)
            .foregroundStyle(selected ? Brand.accent : Brand.textPrimary)
            .background(selected ? Brand.accent.opacity(0.12) : Brand.control,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Brand.accent : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.label), \(preset.capacity) seats")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var customChip: some View {
        let selected = selectedPresetID == nil
        return Button {
            forceCustom = true
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                    .scaledFont(size: 19, weight: .semibold)
                Text("Custom")
                    .scaledFont(size: 12, weight: .bold)
                Text("Any size")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(selected ? Brand.accent : Brand.textSecondary)
            }
            .frame(width: 96, height: 84)
            .foregroundStyle(selected ? Brand.accent : Brand.textPrimary)
            .background(selected ? Brand.accent.opacity(0.12) : Brand.control,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: selected ? 2 : 1.5,
                                                 dash: selected ? [] : [4, 4]))
                .foregroundStyle(selected ? Brand.accent : Brand.fieldBorder))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Custom size")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - State transitions

    private func applyPreset(_ preset: TablePreset) {
        shape = preset.shape
        capacity = preset.capacity
        widthFt = TableScale.toFeet(points: preset.width)
        lengthFt = TableScale.toFeet(points: preset.height)
        forceCustom = false
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmed.isEmpty ? "Table" : trimmed
        let widthPx = TableScale.feet(max(0.5, widthFt))
        let heightPx = TableScale.feet(max(0.5, usesSingleDimension ? widthFt : lengthFt))
        let finalRotation = isRound ? 0 : rotation
        let isCustom = selectedPresetID == nil
        let description = note.nilIfBlank

        if let editing {
            let updated = await store.updateTable(editing,
                                                  name: finalName,
                                                  capacity: capacity,
                                                  shape: shape,
                                                  width: widthPx,
                                                  height: heightPx,
                                                  description: description,
                                                  rotation: finalRotation,
                                                  isCustom: isCustom)
            if updated != nil {
                dismiss()
            } else {
                errorMessage = store.errorMessage ?? "Couldn't save changes."
                store.errorMessage = nil
            }
        } else {
            // Land the table where the planner is looking (the canvas passes
            // its viewport center), nudged to the nearest clear spot so new
            // tables never stack on top of each other or off-screen.
            let anchor = suggestedPosition.map { (x: Double($0.x), y: Double($0.y)) }
                ?? store.defaultPlacementAnchor
            let spot = FloorPlanGeometry.freePosition(near: anchor,
                                                      size: (widthPx, heightPx),
                                                      among: store.placementObstacles)
            do {
                let created = try await store.addTable(name: finalName,
                                                       shape: shape,
                                                       capacity: capacity,
                                                       width: widthPx,
                                                       height: heightPx,
                                                       positionX: spot.x,
                                                       positionY: spot.y,
                                                       description: description,
                                                       rotation: finalRotation,
                                                       isCustom: isCustom)
                dismiss()
                onCreated?(created)
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
        }
    }
}
