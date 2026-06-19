//
//  AddTableView.swift
//  A Seat Awaits
//

import SwiftUI

struct AddTableView: View {
    @Bindable var store: SeatingStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var shape: TableShape = .circle
    @State private var capacity = 8
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Table") {
                    TextField("Name (e.g. Table 1, Head Table)", text: $name)
                    Picker("Shape", selection: $shape) {
                        ForEach(TableShape.allCases) { shape in
                            Label(shape.label, systemImage: shape.systemImage).tag(shape)
                        }
                    }
                    Stepper("Seats: \(capacity)", value: $capacity, in: 1...30)
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(Brand.danger).font(.footnote)
                    }
                }
            }
            .navigationTitle("Add Table")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onAppear {
                if name.isEmpty { name = "Table \(store.tables.count + 1)" }
            }
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let size = Self.size(for: shape, capacity: capacity)
        // Stagger new tables so they don't stack exactly on top of each other.
        let offset = Double(store.tables.count % 4) * 30
        do {
            try await store.addTable(
                name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Table" : name,
                shape: shape,
                capacity: capacity,
                width: size.width,
                height: size.height,
                positionX: 60 + offset,
                positionY: 80 + offset
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A sensible default footprint (in canvas points) for a shape + capacity.
    static func size(for shape: TableShape, capacity: Int) -> (width: Double, height: Double) {
        let base = 70.0 + Double(max(0, capacity - 6)) * 6
        switch shape {
        case .circle, .square:
            return (base, base)
        case .rectangle:
            return (base * 1.6, base * 0.8)
        case .oval:
            return (base * 1.5, base)
        }
    }
}
