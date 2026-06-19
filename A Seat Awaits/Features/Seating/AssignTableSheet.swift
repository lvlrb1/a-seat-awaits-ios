//
//  AssignTableSheet.swift
//  A Seat Awaits
//
//  Pick (or clear) the table a guest is seated at, with live capacity hints.
//

import SwiftUI

struct AssignTableSheet: View {
    @Bindable var store: SeatingStore
    let guest: Guest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await store.assign(guest, toTable: nil); dismiss() }
                    } label: {
                        HStack {
                            Label("Unassigned", systemImage: "person.fill.xmark")
                            Spacer()
                            if guest.tableId == nil { Image(systemName: "checkmark").foregroundStyle(Brand.plum) }
                        }
                    }
                    .foregroundStyle(.primary)
                }

                if store.tables.isEmpty {
                    Section {
                        Text("No tables yet. Add a table from the floor plan first.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Tables") {
                        ForEach(store.tables) { table in
                            tableRow(table)
                        }
                    }
                }
            }
            .navigationTitle("Seat \(guest.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func tableRow(_ table: SeatingTable) -> some View {
        let occupancy = store.occupancy(of: table)
        let capacity = table.capacity ?? 0
        let isFull = capacity > 0 && occupancy >= capacity && guest.tableId != table.id
        return Button {
            Task { await store.assign(guest, toTable: table.id); dismiss() }
        } label: {
            HStack {
                Image(systemName: (table.shape ?? .circle).systemImage)
                    .foregroundStyle(Brand.purple)
                VStack(alignment: .leading) {
                    Text(table.name)
                    if capacity > 0 {
                        Text("\(occupancy)/\(capacity) seated")
                            .font(.caption)
                            .foregroundStyle(isFull ? Brand.danger : .secondary)
                    }
                }
                Spacer()
                if guest.tableId == table.id {
                    Image(systemName: "checkmark").foregroundStyle(Brand.plum)
                } else if isFull {
                    Text("Full").font(.caption).foregroundStyle(Brand.danger)
                }
            }
        }
        .foregroundStyle(.primary)
    }
}
