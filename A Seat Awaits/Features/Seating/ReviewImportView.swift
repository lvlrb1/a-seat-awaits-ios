//
//  ReviewImportView.swift
//  A Seat Awaits
//
//  Step 2 of the import flow. Shows the guests the AI extracted (or, offline, the
//  on-device parser) and lets the planner shape the list before it commits: every
//  row is tappable to edit, and every row has an include/skip toggle so a 250-name
//  list can be trimmed to the ones that matter. Names the AI inferred (e.g. a
//  child's last name) get an amber "Review" highlight, optional; saving an edit
//  clears the flag. Likely duplicates of existing guests are flagged and default
//  to "skip" so a re-import never silently doubles the list (F6).
//
//  The screen is capacity-aware: it knows how many guest slots the event's plan or
//  pass has left, pre-selects only what fits, and blocks the confirm button (with
//  a "deselect N" line and a plans link) rather than letting the import run into
//  the cap mid-flight. If an import does stop early anyway, the rows that landed
//  are dropped from the list and the planner gets a clear Done, never a dead end.
//  Rows are written in one batched call via `store.addGuests(...)`.
//

import SwiftUI

struct ReviewImportView: View {
    @Bindable var store: SeatingStore
    /// Called when the import flow is over, successfully or not, so the presenting
    /// sheet can dismiss.
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var rows: [ReviewRow]
    @State private var editing: ReviewRow?
    @State private var search = ""
    @State private var isImporting = false
    /// Running total reported by the batched insert, so a mid-flight failure can
    /// say exactly how many guests landed.
    @State private var importProgress = 0
    @State private var importError: String?
    /// Non-nil once an import stopped early: how many guests made it in.
    @State private var stoppedAfter: Int?
    @State private var didSucceed = false
    @State private var importedCount = 0
    @State private var showingPaywall = false

    init(parsed: [ParsedGuest], store: SeatingStore, onFinish: @escaping () -> Void) {
        self.store = store
        self.onFinish = onFinish
        // Flag rows whose normalized name already exists in this event (F6).
        let existing = Set(store.guests.map { GuestImportParser.normalizedName($0.name) })
        var built = parsed.map { guest -> ReviewRow in
            let dupe = existing.contains(GuestImportParser.normalizedName(guest.name))
            // Duplicates default to skip; everything else imports.
            return ReviewRow(guest: guest, isDuplicate: dupe, action: dupe ? .skip : .add)
        }
        // Pre-select only what the event's remaining capacity can hold. The
        // overflow arrives skipped rather than erroring out halfway through, and
        // the planner can swap any of it in.
        if let room = store.remainingGuestCapacity {
            var used = 0
            for index in built.indices where built[index].action == .add {
                if used < room { used += 1 } else { built[index].action = .skip }
            }
        }
        _rows = State(initialValue: built)
    }

    // MARK: - Derived

    private var importingCount: Int { rows.filter { $0.action == .add }.count }
    private var skippedCount: Int { rows.filter { $0.action == .skip }.count }
    private var duplicateCount: Int { rows.filter { $0.isDuplicate }.count }
    private var confirmCount: Int { rows.filter { $0.guest.needsReview }.count }

    /// Guest slots left on the event right now. `nil` while the entitlement is
    /// still loading, in which case capacity never blocks anything.
    private var room: Int? { store.remainingGuestCapacity }

    /// How many selected guests exceed the remaining capacity.
    private var overBy: Int {
        guard let room else { return 0 }
        return max(0, importingCount - room)
    }

    /// True when the list is bigger than the event can hold, so the capacity
    /// explainer is worth the space.
    private var showsCapacityNotice: Bool {
        guard let room else { return false }
        return rows.count > room || overBy > 0
    }

    private var canImport: Bool { importingCount > 0 && overBy == 0 }

