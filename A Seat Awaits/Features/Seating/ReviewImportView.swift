//
//  ReviewImportView.swift
//  A Seat Awaits
//
//  Step 2 of the on-device import flow. Shows the structured guests parsed from
//  pasted text and lets the planner actually fix them before committing (F5):
//  every row is tappable to edit the name, household and dietary note, and to
//  resolve a "+1"/partner by naming the companion (which splits it into its own
//  guest) or keeping it as a note. Likely duplicates of existing guests are
//  flagged and default to "skip" so a re-import never silently doubles the list
//  (F6). Confirmed rows are written via `store.addGuest(...)`.
//

import SwiftUI

struct ReviewImportView: View {
    @Bindable var store: SeatingStore
    /// Called after a successful import so the presenting sheet can dismiss.
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var rows: [ReviewRow]
    @State private var editing: ReviewRow?
    @State private var isImporting = false
    @State private var importError: String?

    init(parsed: [ParsedGuest], store: SeatingStore, onFinish: @escaping () -> Void) {
        self.store = store
        self.onFinish = onFinish
        // Flag rows whose normalized name already exists in this event (F6).
        let existing = Set(store.guests.map { GuestImportParser.normalizedName($0.name) })
        _rows = State(initialValue: parsed.map { guest in
            let dupe = existing.contains(GuestImportParser.normalizedName(guest.name))
            // Duplicates default to skip; everything else imports.
            return ReviewRow(guest: guest, isDuplicate: dupe, action: dupe ? .skip : .add)
        })
    }

    // MARK: - Derived

    private var importingCount: Int { rows.filter { $0.action == .add }.count }
    private var duplicateCount: Int { rows.filter { $0.isDuplicate }.count }

    var body: some View {
        ZStack(alignment: .bottom) {
            Brand.canvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 10) {
                    legend
                        .padding(.top, 12)
                        .padding(.bottom, 2)

                    if duplicateCount > 0 {
                        duplicateNotice
                    }

                    ForEach($rows) { $row in
                        Button {
                            editing = row
                        } label: {
                            ParsedGuestRow(row: row,
                                           onToggleDuplicate: { toggle($row) })
                        }
                        .buttonStyle(.plain)
                    }

                    Color.clear.frame(height: 96)
                }
                .padding(.horizontal, 16)
            }

            confirmFooter
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                }
                .tint(Brand.accent)
            }
            ToolbarItem(placement: .principal) {
                Text("Review import")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
            }
        }
        .toolbarBackground(Brand.card, for: .navigationBar)
        .safeAreaInset(edge: .top) { summaryBanner }
        .sheet(item: $editing) { row in
            EditParsedGuestSheet(row: row) { updated, companion in
                applyEdit(updated, companion: companion)
            }
        }
        .alert("Import failed",
               isPresented: Binding(get: { importError != nil },
                                    set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .interactiveDismissDisabled(isImporting)
    }

    // MARK: - Summary banner

    private var summaryBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Brand.successText)
            Text(summaryText)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Brand.successText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(Brand.successFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.successBorder, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Brand.card)
    }

    private var summaryText: String {
        let parsed = rows.map(\.guest)
        let n = parsed.count
        let h = parsed.householdCount
        let d = parsed.dietaryCount
        return "\(n) \(n == 1 ? "guest" : "guests") parsed · \(h) \(h == 1 ? "household" : "households") · \(d) dietary \(d == 1 ? "note" : "notes")"
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 8) {
            TagPill.neutral("Name")
            TagPill.household("Household")
            TagPill.dietary("Dietary")
            Spacer(minLength: 0)
            Text("Tap a row to edit")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.textTertiary)
        }
    }

    private var duplicateNotice: some View {
        HStack(spacing: 9) {
            Image(systemName: "person.fill.questionmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Brand.warningText)
            Text("\(duplicateCount) look like \(duplicateCount == 1 ? "a duplicate" : "duplicates") of guests you already have. They're set to skip — tap a flagged row's toggle to import it anyway.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.warningText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(Brand.warningFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.warningBorder, lineWidth: 1)
        )
    }

    // MARK: - Confirm footer

    private var confirmFooter: some View {
        Button(action: { Task { await importAll() } }) {
            if isImporting {
                ProgressView().tint(.white)
            } else {
                Text(importingCount == 0
                     ? "Nothing to import"
                     : "Confirm & import \(importingCount) \(importingCount == 1 ? "guest" : "guests")")
            }
        }
        .buttonStyle(PrimaryButtonStyle(isLoading: isImporting))
        .disabled(isImporting || importingCount == 0)
        .opacity(importingCount == 0 ? 0.5 : 1)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().fill(Brand.separator).frame(height: 1), alignment: .top)
    }

    // MARK: - Mutation

    private func toggle(_ row: Binding<ReviewRow>) {
        row.wrappedValue.action = row.wrappedValue.action == .add ? .skip : .add
    }

    /// Applies an inline edit. When the planner names a "+1" companion, it's split
    /// off into its own guest row sharing the household; the original row's
    /// unresolved hint is cleared.
    private func applyEdit(_ updated: ParsedGuest, companion: String?) {
        guard let index = rows.firstIndex(where: { $0.id == updated.id }) else { return }
        var edited = updated
        let companionName = companion?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let companionName, !companionName.isEmpty {
            edited.plusOneHint = nil
            edited.needsReview = false
            let new = ParsedGuest(name: GuestImportParser.titleCasedName(companionName),
                                  group: edited.group,
                                  dietary: nil,
                                  plusOneHint: nil,
                                  needsReview: false)
            rows.insert(ReviewRow(guest: new, isDuplicate: false, action: .add), at: index + 1)
        }

        // Re-evaluate duplicate status against existing guests after a rename.
        let existing = Set(store.guests.map { GuestImportParser.normalizedName($0.name) })
        let dupe = existing.contains(GuestImportParser.normalizedName(edited.name))
        rows[index].guest = edited
        rows[index].isDuplicate = dupe
    }

    // MARK: - Import

    private func importAll() async {
        isImporting = true
        importError = nil
        defer { isImporting = false }
        do {
            for row in rows where row.action == .add {
                let guest = row.guest
                try await store.addGuest(
                    name: guest.name,
                    groupId: nil,
                    groupName: guest.group,
                    notes: guest.plusOneHint,
                    dietary: guest.dietary
                )
            }
            onFinish()
        } catch {
            importError = FriendlyError.message(for: error)
        }
    }
}

