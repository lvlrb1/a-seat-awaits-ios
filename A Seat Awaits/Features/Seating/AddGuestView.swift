//
//  AddGuestView.swift
//  A Seat Awaits
//

import SwiftUI

struct AddGuestView: View {
    @Bindable var store: SeatingStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selectedGroupId: String?
    @State private var customGroupName = ""
    @State private var dietary = ""
    @State private var notes = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Guest") {
                    TextField("Full name", text: $name)
                        .textContentType(.name)
                }
                Section("Group") {
                    if !store.groups.isEmpty {
                        Picker("Group", selection: $selectedGroupId) {
                            Text("None").tag(String?.none)
                            ForEach(store.groups) { group in
                                Text(group.name).tag(String?.some(group.id))
                            }
                        }
                    }
                    TextField("Or type a group name", text: $customGroupName)
                }
                Section("Details") {
                    TextField("Dietary preference", text: $dietary)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(Brand.danger).font(.footnote)
                    }
                }
            }
            .navigationTitle("Add Guest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func resolvedGroupName() -> String? {
        if let custom = customGroupName.nilIfBlank { return custom }
        if let id = selectedGroupId { return store.groups.first { $0.id == id }?.name }
        return nil
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await store.addGuest(
                name: name.trimmingCharacters(in: .whitespaces),
                groupId: customGroupName.nilIfBlank == nil ? selectedGroupId : nil,
                groupName: resolvedGroupName(),
                notes: notes,
                dietary: dietary
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
