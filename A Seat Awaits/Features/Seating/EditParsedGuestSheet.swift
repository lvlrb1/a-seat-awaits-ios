//
//  EditParsedGuestSheet.swift
//  A Seat Awaits
//
//  Inline editor for a single parsed import row (F5). Lets the planner fix a
//  misread name, set the household and dietary note, and resolve a "+1" by
//  naming the companion (which splits it into its own guest) before importing.
//  Uses a native Form so it inherits Dynamic Type and familiar editing chrome.
//

import SwiftUI

struct EditParsedGuestSheet: View {
    let row: ReviewRow
    /// Called on Save with the edited guest and, if provided, a companion name to
    /// split off into a second guest.
    var onSave: (ParsedGuest, String?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var household: String
    @State private var dietary: String
    @State private var companion: String

    private let hasPlusOne: Bool
    private let plusOneLabel: String

    init(row: ReviewRow, onSave: @escaping (ParsedGuest, String?) -> Void) {
        self.row = row
        self.onSave = onSave
        _name = State(initialValue: row.guest.name)
        _household = State(initialValue: row.guest.group ?? "")
        _dietary = State(initialValue: row.guest.dietary ?? "")
        _companion = State(initialValue: "")
        self.hasPlusOne = row.guest.plusOneHint != nil
        let hint = row.guest.plusOneHint?.lowercased() ?? ""
        if hint.contains("partner") { plusOneLabel = "Partner's name" }
        else if hint.contains("guest") { plusOneLabel = "Guest's name" }
        else { plusOneLabel = "Plus-one's name" }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Guest") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Household (optional)", text: $household)
                        .textInputAutocapitalization(.words)
                    TextField("Dietary note (optional)", text: $dietary)
                }

                if hasPlusOne {
                    Section {
                        TextField(plusOneLabel, text: $companion)
                            .textInputAutocapitalization(.words)
                    } header: {
                        Text("Plus-one")
                    } footer: {
                        Text("Name them to add a second guest in the same household, or leave blank to keep \"\(row.guest.plusOneHint ?? "")\" as a note.")
                    }
                }
            }
            .navigationTitle("Edit guest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        var edited = row.guest
        edited.name = GuestImportParser.titleCasedName(name.trimmingCharacters(in: .whitespacesAndNewlines))
        edited.group = household.nilIfBlank
        edited.dietary = dietary.nilIfBlank
        let companionName = companion.nilIfBlank
        onSave(edited, companionName)
        dismiss()
    }
}
