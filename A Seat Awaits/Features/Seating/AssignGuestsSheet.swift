//
//  AssignGuestsSheet.swift
//  A Seat Awaits
//
//  Full-screen guest picker for seating people at a table, presented from
//  TableDetailSheet. A pinned search field over a recycling List keeps large
//  guest lists fast; candidates are sectioned into "Unassigned" and "Seated
//  elsewhere", parties get a one-tap select-all, and the seat CTA stays pinned
//  to the bottom with the over-capacity warning.
//

import SwiftUI

struct AssignGuestsSheet: View {
    @Bindable var store: SeatingStore
    let table: SeatingTable
    @Environment(\.dismiss) private var dismiss

    /// Which pool of candidates is showing. Surfaced as counted chips (like the
    /// Guests tab) so "seated at another table" is discoverable even when the
    /// unassigned list runs hundreds of rows deep.
    private enum Scope: Hashable {
        case all
        case unassigned
        case seated
    }

    @State private var selection: Set<String> = []
    @State private var search = ""
    @State private var sort: GuestSort = .lastNameAZ
    @State private var scope: Scope = .all
    @State private var groupFilter: String?
    /// Narrows the Seated pool to one specific table.
    @State private var tableFilter: String?
    @State private var isSaving = false

    /// "Unassigned first" is meaningless here — the list is already sectioned
    /// into Unassigned and Seated elsewhere.
    private static let sortOptions = GuestSort.allCases.filter { $0 != .unassignedFirst }

    // MARK: - Candidates

    /// Everyone not already seated at this table.
    private var candidates: [Guest] {
        store.guests.filter { $0.tableId != table.id }
    }