// MARK: - Review row model

/// One reviewable import row: the parsed guest plus whether it duplicates an
/// existing guest and whether it will be imported.
struct ReviewRow: Identifiable {
    var guest: ParsedGuest
    var isDuplicate: Bool
    var action: ImportAction
    var id: UUID { guest.id }

    enum ImportAction { case add, skip }
}

// MARK: - Parsed guest row

private struct ParsedGuestRow: View {
    let row: ReviewRow
    var onToggleDuplicate: () -> Void

    private var guest: ParsedGuest { row.guest }
    private var willImport: Bool { row.action == .add }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(guest.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(willImport ? Brand.textPrimary : Brand.textTertiary)
                        .strikethrough(!willImport, color: Brand.textTertiary)
                    if let hint = plusOneShort {
                        Text(hint)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Brand.textTertiary)
                    }
                }

                if hasBadges {
                    HStack(spacing: 6) {
                        if let group = guest.group {
                            TagPill.household(group)
                        }
                        if let dietary = guest.dietary {
                            TagPill.dietary(dietary)
                        }
                        if guest.needsReview {
                            TagPill(text: confirmText,
                                    fg: Brand.warningText,
                                    bg: Brand.warningFill)
                        }
                        if row.isDuplicate {
                            TagPill(text: "Duplicate",
                                    fg: Brand.warningText,
                                    bg: Brand.warningFill,
                                    icon: "person.fill.questionmark")
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            if row.isDuplicate {
                // Explicit skip/import toggle for a flagged duplicate (F6).
                Button(action: onToggleDuplicate) {
                    Text(willImport ? "Import" : "Skip")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(willImport ? Brand.successText : Brand.warningText)
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background(willImport ? Brand.successFill : Brand.warningFill, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            // The chevron now honors a real action — every row is editable (F5).
            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Brand.slate400)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background {
            if guest.needsReview || row.isDuplicate {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Brand.inviteBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Brand.warningBorder, lineWidth: 1)
                    )
            }
        }
        .modifier(NonReviewCard(highlighted: guest.needsReview || row.isDuplicate))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Tap to edit \(guest.name)")
    }

    private var hasBadges: Bool {
        guest.group != nil || guest.dietary != nil || guest.needsReview || row.isDuplicate
    }

    /// Short trailing name annotation, e.g. "+1" / "+ partner".
    private var plusOneShort: String? {
        guard let hint = guest.plusOneHint?.lowercased() else { return nil }
        if hint.contains("partner") { return "+ partner" }
        if hint.contains("guest") { return "+ guest" }
        return "+1"
    }

    private var confirmText: String {
        guard let hint = guest.plusOneHint?.lowercased() else { return "Confirm…" }
        if hint.contains("partner") { return "Confirm partner name" }
        if hint.contains("guest") { return "Confirm guest name" }
        return "Confirm +1 name"
    }
}

/// Applies the standard `.brandCard` only to plain rows (highlighted rows carry
/// their own amber styling).
private struct NonReviewCard: ViewModifier {
    let highlighted: Bool
    func body(content: Content) -> some View {
        if highlighted {
            content
        } else {
            content.brandCard(radius: 14)
        }
    }
}