    /// Rows matching the search box, in list order.
    private var visibleRows: [ReviewRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return rows }
        return rows.filter {
            $0.guest.name.lowercased().contains(query)
            || ($0.guest.group?.lowercased().contains(query) ?? false)
        }
    }

    /// The search box only earns its place on a list long enough to get lost in.
    private var showsSearch: Bool { rows.count > 20 }

    var body: some View {
        ZStack(alignment: .bottom) {
            Brand.canvas.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 10) {
                    legend
                        .padding(.top, 12)
                        .padding(.bottom, 2)

                    if let landed = stoppedAfter, landed > 0 {
                        stoppedNotice(landed)
                    }

                    if showsCapacityNotice {
                        capacityNotice
                    }

                    if duplicateCount > 0 {
                        duplicateNotice
                    }

                    if visibleRows.isEmpty {
                        noMatchesNotice
                    }

                    ForEach(visibleRows) { row in
                        Button {
                            editing = row
                        } label: {
                            ParsedGuestRow(row: row,
                                           blockedByCapacity: showsCapacityNotice
                                               && row.action == .skip && !row.isDuplicate,
                                           onToggle: { toggle(row.id) })
                        }
                        .buttonStyle(.plain)
                    }

                    Color.clear.frame(height: 96)
                }
                .padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.interactively)

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
                .disabled(isImporting)
            }
            ToolbarItem(placement: .principal) {
                Text("Review import")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                selectionMenu
            }
        }
        .toolbarBackground(Brand.card, for: .navigationBar)
        .safeAreaInset(edge: .top) { header }
        .sheet(item: $editing) { row in
            EditParsedGuestSheet(
                row: row,
                onSave: { updated, companion in applyEdit(updated, companion: companion) },
                onRemove: { removeRow(row) })
        }
        .sheet(isPresented: $showingPaywall, onDismiss: {
            Task { await store.loadEntitlement() }
        }) {
            if let supabase = appState.supabase {
                PaywallView(supabase: supabase, appState: appState,
                            mode: .plans(eventId: store.event.id))
            }
        }
        .alert(stoppedAfter == nil ? "Import failed" : "Import stopped early",
               isPresented: Binding(get: { importError != nil },
                                    set: { if !$0 { importError = nil } })) {
            if let landed = stoppedAfter, landed > 0 {
                Button("Done") { onFinish() }
                Button("Keep editing", role: .cancel) { importError = nil }
            } else {
                Button("OK", role: .cancel) { importError = nil }
            }
        } message: {
            Text(alertMessage)
        }
        .interactiveDismissDisabled(isImporting || didSucceed)
        .overlay {
            if didSucceed {
                ImportSuccessOverlay(count: importedCount)
                    .transition(.opacity)
            }
        }
        .sensoryFeedback(.success, trigger: didSucceed)
    }

    private var alertMessage: String {
        guard let landed = stoppedAfter, landed > 0 else { return importError ?? "" }
        let noun = landed == 1 ? "guest is" : "guests are"
        return "\(landed) \(noun) on your guest list. \(importError ?? "") The rest are still here to review."
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            summaryBanner
            if showsSearch {
                SearchField(text: $search, placeholder: "Search this import", height: 42)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 8)
        .background(Brand.card)
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
    }

    private var summaryText: String {
        let parsed = rows.map(\.guest)
        let n = parsed.count
        var parts = ["\(n) \(n == 1 ? "guest" : "guests")"]
        // Household / dietary only appear when actually present (the AI import is
        // names-only; the offline fallback parser may still fill them).
        let h = parsed.householdCount
        let d = parsed.dietaryCount
        if h > 0 { parts.append("\(h) \(h == 1 ? "household" : "households")") }
        if d > 0 { parts.append("\(d) dietary \(d == 1 ? "note" : "notes")") }
        if confirmCount > 0 { parts.append("\(confirmCount) to review") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 8) {
            Text(confirmCount > 0
                 ? "Highlighted rows are worth a quick review. Tap a row to edit it, or use the circle to leave someone out."
                 : "Tap a row to edit it, or use the circle to leave someone out.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Brand.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Selection menu

    private var selectionMenu: some View {
        Menu {
            Button {
                selectUpToCapacity()
            } label: {
                Label(room == nil ? "Select everyone" : "Select as many as fit",
                      systemImage: "checkmark.circle")
            }
            Button {
                setAll(.skip)
            } label: {
                Label("Deselect everyone", systemImage: "circle")
            }
            if duplicateCount > 0 {
                Button {
                    skipDuplicates()
                } label: {
                    Label("Skip \(duplicateCount) duplicate\(duplicateCount == 1 ? "" : "s")",
                          systemImage: "person.fill.questionmark")
                }
            }
            if skippedCount > 0 {
                Divider()
                Button(role: .destructive) {
                    removeSkipped()
                } label: {
                    Label("Remove \(skippedCount) skipped from list", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Brand.accent)
        }
        .disabled(isImporting)
    }

    // MARK: - Notices

    /// Explains the plan/pass ceiling and what was pre-selected because of it.
    private var capacityNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(overBy > 0 ? "More guests selected than your plan allows"
                             : "This list is larger than your plan allows",
                  systemImage: "person.2.slash")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Brand.warningText)
            Text(capacityText)
                .font(.system(size: 12))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button("View plans") { showingPaywall = true }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                if overBy > 0 {
                    Button("Select as many as fit") { selectUpToCapacity() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.accent)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.warningFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.warningBorder, lineWidth: 1)
        )
    }

    private var capacityText: String {
        guard let room else { return "" }
        let cap = store.entitlement.guestCap
        let source = store.entitlement.guestCapSourceLabel
        let have = store.guests.count
        let base = have > 0
            ? "This event holds \(cap) guests on \(source) and already has \(have), so there's room for \(room) more."
            : "This event holds \(cap) guests on \(source), so there's room for \(room)."
        if overBy > 0 {
            return "\(base) You have \(importingCount) selected. Leave \(overBy) out, or upgrade for more room."
        }
        return "\(base) The first \(room) are selected. Swap anyone in or out, or upgrade to bring the whole list."
    }

    private var duplicateNotice: some View {
        HStack(spacing: 9) {
            Image(systemName: "person.fill.questionmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Brand.warningText)
            Text("\(duplicateCount) look like \(duplicateCount == 1 ? "a duplicate" : "duplicates") of guests you already have. They're set to skip. Tap a flagged row's circle to import it anyway.")
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

    /// Shown after an import stopped part way: what landed, and that the rest is
    /// still here. The alert's Done button closes the flow outright.
    private func stoppedNotice(_ landed: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Brand.successText)
            Text("\(landed) \(landed == 1 ? "guest" : "guests") already imported and removed from this list. Adjust what's left, or tap Done to finish.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.successText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(Brand.successFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.successBorder, lineWidth: 1)
        )
    }

    private var noMatchesNotice: some View {
        Text("No one in this import matches \"\(search)\".")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Brand.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 18)
    }

    // MARK: - Confirm footer

    private var confirmFooter: some View {
        VStack(spacing: 10) {
            Text(footerStatus)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(overBy > 0 ? Brand.warningText : Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 12) {
                if stoppedAfter != nil {
                    Button("Done") { onFinish() }
                        .buttonStyle(.secondaryOutline)
                        .disabled(isImporting)
                }

                Button(action: { Task { await importAll() } }) {
                    if isImporting {
                        ProgressView().tint(.white)
                    } else {
                        Text(confirmTitle)
                    }
                }
                .buttonStyle(PrimaryButtonStyle(isLoading: isImporting))
                .disabled(isImporting || !canImport)
                .opacity(canImport ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().fill(Brand.separator).frame(height: 1), alignment: .top)
    }

    private var confirmTitle: String {
        if overBy > 0 { return "Leave out \(overBy) to continue" }
        if importingCount == 0 { return "Nothing selected" }
        return "Confirm & import \(importingCount) \(importingCount == 1 ? "guest" : "guests")"
    }

    private var footerStatus: String {
        if isImporting {
            return importProgress > 0
                ? "Importing \(importProgress) of \(importingCount)."
                : "Importing \(importingCount) \(importingCount == 1 ? "guest" : "guests")."
        }
        var parts = ["\(importingCount) selected"]
        if skippedCount > 0 { parts.append("\(skippedCount) left out") }
        if let room, overBy == 0, room - importingCount > 0 {
            parts.append("room for \(room - importingCount) more after this")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Mutation

    private func toggle(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].action = rows[index].action == .add ? .skip : .add
    }

    private func setAll(_ action: ReviewRow.ImportAction) {
        withAnimation(.easeInOut(duration: 0.15)) {
            for index in rows.indices { rows[index].action = action }
        }
    }

    /// Selects rows from the top until the event's remaining capacity is full,
    /// leaving flagged duplicates for last so a re-import doesn't spend the
    /// remaining slots on names the planner already has.
    private func selectUpToCapacity() {
        withAnimation(.easeInOut(duration: 0.15)) {
            let limit = room ?? rows.count
            var used = 0
            for index in rows.indices where !rows[index].isDuplicate {
                if used < limit { rows[index].action = .add; used += 1 }
                else { rows[index].action = .skip }
            }
            for index in rows.indices where rows[index].isDuplicate {
                if used < limit, rows[index].action == .add { used += 1 }
                else { rows[index].action = .skip }
            }
        }
    }

    private func skipDuplicates() {
        withAnimation(.easeInOut(duration: 0.15)) {
            for index in rows.indices where rows[index].isDuplicate {
                rows[index].action = .skip
            }
        }
    }

    /// Clears everything currently left out, so a trimmed list reads clean.
    private func removeSkipped() {
        withAnimation(.easeInOut(duration: 0.2)) {
            rows.removeAll { $0.action == .skip }
        }
    }

    /// Drops a guest from the import entirely.
    private func removeRow(_ row: ReviewRow) {
        withAnimation(.easeInOut(duration: 0.2)) {
            rows.removeAll { $0.id == row.id }
        }
    }

    /// Applies an inline edit. When the planner names a "+1" companion, it's split
    /// off into its own guest row sharing the household; the original row's
    /// unresolved hint is cleared.
    private func applyEdit(_ updated: ParsedGuest, companion: String?) {
        guard let index = rows.firstIndex(where: { $0.id == updated.id }) else { return }
        var edited = updated
        // Tapping a row and saving is the confirmation — clear the amber flag.
        edited.needsReview = false
        let companionName = companion?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let companionName, !companionName.isEmpty {
            edited.plusOneHint = nil
            let new = ParsedGuest(name: GuestImportParser.titleCasedName(companionName),
                                  group: edited.group,
                                  dietary: nil,
                                  plusOneHint: nil,
                                  needsReview: false)
            // A split companion only joins the import if there's room for it.
            let fits = room.map { importingCount < $0 } ?? true
            rows.insert(ReviewRow(guest: new, isDuplicate: false, action: fits ? .add : .skip),
                        at: index + 1)
        }

        // Re-evaluate duplicate status against existing guests after a rename.
        let existing = Set(store.guests.map { GuestImportParser.normalizedName($0.name) })
        let dupe = existing.contains(GuestImportParser.normalizedName(edited.name))
        rows[index].guest = edited
        rows[index].isDuplicate = dupe
    }

    // MARK: - Import

    private func importAll() async {
        let selected = rows.filter { $0.action == .add }
        guard !selected.isEmpty else { return }

        isImporting = true
        importError = nil
        importProgress = 0

        let drafts = selected.map {
            NewGuestDraft(name: $0.guest.name,
                          groupName: $0.guest.group,
                          notes: $0.guest.plusOneHint,
                          dietary: $0.guest.dietary)
        }

        do {
            let count = try await store.addGuests(drafts) { done in importProgress = done }
            importedCount = count
            // Celebrate, then dismiss once the animation has had a beat to play.
            withAnimation(.easeInOut(duration: 0.25)) {
                isImporting = false
                didSucceed = true
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            onFinish()
        } catch {
            // Whatever landed before the failure is already on the guest list, so
            // drop those rows here. Retrying can't double them up, and the counts
            // on screen stay true.
            let landed = importProgress
            if landed > 0 {
                let importedIDs = Set(selected.prefix(landed).map(\.id))
                withAnimation(.easeInOut(duration: 0.2)) {
                    rows.removeAll { importedIDs.contains($0.id) }
                }
                stoppedAfter = (stoppedAfter ?? 0) + landed
            }
            isImporting = false
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
    /// True when the list is over the event's guest cap and this row is one of
    /// the ones left out because of it. Earns a quiet pill, not the amber card,
    /// since a long overflow would otherwise light up the whole screen.
    var blockedByCapacity: Bool
    var onToggle: () -> Void

    private var guest: ParsedGuest { row.guest }
    private var willImport: Bool { row.action == .add }

    var body: some View {
        HStack(spacing: 12) {
            // Include / leave out. The primary way to shape a long import, and
            // reversible, unlike deleting the row.
            Button(action: onToggle) {
                Image(systemName: willImport ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(willImport ? Brand.accent : Brand.slate400)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(willImport ? "Leave out \(guest.name)" : "Include \(guest.name)")

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
                        if blockedByCapacity {
                            TagPill(text: "No room on your plan",
                                    fg: Brand.textTertiary,
                                    bg: Brand.control,
                                    icon: "person.2.slash")
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            // The chevron signals the row is tappable to edit (F5).
            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Brand.slate400)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Brand.inviteBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Brand.warningBorder, lineWidth: 1)
                    )
            }
        }
        .modifier(NonReviewCard(highlighted: highlighted))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Tap to edit \(guest.name)")
    }

    private var highlighted: Bool { guest.needsReview || row.isDuplicate }

    private var hasBadges: Bool {
        guest.group != nil || guest.dietary != nil || guest.needsReview
        || row.isDuplicate || blockedByCapacity
    }

    /// Short trailing name annotation, e.g. "+1" / "+ partner".
    private var plusOneShort: String? {
        guard let hint = guest.plusOneHint?.lowercased() else { return nil }
        if hint.contains("partner") { return "+ partner" }
        if hint.contains("guest") { return "+ guest" }
        return "+1"
    }

    private var confirmText: String {
        guard let hint = guest.plusOneHint?.lowercased() else { return "Review" }
        if hint.contains("partner") { return "Review partner name" }
        if hint.contains("guest") { return "Review guest name" }
        return "Review +1 name"
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
