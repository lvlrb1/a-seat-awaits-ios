//
//  TableDetailSheet.swift
//  A Seat Awaits
//
//  Tap a table on the floor plan to see who's seated. Actions live in fixed
//  zones per the HIG so nothing hides below the fold: Close and Delete in the
//  top bar, Edit/Duplicate at the top of the content, the seated list as the
//  scrolling content, and the primary "Assign guests" action pinned to the
//  bottom. Page sheet on iPad; opens at a medium detent on iPhone.
//

import SwiftUI

struct TableDetailSheet: View {
    @Bindable var store: SeatingStore
    let table: SeatingTable
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var showingAssign = false
    @State private var showingEdit = false

    /// Always read the latest table from the store so edits/duplicates made from
    /// this sheet reflect immediately (the passed-in `table` is a snapshot).
    private var t: SeatingTable { store.tables.first { $0.id == table.id } ?? table }

    private var seated: [Guest] {
        store.guests.filter { $0.tableId == table.id }
            .sorted { $0.lastNameKey < $1.lastNameKey }
    }
    /// Anyone not already at this table can be seated here (the picker sheet
    /// handles unassigned-vs-moving); empty means the assign button is moot.
    private var hasCandidates: Bool {
        store.guests.contains { $0.tableId != table.id }
    }
    private var canEdit: Bool { store.canEdit }
    private var capacity: Int { t.capacity ?? 0 }
    private var isFull: Bool { capacity > 0 && seated.count >= capacity }
    private var isOver: Bool { capacity > 0 && seated.count > capacity }
    private var progress: Double { capacity > 0 ? Double(seated.count) / Double(capacity) : 0 }
    private var open: Int { max(0, capacity - seated.count) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let note = t.description?.nilIfBlank { noteRow(note) }
                    if canEdit { actionButtons }
                    seatedSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
        .background(Brand.canvas)
        .safeAreaInset(edge: .bottom) { if canEdit { assignCTABar } }
        .presentationDragIndicator(.visible)
        .presentationDetents([.medium, .large])
        // Page sheet on iPad: slides up from the bottom edge and fills most of
        // the screen instead of the small centered form-sheet card.
        .presentationSizing(.page)
        .sheet(isPresented: $showingEdit) {
            AddTableView(store: store, editing: t)
        }
        .sheet(isPresented: $showingAssign, onDismiss: { store.undo.extend() }) {
            AssignGuestsSheet(store: store, table: t)
        }
        .confirmationDialog("Delete \(t.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Table", role: .destructive) { deleteTable() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(seated.count) guest\(seated.count == 1 ? "" : "s") seated here will become unassigned. You can undo for a few seconds.")
        }
    }

    /// An empty table deletes straight away (undo is the safety net); one with
    /// people at it asks first.
    private func requestDelete() {
        if seated.isEmpty { deleteTable() } else { confirmingDelete = true }
    }

    private func deleteTable() {
        let target = t
        dismiss()
        Task { await store.deleteTableWithUndo(target) }
    }

    // MARK: - Top bar (Close + Delete)

    /// Fixed toolbar row: standard Close on the leading edge, Delete on the
    /// trailing edge (destructive, so it sits apart from the everyday actions;
    /// the confirmation dialog still guards it).
    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(Brand.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Brand.control, in: Circle())
                    // 32pt visual, 44pt hit target.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")

            Spacer()

            if canEdit {
                Button(role: .destructive) { requestDelete() } label: {
                    Image(systemName: "trash")
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(Brand.danger)
                        .frame(width: 32, height: 32)
                        .background(Brand.danger.opacity(0.1), in: Circle())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Delete table")
            }
        }
        .padding(.horizontal, 16)
        // Clear the system grabber overlaid at the sheet's top edge.
        .padding(.top, 16)
        .padding(.bottom, 4)
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

    // MARK: - Header (capacity ring + title + summary)

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                ProgressRing(progress: progress, size: 60, lineWidth: 6, showsPercent: false)
                VStack(spacing: 0) {
                    Text("\(seated.count)")
                        .scaledFont(size: 18, weight: .heavy)
                        .foregroundStyle(Brand.textPrimary)
                    if capacity > 0 {
                        Text("of \(capacity)")
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(t.name)
                    .scaledFont(size: 22, weight: .bold)
                    .tracking(-0.02 * 22)
                    .foregroundStyle(Brand.textPrimary)
                HStack(spacing: 8) {
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
                    Text(summaryText)
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(Brand.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
    }

    /// One-line stand-in for the old details card; the full facts (dimensions,
    /// rotation, notes) live in the Edit form.
    private var summaryText: String {
        var parts = [typeText]
        if t.matchingPreset == nil { parts.append(sizeText) }
        parts.append(capacity > 0 ? "\(capacity) seats" : "\(seated.count) seated")
        return parts.joined(separator: " · ")
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

    private func noteRow(_ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "note.text")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(Brand.textSecondary)
                .accessibilityHidden(true)
            Text(note)
                .scaledFont(size: 13)
                .foregroundStyle(Brand.textSecondary)
                .lineLimit(2)
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
                                        .scaledFont(size: 13, weight: .bold)
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

    // MARK: - Pinned assign CTA

    /// The primary action stays visible at every sheet height (HIG: a view's
    /// primary actions must be easily discoverable, never buried in a scroll).
    private var assignCTABar: some View {
        VStack(spacing: 8) {
            // Unseating from this sheet is undoable, but the workspace's
            // snackbar sits under the sheet; show it here, above the CTA.
            UndoSnackbarView(toast: store.undo)
                // The snackbar carries its own 16pt side padding; pull it back
                // out so it lines up with the CTA button below.
                .padding(.horizontal, -16)
                .animation(.snappy(duration: 0.25), value: store.undo.message)
            if isFull {
                Text(isOver ? "Over capacity · \(seated.count) guests seated, \(capacity) seats"
                            : "Table full · assigning more will exceed capacity")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(Brand.warningText)
            }
            Button { showingAssign = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.badge.plus")
                    Text("Assign guests")
                }
            }
            .buttonStyle(.primaryBrand)
            .disabled(!hasCandidates)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            Brand.canvas
                .overlay(Brand.separator.frame(height: 1), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Building blocks

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 12, weight: .bold)
            .tracking(0.6)
            .foregroundStyle(Brand.textSecondary)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 15)
            .foregroundStyle(Brand.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .brandCard()
    }

    private func guestRow<Trailing: View>(_ guest: Guest,
                                          subtitle: String? = nil,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            InitialsAvatar(name: guest.name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(guest.name)
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(Brand.textPrimary)
                if let group = guest.groupName, !group.isEmpty {
                    Text(group)
                        .scaledFont(size: 13)
                        .foregroundStyle(Brand.textSecondary)
                }
                if let subtitle {
                    Text(subtitle)
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(Brand.warningText)
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
