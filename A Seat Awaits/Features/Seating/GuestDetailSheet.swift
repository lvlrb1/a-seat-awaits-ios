//
//  GuestDetailSheet.swift
//  A Seat Awaits
//
//  Tap a guest → quick-assign sheet. Fixed zones per the HIG (matching
//  TableDetailSheet): Close in the top bar, guest details + table search fixed
//  below it, only the table list scrolls, and the "Seat at {table}" CTA is
//  pinned to the bottom. Page sheet on iPad; medium detent on iPhone.
//  Section 04 of the design spec.
//

import SwiftUI

struct GuestDetailSheet: View {
    @Bindable var store: SeatingStore
    let guest: Guest
    /// "Pick a Table on the Floor Plan": the presenter dismisses this sheet
    /// and hands the guest to the canvas's assign mode. Nil hides the button.
    var onPickOnFloorPlan: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTableId: String?
    @State private var isSaving = false
    @State private var tableSearch = ""
    /// Why the last seat attempt didn't land (the sheet stays open to retry).
    @State private var saveError: String?

    init(store: SeatingStore, guest: Guest, onPickOnFloorPlan: (() -> Void)? = nil) {
        self.store = store
        self.guest = guest
        self.onPickOnFloorPlan = onPickOnFloorPlan
        _selectedTableId = State(initialValue: guest.tableId)
    }

    // The table the CTA will seat the guest at. Defaults to the guest's current
    // table; for an unassigned guest nothing is pre-selected until the user taps one.
    private var targetTableId: String? {
        selectedTableId ?? guest.tableId
    }

