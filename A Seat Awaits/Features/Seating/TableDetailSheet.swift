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

    private var seated: [Guest] {
        store.guests.filter { $0.tableId == table.id }
            .sorted { $0.lastNameKey < $1.lastNameKey }
    }
    private var unassigned: [Guest] {
        store.guests.filter { !$0.isAssigned }
            .sorted { $0.lastNameKey < $1.lastNameKey }
    }
    private var capacity: Int { table.capacity ?? 0 }
    private var isFull: Bool { capacity > 0 && seated.count >= capacity }
    private var progress: Double { capacity > 0 ? Double(seated.count) / Double(capacity) : 0 }
    private var open: Int { max(0, capacity - seated.count) }

    var body: some View {
        VStack(spacing: 0) {
            Grabber().padding(.top, 10).padding(.bottom, 6)

            header

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    seatedSection
                    if !showingAssign { assignSection } else { assignPicker }
                    deleteButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 30)
            }
        }
        .background(Brand.canvas)
        .presentationDragIndicator(.hidden)
        .confirmationDialog("Delete \(table.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
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
                Text(table.name)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.02 * 22)
                    .foregroundStyle(Brand.textPrimary)
                if capacity > 0 {
                    if isFull {
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
                            Button {
                                Task { await store.assign(guest, toTable: nil) }
                            } label: {
                                Text("Unseat")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Brand.warningText)
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

    private var assignPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("ADD FROM UNASSIGNED")
                Spacer()
                Button("Done") { showingAssign = false }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Brand.accent)
            }
            if unassigned.isEmpty {
                emptyHint("Everyone is seated.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(unassigned.enumerated()), id: \.element.id) { idx, guest in
                        Button {
                            Task { await store.assign(guest, toTable: table.id) }
                        } label: {
                            guestRow(guest, trailing: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(isFull ? Brand.slate300 : Brand.accent)
                            })
                        }
                        .buttonStyle(.plain)
                        .disabled(isFull)
                        if idx < unassigned.count - 1 { rowDivider }
                    }
                }
                .brandCard()
                if isFull {
                    Text("This table is full.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.danger)
                }
            }
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
