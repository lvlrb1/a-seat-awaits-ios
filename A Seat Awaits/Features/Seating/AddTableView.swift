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

    init(store: SeatingStore, editing: SeatingTable? = nil) {
        self.store = store
        self.editing = editing
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
                    Button(isEditing ? "Save" : "Add") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onAppear {
                if !isEditing && name.isEmpty && !didSetDefaultName {
                    name = "Table \(store.tables.count + 1)"
                    didSetDefaultName = true
                }
            }
        }
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
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
            }
            .accessibilityLabel("Rotation")
            .accessibilityValue("\(Int(rotation)) degrees")
        }
    }

    private var capacityWarningSection: some View {
        Section {
            Label("\(seatedCount) guest\(seatedCount == 1 ? "" : "s") seated here exceed the new capacity of \(capacity). They'll stay seated, but the table will show as over capacity.",
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
                    .font(.system(size: 19, weight: .semibold))
                Text(preset.label)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("\(preset.capacity) seats")
                    .font(.system(size: 11, weight: .medium))
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
                    .font(.system(size: 19, weight: .semibold))
                Text("Custom")
                    .font(.system(size: 12, weight: .bold))
                Text("Any size")
                    .font(.system(size: 11, weight: .medium))
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
            // Stagger new tables so they don't stack exactly on top of each other.
            let offset = Double(store.tables.count % 4) * 30
            do {
                try await store.addTable(name: finalName,
                                         shape: shape,
                                         capacity: capacity,
                                         width: widthPx,
                                         height: heightPx,
                                         positionX: 60 + offset,
                                         positionY: 80 + offset,
                                         description: description,
                                         rotation: finalRotation,
                                         isCustom: isCustom)
                dismiss()
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
        }
    }
}
