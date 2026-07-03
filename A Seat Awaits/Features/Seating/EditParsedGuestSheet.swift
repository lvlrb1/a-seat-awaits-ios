//
//  EditParsedGuestSheet.swift
//  A Seat Awaits
//
//  Inline editor for a single import row (F5). Its main job is fixing a misread
//  or auto-completed name (saving confirms it). Household / dietary fields only
//  appear when the row already carries them; a "+1" can be resolved by naming the
//  companion (which splits it into its own guest). Uses a native Form so it
//  inherits Dynamic Type and familiar editing chrome.
//

import SwiftUI

struct EditParsedGuestSheet: View {
    let row: ReviewRow
    /// Called on Save with the edited guest and, if provided, a companion name to
    /// split off into a second guest.
    var onSave: (ParsedGuest, String?) -> Void
    /// Called when the planner removes this guest from the import.
    var onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var household: String
    @State private var dietary: String
    @State private var companion: String

    private let hasPlusOne: Bool
    private let plusOneLabel: String
    /// Household / dietary fields only appear when the row already carries them
    /// (the AI import is names-only; the offline parser may still fill them).
    private let showsExtras: Bool
    private let needsConfirm: Bool

    init(row: ReviewRow,
         onSave: @escaping (ParsedGuest, String?) -> Void,
         onRemove: @escaping () -> Void) {
        self.row = row
        self.onSave = onSave
        self.onRemove = onRemove
        _name = State(initialValue: row.guest.name)
        _household = State(initialValue: row.guest.group ?? "")
        _dietary = State(initialValue: row.guest.dietary ?? "")
        _companion = State(initialValue: "")
        self.hasPlusOne = row.guest.plusOneHint != nil
        self.showsExtras = row.guest.group != nil || row.guest.dietary != nil
        self.needsConfirm = row.guest.needsReview
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
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    if showsExtras {
                        TextField("Household (optional)", text: $household)
                            .textInputAutocapitalization(.words)
                        TextField("Dietary note (optional)", text: $dietary)
                    }
                } header: {
                    Text("Guest")
                } footer: {
                    if needsConfirm {
                        Text("Worth a quick look — tweak the name if needed. It imports either way.")
                    }
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

                Section {
                    Button(role: .destructive) {
                        onRemove()
                        dismiss()
                    } label: {
                        Label("Remove from import", systemImage: "trash")
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
