//
//  GuestListView.swift
//  A Seat Awaits
//
//  The "Guests" tab of the event workspace: persistent search, count filter
//  chips, a clean guest list with status pills, and a seated-progress footer
//  with an Import action. Section 03 of the design spec.
//

import SwiftUI

struct GuestListView: View {
    @Bindable var store: SeatingStore

    @State private var search = ""
    @State private var filter: GuestFilter = .all
    @State private var groupFilter: String?
    @State private var sort: GuestSort = .lastNameAZ
    @State private var detailGuest: Guest?
    @State private var showingImport = false
    @State private var guestPendingDeletion: Guest?

    enum GuestFilter: Equatable {
        case all
        case assigned
        case open
        case households
    }

    init(store: SeatingStore) {
        self.store = store
    }

    private var visibleGuests: [Guest] {
        let base = SeatingLogic.filterAndSort(store.guests,
                                              search: search,
                                              groupId: filter == .households ? groupFilter : nil,
                                              sort: sort)
        switch filter {
        case .all, .households:
            return base
        case .assigned:
            return base.filter(\.isAssigned)
        case .open:
            return base.filter { !$0.isAssigned }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchAndFilters

            if store.guests.isEmpty {
                ContentUnavailableView("No guests yet",
                                       systemImage: "person.2",
                                       description: Text("Import or add guests, then seat them at tables."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Brand.canvas)
            } else {
                List {
                    ForEach(visibleGuests) { guest in
                        GuestRowView(guest: guest, table: store.table(withId: guest.tableId))
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Brand.card)
                            .contentShape(Rectangle())
                            .onTapGesture { detailGuest = guest }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if store.canEdit {
                                    // Deliberately NOT role: .destructive — that makes the
                                    // List collapse the row optimistically before the
                                    // confirmation dialog can show.
                                    Button {
                                        requestDelete(guest)
                                    } label: { Label("Delete", systemImage: "trash") }
                                        .tint(.red)

                                    Button {
                                        detailGuest = guest
                                    } label: { Label("Assign", systemImage: "person.crop.circle.badge.plus") }
                                        .tint(Brand.plum)
                                }
                            }
                            // Non-swipe paths for VoiceOver / Switch Control (A11y-2).
                            .contextMenu {
                                if store.canEdit {
                                    Button {
                                        detailGuest = guest
                                    } label: { Label("Assign to Table", systemImage: "person.crop.circle.badge.plus") }
                                    Button(role: .destructive) {
                                        requestDelete(guest)
                                    } label: { Label("Delete Guest", systemImage: "trash") }
                                }
                            }
                            // Attached per-row so the dialog's popover anchors to the
                            // guest being deleted rather than the top of the screen.
                            .confirmationDialog(
                                "Remove \(guest.name)?",
                                isPresented: Binding(get: { guestPendingDeletion?.id == guest.id },
                                                     set: { if !$0 { guestPendingDeletion = nil } }),
                                titleVisibility: .visible
                            ) {
                                Button("Delete Guest", role: .destructive) {
                                    guestPendingDeletion = nil
                                    Task { await store.deleteGuestWithUndo(guest) }
                                }
                                Button("Cancel", role: .cancel) { guestPendingDeletion = nil }
                            } message: {
                                Text(deletionMessage(for: guest))
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Brand.canvas)
            }

            footer
        }
        .background(Brand.canvas)
        .sheet(item: $detailGuest) { guest in
            GuestDetailSheet(store: store, guest: guest)
        }
        .sheet(isPresented: $showingImport) {
            ImportGuestsView(store: store)
        }
    }

    /// Routes a delete request: guests carrying real data (a seat, notes, dietary
    /// needs) get a confirmation; empty rows delete straight away. Both paths offer
    /// undo (F2).
    private func requestDelete(_ guest: Guest) {
        if isPopulated(guest) {
            guestPendingDeletion = guest
        } else {
            Task { await store.deleteGuestWithUndo(guest) }
        }
    }

    private func isPopulated(_ guest: Guest) -> Bool {
        guest.isAssigned
            || guest.notes?.nilIfBlank != nil
            || guest.dietaryPreference?.nilIfBlank != nil
            || guest.groupName?.nilIfBlank != nil
    }

    /// Confirmation copy that names what would be lost (F2).
    private func deletionMessage(for guest: Guest) -> String {
        var parts: [String] = []
        if let table = store.table(withId: guest.tableId) {
            parts.append("seated at \(table.name)")
        }
        if guest.dietaryPreference?.nilIfBlank != nil { parts.append("has dietary notes") }
        else if guest.notes?.nilIfBlank != nil { parts.append("has notes") }
        let detail = parts.isEmpty ? "" : " They're \(parts.joined(separator: " and "))."
        return "\(detail) You'll be able to undo for a few seconds.".trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Search + filter chips

    private var searchAndFilters: some View {
        VStack(spacing: 10) {
            SearchField(text: $search, placeholder: "Search guests", height: 42)

            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        let stats = store.stats
                        chip(.all,        title: "All",      count: stats.total,    bg: Brand.plum)
                        chip(.open,       title: "Open",     count: stats.open,     bg: Brand.warning)
                        chip(.assigned,   title: "Assigned", count: stats.assigned, bg: Brand.success)
                        chip(.households, title: "Households", count: nil,          bg: Brand.plum)
                    }
                }
                sortMenu
            }

            if filter == .households {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        groupChip(nil, label: "All groups")
                        ForEach(store.groups) { group in
                            groupChip(group.id, label: group.name)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(Brand.card)
        .overlay(Brand.hairline.frame(height: 1), alignment: .bottom)
    }

    private func chip(_ value: GuestFilter, title: String, count: Int?, bg: Color) -> some View {
        Button {
            filter = value
            if value != .households { groupFilter = nil }
        } label: {
            FilterChip(title: title, count: count, selected: filter == value, selectedBg: bg)
        }
        .buttonStyle(.plain)
    }

    private func groupChip(_ id: String?, label: String) -> some View {
        Button {
            groupFilter = id
        } label: {
            FilterChip(title: label, selected: groupFilter == id, selectedBg: Brand.purple)
        }
        .buttonStyle(.plain)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort guests", selection: $sort) {
                ForEach(GuestSort.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Brand.accent)
                .frame(width: 38, height: 32)
                .background(Brand.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                // Keep the 38×32 pill visual but guarantee a 44pt hit target (A11y-5).
                .contentShape(Rectangle())
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Sort guests")
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            HStack {
                let stats = store.stats
                Text("\(stats.assigned) of \(stats.total) seated")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                Spacer()
                if store.canEdit {
                    Button {
                        showingImport = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 14, weight: .bold))
                            Text("Import").font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(Brand.accent)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Brand.accent, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            ProgressBar(progress: fraction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            Brand.card.overlay(Brand.separator.frame(height: 1), alignment: .top)
        )
    }

    private var fraction: Double {
        let stats = store.stats
        guard stats.total > 0 else { return 0 }
        return Double(stats.assigned) / Double(stats.total)
    }
}

// MARK: - Guest row

struct GuestRowView: View {
    let guest: Guest
    let table: SeatingTable?

    var body: some View {
        HStack(spacing: 12) {
            InitialsAvatar(name: guest.name, size: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(guest.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                if let subtitle {
                    HStack(spacing: 6) {
                        Circle().fill(Brand.teal).frame(width: 8, height: 8)
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            if let table {
                TagPill.assigned(table.name)
            } else {
                TagPill.unassigned()
            }
        }
        .padding(.vertical, 14)
    }

    private var subtitle: String? {
        let group = guest.groupName?.nilIfBlank
        let diet = guest.dietaryPreference?.nilIfBlank
        switch (group, diet) {
        case let (g?, d?): return "\(g) · \(d)"
        case let (g?, nil): return g
        case let (nil, d?): return d
        default: return nil
        }
    }
}
