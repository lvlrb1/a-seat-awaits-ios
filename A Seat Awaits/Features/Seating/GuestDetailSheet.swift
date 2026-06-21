//
//  GuestDetailSheet.swift
//  A Seat Awaits
//
//  Tap a guest → quick-assign sheet. Shows the guest's details (household,
//  dietary, notes) and a list of tables with open-seat counts and a "best match"
//  hint, then a pinned "Seat at {table}" CTA. Section 04 of the design spec.
//

import SwiftUI

struct GuestDetailSheet: View {
    @Bindable var store: SeatingStore
    let guest: Guest

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTableId: String?
    @State private var isSaving = false

    init(store: SeatingStore, guest: Guest) {
        self.store = store
        self.guest = guest
        _selectedTableId = State(initialValue: guest.tableId)
    }

    // The table the CTA will seat the guest at (defaults to current/best match).
    private var targetTableId: String? {
        selectedTableId ?? guest.tableId ?? bestMatchTableId
    }

    private var targetTableName: String? {
        store.table(withId: targetTableId)?.name
    }

    // Best match = same group if any has open seats, else most open seats.
    private var bestMatchTableId: String? {
        let candidates = store.tables.filter { table in
            guard let remaining = SeatingLogic.remainingSeats(table, guests: store.guests) else { return true }
            return remaining > 0
        }
        // Prefer a table matching the guest's group name.
        if let groupName = guest.groupName?.nilIfBlank {
            let grouped = candidates.filter {
                ($0.description?.localizedCaseInsensitiveContains(groupName) ?? false)
                    || $0.name.localizedCaseInsensitiveContains(groupName)
            }
            if let best = grouped.max(by: { openSeats($0) < openSeats($1) }) {
                return best.id
            }
        }
        return candidates.max(by: { openSeats($0) < openSeats($1) })?.id
    }

    private func openSeats(_ table: SeatingTable) -> Int {
        SeatingLogic.remainingSeats(table, guests: store.guests) ?? .max
    }

    var body: some View {
        VStack(spacing: 0) {
            Grabber().padding(.top, 10).padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    attributeChips
                    if let notes = guest.notes?.nilIfBlank {
                        notesCard(notes)
                    }
                    if store.canEdit { assignSection }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, store.canEdit ? 120 : 24)
            }
        }
        .background(Brand.card)
        .overlay(alignment: .bottom) { if store.canEdit { ctaBar } }
        .presentationDragIndicator(.hidden)
        .presentationDetents([.large])
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            InitialsAvatar(name: guest.name, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(guest.name)
                    .font(.system(size: 22, weight: .heavy))
                    .tracking(-0.2)
                    .foregroundStyle(Brand.textPrimary)
                if let household = householdLine {
                    Text(household)
                        .font(.system(size: 14))
                        .foregroundStyle(Brand.textSecondary)
                }
            }
            Spacer(minLength: 8)
            statusBadge
        }
        .padding(.top, 12)
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

    private func notesCard(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NOTES")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Brand.slate400)
            Text(notes)
                .font(.system(size: 14))
                .lineSpacing(2)
                .foregroundStyle(Brand.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.dynamic(Brand.slate50, Brand.cardDark),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Brand.hairline, lineWidth: 1))
        .padding(.top, 18)
    }

    // MARK: - Assign to a table

    private var assignSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Assign to a table")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Brand.textPrimary)

            if store.tables.isEmpty {
                Text("No tables yet. Add a table from the Tables tab first.")
                    .font(.system(size: 14))
                    .foregroundStyle(Brand.textSecondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 9) {
                    ForEach(store.tables) { table in
                        tableRow(table)
                    }
                }
            }
        }
        .padding(.top, 20)
    }

    private func tableRow(_ table: SeatingTable) -> some View {
        let remaining = SeatingLogic.remainingSeats(table, guests: store.guests)
        let isBest = table.id == bestMatchTableId
        let isSelected = targetTableId == table.id
        let isFull = (remaining ?? 1) == 0 && guest.tableId != table.id

        return Button {
            selectedTableId = table.id
        } label: {
            HStack(spacing: 12) {
                tableBadge(table, selected: isSelected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tableTitle(table))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    Text(seatsLine(remaining: remaining, isBest: isBest, isFull: isFull))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(seatsColor(remaining: remaining, isBest: isBest, isFull: isFull))
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Brand.accent)
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
        .disabled(isFull)
        .opacity(isFull ? 0.55 : 1)
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
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(selected ? .white : Brand.slate600)
            )
    }

    private func tableShortLabel(_ table: SeatingTable) -> String {
        // "T" + leading digits of the name when present, else two initials.
        let digits = table.name.filter(\.isNumber)
        if !digits.isEmpty { return "T\(digits.prefix(2))" }
        return Initials.from(table.name)
    }

    private func seatsLine(remaining: Int?, isBest: Bool, isFull: Bool) -> String {
        if isFull { return "Full" }
        let base: String
        if let remaining {
            base = "\(remaining) seat\(remaining == 1 ? "" : "s") open"
        } else {
            base = "Open seating"
        }
        return isBest ? "\(base) · best match" : base
    }

    private func seatsColor(remaining: Int?, isBest: Bool, isFull: Bool) -> Color {
        if isFull { return Brand.danger }
        if isBest { return Brand.success }
        return Brand.textSecondary
    }

    // MARK: - CTA

    @ViewBuilder
    private var ctaBar: some View {
        VStack(spacing: 0) {
            Button {
                seat()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .heavy))
                    Text(ctaTitle)
                }
            }
            .buttonStyle(.primaryBrand)
            .disabled(targetTableId == nil || isSaving)
            .opacity(targetTableId == nil ? 0.5 : 1)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
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
        Task {
            await store.assignWithUndo(guest, toTable: tableId)
            isSaving = false
            dismiss()
        }
    }
}
