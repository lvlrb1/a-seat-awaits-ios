//
//  CollaboratorsView.swift
//  A Seat Awaits
//
//  Account → Collaborators. A fully native management screen for event owners:
//  plan-based limits, per-event usage, role changes, invitation revocation, and
//  per-event / all-event removal. All data flows through `CollaboratorsStore`
//  (Supabase PostgREST + RPCs, RLS-enforced) — no web API calls.
//

import SwiftUI

struct CollaboratorsView: View {
    let supabase: SupabaseClient

    @State private var store: CollaboratorsStore
    @State private var expandedEventIDs: Set<String> = []
    @State private var pendingAction: PendingDestructiveAction?

    // Invite flow (inviting is per-event; we pick an event, then reuse the
    // per-event store + invite form).
    @State private var showEventPicker = false
    @State private var inviteContext: InviteContext?
    @State private var isPreparingInvite = false
    @State private var isPresentingPaywall = false

    @Environment(AppState.self) private var appState

    init(supabase: SupabaseClient) {
        self.supabase = supabase
        _store = State(initialValue: CollaboratorsStore(supabase: supabase))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if let overview = store.overview {
                    CollaboratorLimitsCard(overview: overview) {
                        isPresentingPaywall = true
                    }
                    byEventSection(overview)
                } else if store.isLoading {
                    ProgressView("Loading collaborators…")
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if store.errorMessage != nil {
                    retryState
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .background(Brand.canvas.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .navigationTitle("Collaborators")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if canInvite {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { startInvite() } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                    }
                    .accessibilityLabel("Invite collaborator")
                }
            }
        }
        .task {
            if store.overview == nil { await store.load() }
        }
        .refreshable { await store.load() }
        .alert("Something went wrong",
               isPresented: Binding(get: { store.errorMessage != nil && store.overview != nil },
                                    set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .confirmationDialog(pendingAction?.title ?? "",
                            isPresented: Binding(get: { pendingAction != nil },
                                                 set: { if !$0 { pendingAction = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingAction) { action in
            Button(action.confirmLabel, role: .destructive) {
                perform(action)
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: { action in
            Text(action.message)
        }
        .sheet(isPresented: $showEventPicker) {
            InviteEventPicker(events: store.overview?.events ?? []) { summary in
                showEventPicker = false
                beginInvite(for: summary)
            }
        }
        .sheet(item: $inviteContext) { context in
            InviteCollaboratorView(store: context.store) {
                inviteContext = nil
                Task { await store.load() }
            }
        }
        .sheet(isPresented: $isPresentingPaywall, onDismiss: {
            Task { await store.load() }
        }) {
            PaywallView(supabase: supabase, appState: appState)
        }
        .overlay {
            if isPreparingInvite {
                ZStack {
                    Color.black.opacity(0.04).ignoresSafeArea()
                    ProgressView()
                }
            }
        }
    }

    // MARK: - Invite flow

    /// Inviting requires collaboration on the plan and at least one owned event.
    private var canInvite: Bool {
        guard let overview = store.overview else { return false }
        return overview.policy.isCollaborationEnabled && !overview.events.isEmpty
    }

    /// Entry point from the toolbar / empty-state button. Skips the picker when
    /// there's only one event to invite to.
    private func startInvite() {
        guard let events = store.overview?.events, !events.isEmpty else { return }
        if events.count == 1 {
            beginInvite(for: events[0])
        } else {
            showEventPicker = true
        }
    }

    /// Builds a per-event store for the chosen event, loads it (so plan limits and
    /// duplicate checks are in place), then presents the shared invite form.
    private func beginInvite(for summary: CollaboratorEventSummary) {
        let event = Event(id: summary.eventId, name: summary.eventName,
                          ownerId: appState.currentUserId ?? "")
        let inviteStore = EventCollaboratorsStore(
            event: event, supabase: supabase, siteURL: appState.publicSiteURL)
        isPreparingInvite = true
        Task {
            await inviteStore.load()
            isPreparingInvite = false
            inviteContext = InviteContext(store: inviteStore)
        }
    }

    // MARK: - By-event section

    @ViewBuilder
    private func byEventSection(_ overview: CollaboratorsOverview) -> some View {
        if overview.events.isEmpty {
            emptyState(
                title: "No events yet",
                message: "Create an event first, then invite people to collaborate on it.")
        } else if overview.isEmpty {
            VStack(spacing: 16) {
                emptyState(
                    title: "No collaborators yet",
                    message: "Invite people to collaborate on your events to manage them here.")
                if canInvite {
                    Button { startInvite() } label: {
                        Label("Invite collaborator", systemImage: "person.crop.circle.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.primaryBrand)
                    .frame(maxWidth: 280)
                }
            }
        } else {
            HStack {
                Text("Collaborators by Event")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Brand.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)

            ForEach(overview.events) { event in
                EventCollaboratorCard(
                    event: event,
                    isExpanded: expandedEventIDs.contains(event.id),
                    store: store,
                    onToggle: { toggle(event.id) },
                    onRevoke: { pendingAction = .revoke($0, eventName: event.eventName) },
                    onRemoveFromEvent: { pendingAction = .removeFromEvent($0, eventName: event.eventName) },
                    onRemoveFromAll: { collaborator in
                        if let person = overview.people.first(where: { $0.normalizedEmail == collaborator.normalizedEmail }) {
                            pendingAction = .removeFromAll(person)
                        }
                    })
            }
        }
    }

    private func toggle(_ id: String) {
        if expandedEventIDs.contains(id) {
            expandedEventIDs.remove(id)
        } else {
            expandedEventIDs.insert(id)
        }
    }

    // MARK: - States

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Brand.slate300)
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 16)
    }

    private var retryState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(Brand.warning)
            Text(store.errorMessage ?? "Couldn't load collaborators.")
                .font(.system(size: 15))
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { Task { await store.load() } }
                .buttonStyle(.secondaryOutline)
                .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(.horizontal, 16)
    }

    // MARK: - Destructive actions

    private func perform(_ action: PendingDestructiveAction) {
        switch action {
        case .revoke(let collaborator, _):
            Task { await store.revokeInvitation(collaborator) }
        case .removeFromEvent(let collaborator, _):
            Task { await store.removeFromEvent(collaborator) }
        case .removeFromAll(let person):
            Task { await store.removeFromAll(person) }
        }
        pendingAction = nil
    }
}

// MARK: - Destructive action model

private enum PendingDestructiveAction: Identifiable {
    case revoke(EventCollaborator, eventName: String)
    case removeFromEvent(EventCollaborator, eventName: String)
    case removeFromAll(GlobalCollaborator)

    var id: String {
        switch self {
        case .revoke(let c, _): return "revoke-\(c.id)"
        case .removeFromEvent(let c, _): return "remove-\(c.id)"
        case .removeFromAll(let p): return "remove-all-\(p.normalizedEmail)"
        }
    }

    var title: String {
        switch self {
        case .revoke: return "Revoke invitation"
        case .removeFromEvent: return "Remove access"
        case .removeFromAll: return "Remove from all events"
        }
    }

    var confirmLabel: String {
        switch self {
        case .revoke: return "Revoke"
        case .removeFromEvent: return "Remove"
        case .removeFromAll: return "Remove from all"
        }
    }

    var message: String {
        switch self {
        case .revoke(let c, _):
            let who = c.displayName.isEmpty ? c.email : c.displayName
            return "This invitation to \(who) will be revoked."
        case .removeFromEvent(let c, let eventName):
            return "\(c.displayName) will lose access to “\(eventName)” but will retain access to any other events you’ve shared with them."
        case .removeFromAll(let p):
            return "This will revoke \(p.displayName)’s access to every event you own and cancel their pending invitations. This action cannot be undone."
        }
    }
}

// MARK: - Invite presentation helpers

/// Identifiable wrapper so the invite form can be presented via `.sheet(item:)`
/// with a freshly built, pre-loaded per-event store.
private struct InviteContext: Identifiable {
    let id = UUID()
    let store: EventCollaboratorsStore
}

/// Lets the owner pick which event to invite someone to when they own more than
/// one. Single-event owners never see this — they go straight to the form.
private struct InviteEventPicker: View {
    let events: [CollaboratorEventSummary]
    let onSelect: (CollaboratorEventSummary) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(events) { event in
                Button { onSelect(event) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.eventName)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Brand.textPrimary)
                            Text("\(event.currentCount)/\(event.maxCount) collaborators")
                                .font(.system(size: 13))
                                .foregroundStyle(event.isAtLimit ? Brand.warningText : Brand.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Brand.slate300)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Choose an event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Limits card

private struct CollaboratorLimitsCard: View {
    let overview: CollaboratorsOverview
    let onUpgrade: () -> Void

    private var policy: CollaborationPlanPolicy { overview.policy }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.badge.gearshape")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                Text("Collaborator Limits")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                Spacer()
            }

            HStack(spacing: 10) {
                statTile(value: "\(policy.maxCollaboratorsPerEvent)", label: "Max / event")
                statTile(value: "\(overview.activeCollaboratorCount)", label: "Active")
                statTile(value: "\(overview.pendingInvitationCount)", label: "Pending")
                statTile(value: "\(overview.uniquePeopleCount)", label: "People")
            }

            HStack(spacing: 8) {
                Image(systemName: policy.isCollaborationEnabled ? "checkmark.seal.fill" : "lock.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(policy.isCollaborationEnabled ? Brand.success : Brand.slate400)
                Text(policy.availabilityMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.textSecondary)
                Spacer(minLength: 4)
            }

            HStack {
                Label("\(policy.planDisplayName) plan", systemImage: "flag.checkered")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
                Spacer()
                Button(action: onUpgrade) {
                    Text(policy.isTopTier ? "Manage Plan" : "Upgrade Plan")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Brand.accent)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the available plans")
            }
        }
        .padding(16)
        .brandCard(radius: 18)
        .accessibilityElement(children: .contain)
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Brand.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Brand.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

// MARK: - Per-event card (disclosure)

private struct EventCollaboratorCard: View {
    let event: CollaboratorEventSummary
    let isExpanded: Bool
    let store: CollaboratorsStore
    let onToggle: () -> Void
    let onRevoke: (EventCollaborator) -> Void
    let onRemoveFromEvent: (EventCollaborator) -> Void
    let onRemoveFromAll: (EventCollaborator) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                Divider().overlay(Brand.hairline)
                if event.collaborators.isEmpty {
                    Text("No collaborators for this event.")
                        .font(.system(size: 14))
                        .foregroundStyle(Brand.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(event.collaborators.enumerated()), id: \.element.id) { index, collaborator in
                            if index > 0 {
                                Divider().overlay(Brand.hairline).padding(.leading, 60)
                            }
                            CollaboratorRow(
                                collaborator: collaborator,
                                store: store,
                                onRevoke: { onRevoke(collaborator) },
                                onRemoveFromEvent: { onRemoveFromEvent(collaborator) },
                                onRemoveFromAll: { onRemoveFromAll(collaborator) })
                        }
                    }
                }
            }
        }
        .brandCard(radius: 16)
    }

    private var header: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.eventName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                        .multilineTextAlignment(.leading)
                    usageBadge
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Brand.slate300)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(event.eventName), \(event.currentCount) of \(event.maxCount) collaborators")
        .accessibilityHint(isExpanded ? "Collapses the list" : "Expands the list")
    }