    private var searchedCandidates: [Guest] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }
        return candidates.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.groupName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// Search results narrowed by the group filter, before the scope chips —
    /// this is what the chip counts describe. Matched on group NAME, not id:
    /// imported guests often carry only `group_name` with no linked group row,
    /// and id-linked guests keep `group_name` in sync, so names cover both.
    private var groupedCandidates: [Guest] {
        guard let groupFilter else { return searchedCandidates }
        return searchedCandidates.filter { $0.groupName == groupFilter }
    }

    /// What the list actually shows: grouped candidates cut down to the chosen
    /// scope (and, for Seated, optionally one specific table).
    private var filteredCandidates: [Guest] {
        groupedCandidates.filter { guest in
            if let tableFilter { return guest.tableId == tableFilter }
            switch scope {
            case .all: return true
            case .unassigned: return !guest.isAssigned
            case .seated: return guest.isAssigned
            }
        }
    }

    /// Group names that actually appear among candidates, matching the web
    /// sidebar's "only groups with guests" rule.
    private var filterableGroupNames: [String] {
        Set(candidates.compactMap { $0.groupName?.nilIfBlank })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Every table except this one (its guests aren't candidates), in the same
    /// numeric-aware name order as the other table pickers.
    private var filterableTables: [SeatingTable] {
        SeatingLogic.sortedTables(store.tables.filter { $0.id != table.id },
                                  by: .nameAZ, guests: store.guests)
    }


    /// A party (household/group) with two or more unassigned members, so
    /// "select all" is worth offering.
    private struct PartyBlock: Identifiable {
        let id: String
        let name: String
        let guests: [Guest]
    }

    /// Unassigned candidates, split into multi-member parties (sorted by party
    /// name) and everyone else (ordered by the chosen sort).
    private var unassigned: (parties: [PartyBlock], individuals: [Guest]) {
        var byGroup: [String: [Guest]] = [:]
        var individuals: [Guest] = []
        for guest in filteredCandidates where !guest.isAssigned {
            if let groupId = guest.groupId {
                byGroup[groupId, default: []].append(guest)
            } else {
                individuals.append(guest)
            }
        }
        var parties: [PartyBlock] = []
        for (groupId, members) in byGroup {
            if members.count >= 2 {
                parties.append(PartyBlock(id: groupId,
                                          name: members.first?.groupName ?? "Party",
                                          guests: SeatingLogic.sorted(members, by: sort)))
            } else {
                individuals.append(contentsOf: members)
            }
        }
        parties.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (parties, SeatingLogic.sorted(individuals, by: sort))
    }

    /// Candidates seated at another table; picking one moves them here.
    private var seatedElsewhere: [Guest] {
        SeatingLogic.sorted(filteredCandidates.filter(\.isAssigned), by: sort)
    }

    // MARK: - Capacity

    private var capacity: Int { table.capacity ?? 0 }
    private var seatedCount: Int { store.guests.count { $0.tableId == table.id } }
    private var open: Int { max(0, capacity - seatedCount) }

    /// How many seats past capacity the current selection would put this table.
    private var projectedOver: Int {
        guard capacity > 0 else { return 0 }
        return max(0, seatedCount + selection.count - capacity)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        SearchField(text: $search, placeholder: "Search guests", height: 42)
                        sortMenu
                    }
                    filterBar
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                if candidates.isEmpty {
                    emptyState("No other guests to seat.",
                               detail: "Everyone is already at this table.")
                } else if searchedCandidates.isEmpty {
                    emptyState("No guests match “\(search)”.",
                               detail: "Try a different name or party.")
                } else if filteredCandidates.isEmpty {
                    emptyState("No guests match your filters.",
                               detail: "Try a different group or table.")
                } else {
                    candidateList
                }
            }
            .background(Brand.canvas)
            .safeAreaInset(edge: .bottom) { seatCTABar }
            // Picking a specific table means browsing the Seated pool, so keep
            // the scope in step for when the table filter is cleared again.
            .onChange(of: tableFilter) { _, newValue in
                if newValue != nil { scope = .seated }
            }
            .navigationTitle("Add to \(table.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if capacity > 0 {
                    ToolbarItem(placement: .topBarTrailing) { seatsLeftBadge }
                }
            }
            .interactiveDismissDisabled(isSaving || !selection.isEmpty)
        }
        // Match TableDetailSheet: full-height page sheet on iPad for room to
        // browse large guest lists.
        .presentationSizing(.page)
    }

    /// Same pill-style sort control as the Guests tab, so the picker orders
    /// candidates the way the user expects.
    private var sortMenu: some View {
        Menu {
            Picker("Sort guests", selection: $sort) {
                ForEach(Self.sortOptions) { option in
                    Text(option.label).tag(option)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Brand.accent)
                .frame(width: 38, height: 32)
                .background(Brand.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                // Keep the 38×32 pill visual but guarantee a 44pt hit target.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Sort guests")
    }

    // MARK: - Filters

    /// Counted scope chips (All / Unassigned / Seated) exactly like the Guests
    /// tab, so both pools are visible up front, plus group and table dropdowns
    /// for narrowing. Everything scrolls in one row.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                let base = groupedCandidates
                let unassignedCount = base.count { !$0.isAssigned }
                let seatedCount = base.count - unassignedCount

                scopeChip(.all, title: "All", count: base.count, bg: Brand.plum)
                scopeChip(.unassigned, title: "Unassigned", count: unassignedCount, bg: Brand.warning)
                scopeChip(.seated, title: "Seated", count: seatedCount, bg: Brand.success)

                if !filterableTables.isEmpty {
                    filterChipMenu(label: tableFilterLabel, active: tableFilter != nil) {
                        Picker("Filter by table", selection: $tableFilter) {
                            Text("All Tables").tag(String?.none)
                            ForEach(filterableTables) { other in
                                Text(other.name).tag(String?.some(other.id))
                            }
                        }
                    }
                }
                if !filterableGroupNames.isEmpty {
                    filterChipMenu(label: groupFilter ?? "All Groups", active: groupFilter != nil) {
                        Picker("Filter by group", selection: $groupFilter) {
                            Text("All Groups").tag(String?.none)
                            ForEach(filterableGroupNames, id: \.self) { name in
                                Text(name).tag(String?.some(name))
                            }
                        }
                    }
                }
            }
        }
    }

    private func scopeChip(_ value: Scope, title: String, count: Int, bg: Color) -> some View {
        Button {
            scope = value
            // A specific table only makes sense inside the Seated pool.
            if value != .seated { tableFilter = nil }
        } label: {
            FilterChip(title: title, count: count,
                       selected: scope == value && tableFilter == nil,
                       selectedBg: bg)
        }
        .buttonStyle(.plain)
    }

    private var tableFilterLabel: String {
        guard let tableFilter else { return "All Tables" }
        return store.tables.first { $0.id == tableFilter }?.name ?? "All Tables"
    }

    private func filterChipMenu(label: String, active: Bool,
                                @ViewBuilder content: () -> some View) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(active ? Color.white : Brand.slate600)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(active ? Brand.plum : Brand.control, in: Capsule())
        }
    }

    // MARK: - List

    private var candidateList: some View {
        List {
            let (parties, individuals) = unassigned
            if !parties.isEmpty || !individuals.isEmpty {
                Section {
                    ForEach(parties) { block in
                        partyHeaderRow(block)
                        ForEach(block.guests) { candidateRow($0) }
                    }
                    ForEach(individuals) { candidateRow($0) }
                } header: {
                    sectionHeader("UNASSIGNED")
                }
            }
            if !seatedElsewhere.isEmpty {
                Section {
                    ForEach(seatedElsewhere) { candidateRow($0, subtitle: moveNote(for: $0)) }
                } header: {
                    sectionHeader("SEATED ELSEWHERE")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Brand.canvas)
        .scrollDismissesKeyboard(.immediately)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Brand.textSecondary)
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 6, trailing: 20))
    }

    /// Party name + select-all toggle for households with multiple candidates.
    private func partyHeaderRow(_ block: PartyBlock) -> some View {
        let ids = Set(block.guests.map(\.id))
        let allPicked = ids.isSubset(of: selection)
        return HStack {
            TagPill.household(block.name)
            Spacer()
            Button(allPicked ? "Deselect all" : "Select all (\(block.guests.count))") {
                if allPicked { selection.subtract(ids) } else { selection.formUnion(ids) }
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Brand.accent)
        }
        .padding(.vertical, 2)
        .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 4, trailing: 20))
        .listRowBackground(Brand.canvas)
        .listRowSeparator(.hidden)
    }

    private func candidateRow(_ guest: Guest, subtitle: String? = nil) -> some View {
        let picked = selection.contains(guest.id)
        return Button {
            if picked { selection.remove(guest.id) } else { selection.insert(guest.id) }
        } label: {
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
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Brand.warningText)
                    }
                }
                Spacer()
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(picked ? Brand.accent : Brand.slate400)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
        .listRowBackground(Brand.card)
        .listRowSeparatorTint(Brand.hairline)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    /// "Moving from X" note for candidates already seated at another table.
    private func moveNote(for guest: Guest) -> String? {
        guard let tableId = guest.tableId,
              let name = store.tables.first(where: { $0.id == tableId })?.name else { return nil }
        return "Moving from \(name)"
    }

    // MARK: - Capacity badge / CTA

    /// Live "N left" / "N over" count in the nav bar as guests are picked.
    private var seatsLeftBadge: some View {
        let remaining = open - selection.count
        return Text(remaining >= 0 ? "\(remaining) left" : "\(-remaining) over")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(remaining > 0 ? Brand.textSecondary : Brand.warningText)
    }

    /// Pinned so the seat action and over-capacity warning stay reachable no
    /// matter how long the guest list is.
    private var seatCTABar: some View {
        VStack(spacing: 10) {
            if projectedOver > 0 {
                Label("This would seat \(seatedCount + selection.count) guests at \(table.name), which has \(capacity) seats. Unseat someone or edit the table to add more.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.warningText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                seatSelected()
            } label: {
                Text(selection.isEmpty
                     ? "Select guests to seat"
                     : "Seat \(selection.count) guest\(selection.count == 1 ? "" : "s")")
            }
            .buttonStyle(.primaryBrand)
            .disabled(selection.isEmpty || isSaving)
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

    private func seatSelected() {
        let picks = candidates.filter { selection.contains($0.id) }
        guard !picks.isEmpty else { return }
        isSaving = true
        Task {
            await store.assignWithUndo(picks, toTable: table.id)
            dismiss()
        }
    }

    // MARK: - Empty states

    private func emptyState(_ title: String, detail: String) -> some View {
        ContentUnavailableView(title,
                               systemImage: "person.2",
                               description: Text(detail))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brand.canvas)
    }
}
