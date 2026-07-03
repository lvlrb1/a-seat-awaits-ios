//
//  AddRoomView.swift
//  A Seat Awaits
//
//  The room form, used to create and edit a floor-plan room — a labelled
//  boundary (banquet hall, tent, patio) drawn behind the tables to anchor the
//  layout in real space. Size is entered in feet; a small palette tints the
//  room's wash so multiple rooms read apart at a glance.
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
    @State private var color: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmingDelete = false

    /// Soft washes that read as room tints (light enough for labels on top).
    private static let palette = ["#E5E7EB", "#EDE3F3", "#FCE7F3", "#FEF3C7",
                                  "#DCFCE7", "#DBEAFE", "#CCFBF1"]

    init(store: SeatingStore, editing: FloorPlanRoom? = nil) {
        self.store = store
        self.editing = editing
        if let r = editing {
            _name = State(initialValue: r.name)
            _widthFt = State(initialValue: r.widthFt)
            _heightFt = State(initialValue: r.heightFt)
            _color = State(initialValue: r.colorHex)
        } else {
            _name = State(initialValue: "Main Room")
            _widthFt = State(initialValue: 50)
            _heightFt = State(initialValue: 80)
            _color = State(initialValue: Self.palette[0])
        }
    }

    private var isEditing: Bool { editing != nil }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                detailsSection
                sizeSection
                colorSection
                if let errorMessage { errorSection(errorMessage) }
                if isEditing { deleteSection }
            }
            .navigationTitle(isEditing ? "Edit Room" : "Add Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") { Task { await save() } }
                        .disabled(isSaving || !canSave)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .confirmationDialog("Delete \(name)?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete room", role: .destructive) {
                    if let editing { Task { await store.deleteRoom(editing); dismiss() } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Tables stay put — only the room boundary is removed.")
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
                .font(.system(size: 13))
                .foregroundStyle(Brand.textSecondary)
        }
    }

    private var colorSection: some View {
        Section("Color") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Self.palette, id: \.self) { hex in
                        swatch(hex)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private func swatch(_ hex: String) -> some View {
        let selected = color.caseInsensitiveCompare(hex) == .orderedSame
        return Button { color = hex } label: {
            Circle()
                .fill(Color.hex(hex))
                .frame(width: 36, height: 36)
                .overlay(Circle().strokeBorder(Brand.slate300, lineWidth: 1))
                .overlay {
                    if selected {
                        Circle().strokeBorder(Brand.accent, lineWidth: 3)
                            .padding(-3)
                    }
                }
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(Brand.ink)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Room color \(hex)")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                                                 widthFt: w, heightFt: h, color: color)
            if updated != nil {
                dismiss()
            } else {
                errorMessage = store.errorMessage ?? "Couldn't save changes."
                store.errorMessage = nil
            }
        } else {
            // Stagger new rooms a little so they don't stack exactly.
            let offset = Double(store.rooms.count % 4) * 24
            do {
                try await store.addRoom(name: finalName, widthFt: w, heightFt: h,
                                        positionX: 40 + offset, positionY: 40 + offset,
                                        color: color)
                dismiss()
            } catch {
                errorMessage = FriendlyError.message(for: error)
            }
        }
    }
}
