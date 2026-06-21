//
//  TableDetailSheet.swift
//  A Seat Awaits
//
//  Tap a table on the floor plan to see who's seated, seat more guests from the
//  unassigned pool, or remove the table. Styled to the design system: grabber +
//  title, capacity ring with seated count, guest rows with initials avatars.
//

import SwiftUI

struct TableDetailSheet: View {
    @Bindable var store: SeatingStore
    let table: SeatingTable
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var showingAssign = false
    @State private var showingEdit = false
    /// Guests ticked in the multi-select assign picker, by id.
    @State private var assignSelection: Set<String> = []

    /// Always read the latest table from the store so edits/duplicates made from
    /// this sheet reflect immediately (the passed-in `table` is a snapshot).
    private var t: SeatingTable { store.tables.first { $0.id == table.id } ?? table }

    private var seated: [Guest] {
        store.guests.filter { $0.tableId == table.id }
            .sorted { $0.lastNameKey < $1.lastNameKey }
    }
    private var unassigned: [Guest] {
        store.guests.filter { !$0.isAssigned }
            .sorted { $0.lastNameKey < $1.lastNameKey }
    }
    private var canEdit: Bool { store.canEdit }
    private var capacity: Int { t.capacity ?? 0 }
    private var isFull: Bool { capacity > 0 && seated.count >= capacity }
    private var isOver: Bool { capacity > 0 && seated.count > capacity }
    private var progress: Double { capacity > 0 ? Double(seated.count) / Double(capacity) : 0 }
    private var open: Int { max(0, capacity - seated.count) }

