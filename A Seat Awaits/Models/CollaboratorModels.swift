//
//  CollaboratorModels.swift
//  A Seat Awaits
//
//  Native models for the Account → Collaborators management screen, plus the
//  pure aggregation that turns raw Supabase rows (owned events, active shares,
//  pending invitations, resolved names) into a `CollaboratorsOverview`.
//
//  Everything here is value-type and side-effect free so it can be unit tested
//  without touching the network. The store (`CollaboratorsStore`) is responsible
//  for loading the rows; this file only shapes them.
//

import Foundation

// MARK: - Supabase row DTOs

/// One owned event (`public.events` where `owner_id = auth.uid()`).
nonisolated struct OwnedEventRow: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String?
    var ownerId: String?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case ownerId = "owner_id"
        case createdAt = "created_at"
    }

    var displayName: String { name?.nilIfBlank ?? "Untitled event" }
}

/// One active share (`public.event_shares`).
nonisolated struct EventShareRecord: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let eventId: String
    let email: String
    var role: String?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, email, role
        case eventId = "event_id"
        case createdAt = "created_at"
    }
}

/// One pending invitation (`public.event_invitations`, status = pending).
nonisolated struct PendingInvitationRecord: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let eventId: String
    var inviterId: String?
    var inviteeName: String?
    var inviteeEmail: String?
    var role: String?
    var status: String?
    /// The opaque accept token (`{site}/invite/{token}`). Only fetched where the
    /// copy-invite-link affordance needs it; nil elsewhere.
    var token: String?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, role, status, token
        case eventId = "event_id"
        case inviterId = "inviter_id"
        case inviteeName = "invitee_name"
        case inviteeEmail = "invitee_email"
        case createdAt = "created_at"
    }
}

/// One row from the `resolve_collaborator_names(p_emails)` RPC.
nonisolated struct ResolvedCollaboratorName: Codable, Equatable, Sendable {
    let email: String
    var fullName: String?

    enum CodingKeys: String, CodingKey {
        case email
        case fullName = "full_name"
    }
}

// MARK: - Aggregated domain models

/// Viewer or Editor. The DB `share_role` enum only ever holds these two values;
/// ownership is derived separately from `events.owner_id` and is never a share.
nonisolated enum CollaboratorRole: String, Sendable, Equatable, CaseIterable {
    case viewer
    case editor

    /// Lenient mapping from the raw DB enum string (defaults to viewer).
    init(dbValue: String?) {
        self = (dbValue?.lowercased() == "editor") ? .editor : .viewer
    }

    var label: String { self == .editor ? "Editor" : "Viewer" }
    /// PostgREST update payload value.
    var dbValue: String { rawValue }
}

/// Active (an existing share) or Pending (an unaccepted invitation).
nonisolated enum CollaboratorState: Sendable, Equatable {
    case active
    case pending
}

/// One person's access on one specific event — either an active share or a
/// pending invitation. `id` is the underlying `event_shares.id` (active) or
/// `event_invitations.id` (pending), which is also what mutations key on.
nonisolated struct EventCollaborator: Identifiable, Equatable, Sendable {
    let id: String
    let eventId: String
    let displayName: String
    /// Original-case email retained for display / VoiceOver.
    let email: String
    /// Trimmed, lowercased email used for grouping.
    let normalizedEmail: String
    let role: CollaboratorRole
    let state: CollaboratorState
    /// Accept token for a pending invitation (so an invite link can be rebuilt
    /// for sharing). Always nil for active shares.
    var inviteToken: String? = nil

    var isActive: Bool { state == .active }
    var isPending: Bool { state == .pending }
}

/// Per-event status used to color the usage row.
nonisolated enum CollaboratorUsageLevel: Sendable, Equatable {
    case normal
    case warning
    case limitReached
}

/// One owned event with its collaborators (active + pending) and limit.
nonisolated struct CollaboratorEventSummary: Identifiable, Equatable, Sendable {
    let eventId: String
    let eventName: String
    /// Active shares first, then pending invitations, each alphabetized.
    let collaborators: [EventCollaborator]
    let maxCount: Int

    var id: String { eventId }

    var currentCount: Int { collaborators.count }
    var activeCount: Int { collaborators.lazy.filter(\.isActive).count }
    var pendingCount: Int { collaborators.lazy.filter(\.isPending).count }

    /// True when collaboration is enabled (maxCount > 0) and the event has
    /// reached its per-event plan limit.
    var isAtLimit: Bool { maxCount > 0 && currentCount >= maxCount }

    var usageLevel: CollaboratorUsageLevel {
        guard maxCount > 0 else { return .normal }
        if currentCount >= maxCount { return .limitReached }
        if currentCount >= maxCount - 1 { return .warning }
        return .normal
    }
}