    // Tables in numeric-aware name order, filtered by the search field.
    private var visibleTables: [SeatingTable] {
        let sorted = SeatingLogic.sortedTables(store.tables, by: .nameAZ, guests: store.guests)
        let query = tableSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter { table in
            table.name.localizedCaseInsensitiveContains(query)
                || (table.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var targetTableName: String? {
        store.table(withId: targetTableId)?.name
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            VStack(alignment: .leading, spacing: 0) {
                header
                attributeChips
                if let notes = guest.notes?.nilIfBlank { noteRow(notes) }
                if store.canEdit { assignHeader }
            }
            .padding(.horizontal, 24)

            if store.canEdit {
                ScrollView {
                    tableList
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .background(Brand.card)
        .safeAreaInset(edge: .bottom) { if store.canEdit { ctaBar } }
        .presentationDragIndicator(.visible)
        .presentationDetents([.medium, .large])
        // Full-height page sheet on iPad, matching the table sheets.
        .presentationSizing(.page)
    }

    // MARK: - Top bar

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
        }
        .padding(.horizontal, 16)
        // Clear the system grabber overlaid at the sheet's top edge.
        .padding(.top, 16)
        .padding(.bottom, 2)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            InitialsAvatar(name: guest.name, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                TitleBadgeRow(badgeAtTrailing: true) {
                    Text(guest.name)
                        .scaledFont(size: 22, weight: .heavy)
                        .tracking(-0.2)
                        .foregroundStyle(Brand.textPrimary)
                } badge: {
                    statusBadge
                }
                if let household = householdLine {
                    Text(household)
                        .scaledFont(size: 14)
                        .foregroundStyle(Brand.textSecondary)
                }
            }
        }
        .padding(.top, 2)
    }

    private var householdLine: String? {
        if let group = guest.groupName?.nilIfBlank {
            return "Household · \(group)"
        }
        return nil
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let table = store.table(withId: guest.tableId) {
            TagPill.assigned(table.name)
        } else {
            TagPill.unassigned()
        }
    }

    // MARK: - Attribute chips

    @ViewBuilder
    private var attributeChips: some View {
        let group = guest.groupName?.nilIfBlank
        let diet = guest.dietaryPreference?.nilIfBlank
        if group != nil || diet != nil {
            HStack(spacing: 8) {
                if let group {
                    if guest.isAssigned {
                        TagPill(text: group, fg: Brand.skyText, bg: Brand.skyFill,
                                dotColor: Brand.teal)
                    } else {
                        TagPill.household(group)
                    }
                }
                if let diet {
                    TagPill.dietary(diet)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 14)
        }
    }

    // MARK: - Notes

    /// Compact fixed note line (mirrors TableDetailSheet); guest notes are
    /// typically short, and keeping this out of the scroll preserves the fixed
    /// header + scrolling-list structure.
    private func noteRow(_ notes: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "note.text")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(Brand.textSecondary)
                .accessibilityHidden(true)
            Text(notes)
                .scaledFont(size: 13)
                .lineSpacing(2)
                .foregroundStyle(Brand.textSecondary)
                .lineLimit(3)
        }
        .padding(.top, 14)
    }

    // MARK: - Assign to a table

    /// Fixed title + search; the matching table list scrolls below it.
    private var assignHeader: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Assign to a table")
                .scaledFont(size: 15, weight: .bold)
                .foregroundStyle(Brand.textPrimary)

            if store.tables.isEmpty {
                Text("No tables yet. Add a table from the Tables tab first.")
                    .scaledFont(size: 14)
                    .foregroundStyle(Brand.textSecondary)
                    .padding(.vertical, 8)
            } else {
                SearchField(text: $tableSearch, placeholder: "Search tables", height: 42)

                if let onPickOnFloorPlan {
                    // The visual route: dismiss, switch to the plan, tap a seat.
                    Button {
                        onPickOnFloorPlan()
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "map")
                                .scaledFont(size: 14, weight: .bold)
                            Text("Pick a Table on the Floor Plan")
                                .scaledFont(size: 14, weight: .bold)
                        }
                        .foregroundStyle(Brand.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Brand.accent.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
                }
            }
        }
        .padding(.top, 20)
    }

    @ViewBuilder
    private var tableList: some View {
        if !store.tables.isEmpty {
            let tables = visibleTables
            if tables.isEmpty {
                Text("No tables match “\(tableSearch)”.")
                    .scaledFont(size: 14)
                    .foregroundStyle(Brand.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 9) {
                    ForEach(tables) { table in
                        tableRow(table)
                    }
                }
            }
        }
    }

    private func tableRow(_ table: SeatingTable) -> some View {
        let isSelected = targetTableId == table.id

        return Button {
            selectedTableId = table.id
        } label: {
            HStack(spacing: 12) {
                tableBadge(table, selected: isSelected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tableTitle(table))
                        .scaledFont(size: 15, weight: .bold)
                        .foregroundStyle(isSelected ? Brand.plum : Brand.textPrimary)
                    Text(seatsLine(for: table))
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(seatsColor(for: table, isSelected: isSelected))
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(size: 22)
                        .foregroundStyle(Brand.plum)
                        .accessibilityLabel("Selected")
                }
            }
            .padding(.horizontal, 15)
            .frame(height: 56)
            .background(
                isSelected ? Brand.plumChipFillSoft : Brand.card,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Brand.accent : Brand.separator,
                                  lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func tableTitle(_ table: SeatingTable) -> String {
        if let desc = table.description?.nilIfBlank {
            return "\(table.name) · \(desc)"
        }
        return table.name
    }

    private func tableBadge(_ table: SeatingTable, selected: Bool) -> some View {
        Circle()
            .fill(selected ? Brand.primaryFill : Brand.control)
            .frame(width: 34, height: 34)
            .overlay(
                Text(tableShortLabel(table))
                    .scaledFont(size: 13, weight: .bold)
                    .foregroundStyle(selected ? .white : Brand.slate600)
            )
    }

    private func tableShortLabel(_ table: SeatingTable) -> String {
        // "T" + leading digits of the name when present, else two initials.
        let digits = table.name.filter(\.isNumber)
        if !digits.isEmpty { return "T\(digits.prefix(2))" }
        return Initials.from(table.name)
    }

    /// Row subtitle: always leads with the guest's relationship to the table
    /// ("Seated here") or the real seated/capacity counts, so empty, full, and
    /// over-capacity tables each read differently and a taken-seats count never
    /// shows for a table the guest already occupies.
    private func seatsLine(for table: SeatingTable) -> String {
        let seatedCount = SeatingLogic.occupancy(of: table.id, guests: store.guests)
        let isCurrent = guest.tableId == table.id
        guard let capacity = table.capacity, capacity > 0 else {
            let counts = seatedCount > 0 ? " · \(seatedCount) seated" : ""
            return isCurrent ? "Seated here\(counts)" : "Open seating\(counts)"
        }
        if isCurrent {
            return "Seated here · \(seatedCount) of \(capacity) seats taken"
        }
        if seatedCount > capacity {
            return "Over capacity · \(seatedCount) seated at \(capacity) seats"
        }
        if seatedCount == capacity {
            return "Full · all \(capacity) seats taken"
        }
        if seatedCount == 0 {
            return "Empty · \(capacity) seats"
        }
        return "\(seatedCount) of \(capacity) seats taken"
    }

    private func seatsColor(for table: SeatingTable, isSelected: Bool) -> Color {
        let seatedCount = SeatingLogic.occupancy(of: table.id, guests: store.guests)
        let capacity = table.capacity ?? 0
        if guest.tableId != table.id && capacity > 0 && seatedCount >= capacity {
            return Brand.danger
        }
        // Selected rows sit on a fixed light lavender background in both modes,
        // so keep the subtitle dark enough to read instead of the mode-aware secondary.
        return isSelected ? Brand.slate600 : Brand.textSecondary
    }

    // MARK: - CTA

    /// Set when the picked table has no open seats: full tables stay selectable
    /// (planners overseat on purpose — extra chairs, kids on laps), but the
    /// consequence is spelled out before they commit.
    private var overCapacityWarning: String? {
        guard let id = targetTableId, id != guest.tableId,
              let table = store.table(withId: id),
              let capacity = table.capacity, capacity > 0 else { return nil }
        let seatedCount = SeatingLogic.occupancy(of: id, guests: store.guests)
        guard seatedCount >= capacity else { return nil }
        let over = seatedCount + 1 - capacity
        return "\(table.name) is full. Seating \(guest.name) puts it \(over) over its \(capacity) seats."
    }

    @ViewBuilder
    private var ctaBar: some View {
        VStack(spacing: 8) {
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.circle.fill")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(Brand.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let warning = overCapacityWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(Brand.warningText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                seat()
            } label: {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "checkmark")
                            .scaledFont(size: 16, weight: .heavy)
                    }
                    Text(ctaTitle)
                }
            }
            .buttonStyle(.primaryBrand)
            .disabled(targetTableId == nil || isSaving)
            .opacity(targetTableId == nil ? 0.5 : 1)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            Brand.card
                .overlay(Brand.separator.frame(height: 1), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var ctaTitle: String {
        if let name = targetTableName { return "Seat at \(name)" }
        return "Seat guest"
    }

    private func seat() {
        guard let tableId = targetTableId else { return }
        isSaving = true
        saveError = nil
        Task {
            store.errorMessage = nil
            await store.assignWithUndo(guest, toTable: tableId)
            isSaving = false
            // Only leave once the guest really sits there; the store rolls a
            // failed write back, so the local row is the source of truth.
            if store.guests.first(where: { $0.id == guest.id })?.tableId == tableId {
                dismiss()
            } else {
                saveError = store.errorMessage
                    ?? "Couldn't seat \(guest.name). Check your connection and try again."
                store.errorMessage = nil
            }
        }
    }
}
