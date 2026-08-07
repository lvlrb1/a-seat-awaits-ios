//
//  AddGuestView.swift
//  A Seat Awaits
//

import SwiftUI

struct AddGuestView: View {
    @Bindable var store: SeatingStore
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var name = ""
    @State private var selectedTableId: String?
    @State private var selectedGroupId: String?
    @State private var customGroupName = ""
    @State private var dietary = ""
    @State private var notes = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingPaywall = false

    /// Numeric-aware name order, same as the table pickers elsewhere.
    private var sortedTables: [SeatingTable] {
        SeatingLogic.sortedTables(store.tables, by: .nameAZ, guests: store.guests)
    }

    /// Seats left at a table, or nil when the table has no capacity set.
    private func openSeats(at table: SeatingTable) -> Int? {
        guard let capacity = table.capacity, capacity > 0 else { return nil }
        return capacity - store.guests.count { $0.tableId == table.id }
    }

    /// The event is at its plan/pass guest cap. Only engages once the
    /// entitlement has actually loaded, so a slow fetch never flashes a bogus
    /// "limit reached" at an entitled user (the DB stays the enforcement).
    private var atCapacity: Bool {
        store.entitlementLoaded && store.guests.count >= store.entitlement.guestCap
    }

    var body: some View {
        NavigationStack {
            Form {
                if atCapacity {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Guest limit reached", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Brand.warning)
                            Text("This event has \(store.guests.count) of \(store.entitlement.guestCap) guests on \(store.entitlement.guestCapSourceLabel). Upgrade to add more.")
                                .font(.footnote)
                                .foregroundStyle(Brand.textSecondary)
                            Button("View plans") { showingPaywall = true }
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Brand.accent)
                        }
                    }
                }
                Section("Guest") {
                    TextField("Full name", text: $name)
                        .textContentType(.name)
                }
                if !store.tables.isEmpty {
                    Section("Seating") {
                        Picker("Assign to table", selection: $selectedTableId) {
                            Text("Unassigned").tag(String?.none)
                            ForEach(sortedTables) { table in
                                Text(tableLabel(table)).tag(String?.some(table.id))
                            }
                        }
                    }
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
                Section {
                    TextField("Dietary preference", text: $dietary)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("Details")
                } footer: {
                    // Same consent reminder as the web form: dietary info can
                    // reveal health conditions or religious beliefs.
                    Text("Dietary information may reveal health conditions or religious beliefs. Make sure you have the guest's consent before entering it.")
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
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving || atCapacity)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .sheet(isPresented: $showingPaywall, onDismiss: {
                Task { await store.loadEntitlement() }
            }) {
                if let supabase = appState.supabase {
                    PaywallView(supabase: supabase, appState: appState,
                                mode: .plans(eventId: store.event.id))
                }
            }
        }
    }

    /// "Table 1 · 3 open" / "Table 2 · Full" so the picker warns before the
    /// save-time validation does.
    private func tableLabel(_ table: SeatingTable) -> String {
        guard let open = openSeats(at: table) else { return table.name }
        return open > 0 ? "\(table.name) · \(open) open" : "\(table.name) · Full"
    }

    private func resolvedGroupName() -> String? {
        if let custom = customGroupName.nilIfBlank { return custom }
        if let id = selectedGroupId { return store.groups.first { $0.id == id }?.name }
        return nil
    }

    private func save() async {
        errorMessage = nil
        // Same guard as the web form: don't seat a new guest at a full table.
        if let id = selectedTableId,
           let table = store.table(withId: id),
           let open = openSeats(at: table), open <= 0 {
            errorMessage = "\(table.name) is full. Pick another table or leave the guest unassigned."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.addGuest(
                name: name.trimmingCharacters(in: .whitespaces),
                groupId: customGroupName.nilIfBlank == nil ? selectedGroupId : nil,
                groupName: resolvedGroupName(),
                notes: notes,
                dietary: dietary,
                tableId: selectedTableId
            )
            dismiss()
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }
}