    private var usageBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(usageColor)
                .frame(width: 7, height: 7)
            Text("\(event.currentCount)/\(event.maxCount)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(usageColor)
            if event.usageLevel == .limitReached {
                Text("Limit reached")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.warningText)
            }
        }
    }

    private var usageColor: Color {
        switch event.usageLevel {
        case .normal: return Brand.success
        case .warning: return Brand.warning
        case .limitReached: return Brand.danger
        }
    }
}

// MARK: - Collaborator row

private struct CollaboratorRow: View {
    let collaborator: EventCollaborator
    let store: CollaboratorsStore
    let onRevoke: () -> Void
    let onRemoveFromEvent: () -> Void
    let onRemoveFromAll: () -> Void

    private var isUpdatingRole: Bool { store.updatingRoleShareIDs.contains(collaborator.id) }
    private var isDeleting: Bool {
        store.deletingShareIDs.contains(collaborator.id)
            || store.deletingInvitationIDs.contains(collaborator.id)
            || store.removingAllEmails.contains(collaborator.normalizedEmail)
    }

    var body: some View {
        HStack(spacing: 12) {
            InitialsAvatar(name: collaborator.displayName, size: 40)
                .opacity(collaborator.isPending ? 0.6 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(collaborator.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
                if !collaborator.email.isEmpty {
                    Text(collaborator.email)
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                statePill
            }

            Spacer(minLength: 8)

            trailingControl
        }
        .padding(16)
        .opacity(isDeleting ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let stateWord = collaborator.isActive ? "Active" : "Pending"
        return "\(collaborator.displayName), \(collaborator.email), \(collaborator.role.label), \(stateWord)"
    }

    @ViewBuilder
    private var statePill: some View {
        if collaborator.isActive {
            TagPill.assigned("Active")
        } else {
            Text("Will be \(collaborator.role.label)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Brand.warningText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Brand.warningFill, in: Capsule())
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isDeleting {
            ProgressView()
        } else if collaborator.isActive {
            HStack(spacing: 8) {
                RoleToggle(
                    role: collaborator.role,
                    isBusy: isUpdatingRole,
                    onSelect: { newRole in
                        Task { await store.changeRole(collaborator: collaborator, to: newRole) }
                    })
                Menu {
                    Button(role: .destructive, action: onRemoveFromEvent) {
                        Label("Remove from this event", systemImage: "person.badge.minus")
                    }
                    Button(role: .destructive, action: onRemoveFromAll) {
                        Label("Remove from all events", systemImage: "person.2.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Brand.slate400)
                }
                .accessibilityLabel("More actions for \(collaborator.displayName)")
            }
        } else {
            Button(role: .destructive, action: onRevoke) {
                Text("Revoke")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Brand.danger)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Revoke invitation for \(collaborator.displayName)")
        }
    }
}

// MARK: - Role toggle (Viewer / Editor)

private struct RoleToggle: View {
    let role: CollaboratorRole
    let isBusy: Bool
    let onSelect: (CollaboratorRole) -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                segment(.viewer)
                segment(.editor)
            }
            .padding(2)
            .background(Brand.control, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(isBusy ? 0 : 1)

            if isBusy {
                ProgressView()
            }
        }
        .disabled(isBusy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Role")
        .accessibilityValue(role.label)
        .accessibilityHint("Double tap to switch between Viewer and Editor")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: role == .viewer ? "Make Editor" : "Make Viewer") {
            onSelect(role == .viewer ? .editor : .viewer)
        }
    }

    private func segment(_ option: CollaboratorRole) -> some View {
        let selected = role == option
        return Button {
            if !selected { onSelect(option) }
        } label: {
            Text(option.label)
                .font(.system(size: 12, weight: selected ? .bold : .semibold))
                .foregroundStyle(selected ? Brand.textPrimary : Brand.textSecondary)
                .frame(width: 52, height: 26)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Brand.card)
                            .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }
}