/// One unique person across every owned event. The same email shared on three
/// events is a single `GlobalCollaborator` with three `entries`.
nonisolated struct GlobalCollaborator: Identifiable, Equatable, Sendable {
    let normalizedEmail: String
    /// Original-case email for display.
    let email: String
    let displayName: String
    /// Every per-event access grant (active and pending) for this person.
    let entries: [EventCollaborator]

    var id: String { normalizedEmail }

    /// Distinct events this person can access (active or pending).
    var eventCount: Int { Set(entries.map(\.eventId)).count }

    var activeEntries: [EventCollaborator] { entries.filter(\.isActive) }
    var pendingEntries: [EventCollaborator] { entries.filter(\.isPending) }

    /// "Viewer" / "Editor" if consistent across all events, otherwise
    /// "Mixed roles".
    var globalRoleLabel: String {
        let roles = Set(entries.map(\.role))
        guard let only = roles.first, roles.count == 1 else { return "Mixed roles" }
        return only.label
    }
}

/// The whole management screen's data.
nonisolated struct CollaboratorsOverview: Equatable, Sendable {
    let policy: CollaborationPlanPolicy
    /// Every owned event, sorted by name (includes events with no collaborators).
    let events: [CollaboratorEventSummary]
    /// Every unique person, sorted by display name.
    let people: [GlobalCollaborator]

    /// Active access grants (one person on three events counts as three).
    var activeCollaboratorCount: Int {
        events.reduce(0) { $0 + $1.activeCount }
    }

    /// Pending invitations across owned events.
    var pendingInvitationCount: Int {
        events.reduce(0) { $0 + $1.pendingCount }
    }

    /// Distinct people across active shares and pending invitations.
    var uniquePeopleCount: Int { people.count }

    /// True when there are no collaborators or invitations at all.
    var isEmpty: Bool { activeCollaboratorCount == 0 && pendingInvitationCount == 0 }
}

// MARK: - Aggregation

extension CollaboratorsOverview {

    /// Trimmed, case-insensitive email key used for grouping people.
    static func normalize(email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Active-before-pending, then alphabetical by display name.
    private static func order(_ a: EventCollaborator, _ b: EventCollaborator) -> Bool {
        if a.state != b.state { return a.isActive && b.isPending }
        return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
    }

    /// Builds the overview from raw Supabase rows. `resolvedNames` is keyed by
    /// normalized email. Shares / invitations referencing a non-owned event are
    /// ignored defensively (RLS should already exclude them).
    static func build(policy: CollaborationPlanPolicy,
                      ownedEvents: [OwnedEventRow],
                      shares: [EventShareRecord],
                      invitations: [PendingInvitationRecord],
                      resolvedNames: [String: String]) -> CollaboratorsOverview {
        let ownedIDs = Set(ownedEvents.map(\.id))
        var entries: [EventCollaborator] = []

        for share in shares where ownedIDs.contains(share.eventId) {
            let normalized = normalize(email: share.email)
            let name = resolvedNames[normalized]?.nilIfBlank ?? share.email
            entries.append(EventCollaborator(
                id: share.id,
                eventId: share.eventId,
                displayName: name,
                email: share.email,
                normalizedEmail: normalized,
                role: CollaboratorRole(dbValue: share.role),
                state: .active))
        }

        for invite in invitations where ownedIDs.contains(invite.eventId) {
            let email = invite.inviteeEmail ?? ""
            let normalized = normalize(email: email)
            let resolved = resolvedNames[normalized]?.nilIfBlank
            let name = invite.inviteeName?.nilIfBlank
                ?? resolved
                ?? (email.isEmpty ? "Invited guest" : email)
            entries.append(EventCollaborator(
                id: invite.id,
                eventId: invite.eventId,
                displayName: name,
                email: email,
                normalizedEmail: normalized,
                role: CollaboratorRole(dbValue: invite.role),
                state: .pending,
                inviteToken: invite.token))
        }

        // Per-event summaries — every owned event, even empty ones.
        let entriesByEvent = Dictionary(grouping: entries, by: \.eventId)
        let events = ownedEvents
            .map { event -> CollaboratorEventSummary in
                let list = (entriesByEvent[event.id] ?? []).sorted(by: order)
                return CollaboratorEventSummary(
                    eventId: event.id,
                    eventName: event.displayName,
                    collaborators: list,
                    maxCount: policy.maxCollaboratorsPerEvent)
            }
            .sorted { $0.eventName.localizedCaseInsensitiveCompare($1.eventName) == .orderedAscending }

        // Unique people across all events.
        let entriesByPerson = Dictionary(grouping: entries, by: \.normalizedEmail)
        let people = entriesByPerson
            .map { normalized, list -> GlobalCollaborator in
                let sorted = list.sorted(by: order)
                return GlobalCollaborator(
                    normalizedEmail: normalized,
                    email: sorted.first?.email ?? normalized,
                    displayName: sorted.first?.displayName ?? normalized,
                    entries: sorted)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        return CollaboratorsOverview(policy: policy, events: events, people: people)
    }
}