    var body: some View {
        VStack(spacing: 0) {
            Grabber().padding(.top, 10).padding(.bottom, 6)

            header

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    detailsSection
                    if canEdit { actionButtons }
                    seatedSection
                    if canEdit {
                        if !showingAssign { assignSection } else { assignPicker }
                        deleteButton
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 30)
            }
        }
        .background(Brand.canvas)
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $showingEdit) {
            AddTableView(store: store, editing: t)
        }
        .confirmationDialog("Delete \(t.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete table", role: .destructive) {
                Task { await store.deleteTable(table); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Guests at this table will become unassigned.")
        }
    }

    // MARK: - Header (title + capacity ring)

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                ProgressRing(progress: progress, size: 60, lineWidth: 6, showsPercent: false)
                VStack(spacing: 0) {
                    Text("\(seated.count)")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(Brand.textPrimary)
                    if capacity > 0 {
                        Text("of \(capacity)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(t.name)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.02 * 22)
                    .foregroundStyle(Brand.textPrimary)
                if capacity > 0 {
                    if isOver {
                        TagPill(text: "\(seated.count - capacity) over", fg: Brand.danger,
                                bg: Brand.danger.opacity(0.12))
                    } else if isFull {
                        TagPill.seated("Full")
                    } else {
                        TagPill.open("\(open) open")
                    }
                }
            }

            Spacer()

            Button { dismiss() } label: {
                Text("Done")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.accent)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Details

    private var detailsSection: some View {
        VStack(spacing: 0) {
            detailRow("Type", value: typeText)
            rowDivider
            detailRow("Size", value: sizeText)
            if !t.isRound {
                rowDivider
                detailRow("Rotation", value: "\(Int(t.rotationDegrees))°")
            }
            rowDivider
            detailRow("Seats", value: seatsText)
            if let note = t.description?.nilIfBlank {
                rowDivider
                detailRow("Notes", value: note)
            }
        }
        .brandCard()
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Brand.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var typeText: String {
        if let preset = t.matchingPreset { return preset.label }
        return (t.shape ?? .circle).label
    }

    private var sizeText: String {
        let w = TableScale.feetLabel(t.widthFeet)
        if t.isRound { return "\(w) ft round" }
        let l = TableScale.feetLabel(t.heightFeet)
        return "\(w) × \(l) ft"
    }

    private var seatsText: String {
        guard capacity > 0 else { return "\(seated.count) seated" }
        if isOver { return "\(seated.count)/\(capacity) · \(seated.count - capacity) over" }
        return "\(seated.count)/\(capacity) · \(open) open"
    }

    // MARK: - Edit / Duplicate

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button { showingEdit = true } label: {
                Label("Edit", systemImage: "pencil")
            }
            .buttonStyle(.secondaryOutline)

            Button { Task { await store.duplicateTable(t); dismiss() } } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .buttonStyle(.secondaryOutline)
        }
    }

    // MARK: - Seated guests

    private var seatedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("SEATED")
            if seated.isEmpty {
                emptyHint("No one seated here yet.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(seated.enumerated()), id: \.element.id) { idx, guest in
                        guestRow(guest, trailing: {
                            if canEdit {
                                Button {
                                    Task { await store.assignWithUndo(guest, toTable: nil) }
                                } label: {
                                    Text("Unseat")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Brand.warningText)
                                }
                            }
                        })
                        if idx < seated.count - 1 { rowDivider }
                    }
                }
                .brandCard()
            }
        }
    }

    // MARK: - Assign affordance / picker

    private var assignSection: some View {
        Button {
            assignSelection = []
            showingAssign = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.plus")
                Text("Assign guests")
            }
        }
        .buttonStyle(.secondaryOutline)
        .disabled(isFull || unassigned.isEmpty)
        .opacity(isFull || unassigned.isEmpty ? 0.5 : 1)
    }

    /// Open seats still selectable; nil capacity means unlimited room.
    private var roomForSelection: Int? { capacity > 0 ? open : nil }

    /// True once the selection has claimed every remaining seat.
    private var selectionAtCapacity: Bool {
        guard let room = roomForSelection else { return false }
        return assignSelection.count >= room
    }

    private var assignPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("ADD FROM UNASSIGNED")
                Spacer()
                if let room = roomForSelection {
                    Text("\(assignSelection.count) of \(room) open")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selectionAtCapacity ? Brand.warningText : Brand.textSecondary)
                }
                Button("Done") {
                    showingAssign = false
                    assignSelection = []
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Brand.accent)
            }
            if unassigned.isEmpty {
                emptyHint("Everyone is seated.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(unassigned.enumerated()), id: \.element.id) { idx, guest in
                        let picked = assignSelection.contains(guest.id)
                        // Block ticking new guests once every open seat is spoken
                        // for, but always allow un-ticking.
                        let blocked = !picked && selectionAtCapacity
                        Button {
                            toggleAssign(guest)
                        } label: {
                            guestRow(guest, trailing: {
                                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22))
                                    .foregroundStyle(picked ? Brand.accent
                                                     : (blocked ? Brand.slate300 : Brand.slate400))
                            })
                        }
                        .buttonStyle(.plain)
                        .disabled(blocked)
                        if idx < unassigned.count - 1 { rowDivider }
                    }
                }
                .brandCard()

                if selectionAtCapacity {
                    Text("That fills every open seat. Unseat someone or edit the table to add more.")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.textSecondary)
                }

                Button {
                    let picks = unassigned.filter { assignSelection.contains($0.id) }
                    Task { await store.assignWithUndo(picks, toTable: table.id) }
                    showingAssign = false
                    assignSelection = []
                } label: {
                    Text(assignSelection.isEmpty
                         ? "Select guests to seat"
                         : "Seat \(assignSelection.count) guest\(assignSelection.count == 1 ? "" : "s")")
                }
                .buttonStyle(.primaryBrand)
                .disabled(assignSelection.isEmpty)
                .opacity(assignSelection.isEmpty ? 0.5 : 1)
            }
        }
    }

    private func toggleAssign(_ guest: Guest) {
        if assignSelection.contains(guest.id) {
            assignSelection.remove(guest.id)
        } else {
            assignSelection.insert(guest.id)
        }
    }

    // MARK: - Delete

    private var deleteButton: some View {
        Button(role: .destructive) {
            confirmingDelete = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                Text("Delete table")
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Brand.danger)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Brand.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - Building blocks

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Brand.textSecondary)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(Brand.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .brandCard()
    }

    private func guestRow<Trailing: View>(_ guest: Guest,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            InitialsAvatar(name: guest.name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(guest.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
                if let group = guest.groupName, !group.isEmpty {
                    Text(group)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.textSecondary)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var rowDivider: some View {
        Rectangle().fill(Brand.hairline).frame(height: 1).padding(.leading, 66)
    }
}
