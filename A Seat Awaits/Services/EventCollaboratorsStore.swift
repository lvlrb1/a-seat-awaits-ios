//
//  EventCollaboratorsStore.swift
//  A Seat Awaits
//
//  Backs the per-event Collaborators screen reached from an event's More tab.
//  Unlike the account-wide `CollaboratorsStore`, this is scoped to a single
//  event and adds the *invite* path: the owner can grant a person access by
//  inserting a pending `event_invitations` row directly (RLS allows the owner),
//  mirroring the web's `POST /api/events/invite` exactly — token, payload, and
//  per-event plan limit. No email is sent (no web/email backend is reachable
//  from the native app); the invitee accepts in-app via the existing pending-
//  invites flow, or the owner shares the generated `{site}/invite/{token}` link.
//
//  Everything flows through the authenticated `SupabaseClient` (PostgREST + RPC,
//  RLS-enforced). No Nuxt/web API, no secrets. See [[collaborators-screen]].
//

import Foundation

@MainActor
@Observable
final class EventCollaboratorsStore {

    let event: Event
    private let supabase: SupabaseClient
    private let siteURL: URL

    /// Active shares first, then pending invitations (each alphabetized). The
    /// owner is not included here — the view renders the owner separately.
    private(set) var collaborators: [EventCollaborator] = []
    private(set) var policy: CollaborationPlanPolicy = .free

    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var errorMessage: String?

    // Row-scoped operation state so one mutation never freezes the whole screen.
    private(set) var isInviting = false
    private(set) var updatingRoleIDs: Set<String> = []
    private(set) var deletingIDs: Set<String> = []

    // Cached authoritative rows backing the current list.
    private var shares: [EventShareRecord] = []
    private var invites: [PendingInvitationRecord] = []
    private var resolvedNames: [String: String] = [:]

    init(event: Event, supabase: SupabaseClient, siteURL: URL) {
        self.event = event
        self.supabase = supabase
        self.siteURL = siteURL
    }

    // MARK: - Derived limits (mirrors the web's per-event check)

    /// Active shares + pending invitations on this event (owner excluded).
    var currentCount: Int { collaborators.count }
    var maxCount: Int { policy.maxCollaboratorsPerEvent }
    var isAtLimit: Bool { maxCount > 0 && currentCount >= maxCount }
    /// True when the plan allows collaboration *and* the event is under its limit.
    var canInviteMore: Bool { policy.isCollaborationEnabled && !isAtLimit }

    var usageLevel: CollaboratorUsageLevel {
        guard maxCount > 0 else { return .normal }
        if currentCount >= maxCount { return .limitReached }
        if currentCount >= maxCount - 1 { return .warning }
        return .normal
    }

    // MARK: - Load

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false; hasLoaded = true }

        do {
            guard let userId = await supabase.currentUser?.id else {
                throw SupabaseError.notAuthenticated
            }
            policy = try await loadPolicy(userId: userId)
            shares = try await loadShares()
            invites = try await loadPendingInvitations(userId: userId)
            resolvedNames = try await resolveNames()
            rebuild()
        } catch {
            errorMessage = CollaboratorsStore.message(for: error)
        }
    }

    private func loadPolicy(userId: String) async throws -> CollaborationPlanPolicy {
        let rows = try await supabase.select(
            "users",
            query: [
                URLQueryItem(name: "select", value: "id,subscription_tier,subscription_status"),
                URLQueryItem(name: "id", value: "eq.\(userId)"),
            ],
            as: [UserProfile].self)
        guard let profile = rows.first else { return .free }
        return CollaborationPlanPolicy.resolve(
            subscriptionTier: profile.subscriptionTier,
            subscriptionStatus: profile.subscriptionStatus)
    }

    private func loadShares() async throws -> [EventShareRecord] {
        try await supabase.select(
            "event_shares",
            query: [
                URLQueryItem(name: "select", value: "id,event_id,email,role,created_at"),
                URLQueryItem(name: "event_id", value: "eq.\(event.id)"),
            ],
            as: [EventShareRecord].self)
    }

    private func loadPendingInvitations(userId: String) async throws -> [PendingInvitationRecord] {
        try await supabase.select(
            "event_invitations",
            query: [
                URLQueryItem(name: "select",
                             value: "id,event_id,inviter_id,invitee_name,invitee_email,role,status,token,created_at"),
                URLQueryItem(name: "inviter_id", value: "eq.\(userId)"),
                URLQueryItem(name: "event_id", value: "eq.\(event.id)"),
                URLQueryItem(name: "status", value: "eq.pending"),
            ],
            as: [PendingInvitationRecord].self)
    }

    /// Resolves display names for the share/invitation emails via the
    /// `resolve_collaborator_names` RPC. Never queries auth.users.
    private func resolveNames() async throws -> [String: String] {
        var seen = Set<String>()
        var emails: [String] = []
        for email in shares.map(\.email) + invites.compactMap(\.inviteeEmail) {
            let key = CollaboratorsOverview.normalize(email: email)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            emails.append(email)
        }
        guard !emails.isEmpty else { return [:] }

        let rows = try await supabase.rpc(
            "resolve_collaborator_names",
            params: ResolveEventNamesParams(p_emails: emails),
            as: [ResolvedCollaboratorName].self)

        var map: [String: String] = [:]
        for row in rows where row.fullName?.nilIfBlank != nil {
            map[CollaboratorsOverview.normalize(email: row.email)] = row.fullName
        }
        return map
    }

    private func rebuild() {
        var entries: [EventCollaborator] = []

        for share in shares {
            let normalized = CollaboratorsOverview.normalize(email: share.email)
            entries.append(EventCollaborator(
                id: share.id,
                eventId: share.eventId,
                displayName: resolvedNames[normalized]?.nilIfBlank ?? share.email,
                email: share.email,
                normalizedEmail: normalized,
                role: CollaboratorRole(dbValue: share.role),
                state: .active))
        }

        for invite in invites {
            let email = invite.inviteeEmail ?? ""
            let normalized = CollaboratorsOverview.normalize(email: email)
            let name = invite.inviteeName?.nilIfBlank
                ?? resolvedNames[normalized]?.nilIfBlank
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

        collaborators = entries.sorted { a, b in
            if a.state != b.state { return a.isActive && b.isPending }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    // MARK: - Invite

    /// Validates and creates a pending invitation, mirroring the web endpoint:
    /// owner-only (enforced by RLS), per-event plan limit, lowercased email,
    /// `viewer`/`editor` role, a fresh UUID token. Returns the shareable invite
    /// link on success, or nil on validation/transport failure (with
    /// `errorMessage` set). Does NOT send an email.
    @discardableResult
    func invite(name: String, email: String, role: CollaboratorRole) async -> URL? {
        guard !isInviting else { return nil }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmail = CollaboratorsOverview.normalize(email: email)

        guard !trimmedName.isEmpty else {
            errorMessage = "Enter the collaborator's name."
            return nil
        }
        guard EmailValidator.isValid(normalizedEmail) else {
            errorMessage = "Enter a valid email address."
            return nil
        }
        guard policy.isCollaborationEnabled else {
            errorMessage = "Your current plan doesn't include collaboration."
            return nil
        }
        guard !isAtLimit else {
            errorMessage = "This event already has the maximum of \(maxCount) collaborators for your \(policy.planDisplayName) plan."
            return nil
        }
        if collaborators.contains(where: { $0.normalizedEmail == normalizedEmail }) {
            errorMessage = "\(email) already has access to this event (or a pending invite)."
            return nil
        }
        guard let userId = await supabase.currentUser?.id else {
            errorMessage = "You're signed out. Please sign in again to invite collaborators."
            return nil
        }

        isInviting = true
        defer { isInviting = false }
        errorMessage = nil

        let token = UUID().uuidString.lowercased()
        do {
            let rows = try await supabase.insert(
                "event_invitations",
                values: NewInvitationDTO(
                    event_id: event.id,
                    inviter_id: userId,
                    invitee_name: trimmedName,
                    invitee_email: normalizedEmail,
                    token: token,
                    status: "pending",
                    role: role.dbValue),
                returning: [PendingInvitationRecord].self)
            guard let created = rows.first else {
                errorMessage = "The invitation could not be created. Please try again."
                return nil
            }
            invites.append(created)
            rebuild()
            return EventInviteURL.make(base: siteURL, token: created.token ?? token)
        } catch {
            errorMessage = CollaboratorsStore.message(for: error)
            return nil
        }
    }

    /// The shareable `{site}/invite/{token}` link for a pending invitation.
    func inviteLink(for collaborator: EventCollaborator) -> URL? {
        guard collaborator.isPending, let token = collaborator.inviteToken else { return nil }
        return EventInviteURL.make(base: siteURL, token: token)
    }

    // MARK: - Manage (active shares)

    func changeRole(_ collaborator: EventCollaborator, to newRole: CollaboratorRole) async {
        guard collaborator.isActive,
              collaborator.role != newRole,
              !updatingRoleIDs.contains(collaborator.id) else { return }

        updatingRoleIDs.insert(collaborator.id)
        defer { updatingRoleIDs.remove(collaborator.id) }
        errorMessage = nil

        do {
            let rows = try await supabase.update(
                "event_shares",
                values: ShareRolePatchDTO(role: newRole.dbValue),
                query: CollaboratorMutationQuery.scoped(rowID: collaborator.id, eventID: collaborator.eventId),
                returning: [EventShareRecord].self)
            guard let updated = rows.first else {
                errorMessage = "That collaborator could not be found. Refreshing…"
                await load()
                return
            }
            if let idx = shares.firstIndex(where: { $0.id == updated.id }) { shares[idx] = updated }
            rebuild()
        } catch {
            errorMessage = CollaboratorsStore.message(for: error)
        }
    }

    /// Removes an active collaborator from this event (deletes the share).
    func remove(_ collaborator: EventCollaborator) async {
        guard collaborator.isActive, !deletingIDs.contains(collaborator.id) else { return }
        deletingIDs.insert(collaborator.id)
        defer { deletingIDs.remove(collaborator.id) }
        errorMessage = nil
        do {
            try await supabase.delete(
                "event_shares",
                query: CollaboratorMutationQuery.scoped(rowID: collaborator.id, eventID: collaborator.eventId))
            shares.removeAll { $0.id == collaborator.id }
            rebuild()
        } catch {
            errorMessage = CollaboratorsStore.message(for: error)
        }
    }

    /// Revokes a pending invitation.
    func revoke(_ collaborator: EventCollaborator) async {
        guard collaborator.isPending, !deletingIDs.contains(collaborator.id) else { return }
        deletingIDs.insert(collaborator.id)
        defer { deletingIDs.remove(collaborator.id) }
        errorMessage = nil
        do {
            try await supabase.delete(
                "event_invitations",
                query: CollaboratorMutationQuery.scoped(rowID: collaborator.id, eventID: collaborator.eventId))
            invites.removeAll { $0.id == collaborator.id }
            rebuild()
        } catch {
            errorMessage = CollaboratorsStore.message(for: error)
        }
    }

    func isUpdatingRole(_ c: EventCollaborator) -> Bool { updatingRoleIDs.contains(c.id) }
    func isDeleting(_ c: EventCollaborator) -> Bool { deletingIDs.contains(c.id) }
}

// MARK: - Invite link

/// Builds the canonical invitation accept URL: `{base}/invite/{token}` — the
/// same route the web app serves (`pages/invite/[token].vue`).
nonisolated enum EventInviteURL {
    static func make(base: URL, token: String) -> URL? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var origin = base.absoluteString
        while origin.hasSuffix("/") { origin.removeLast() }
        guard !origin.isEmpty else { return nil }
        return URL(string: "\(origin)/invite/\(trimmed)")
    }
}

// MARK: - Email validation

/// Minimal, dependency-free email sanity check (matches the web's lenient
/// `z.string().email()` intent — a single `@`, a dotted domain, no spaces).
nonisolated enum EmailValidator {
    static func isValid(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              parts[1].contains("."),
              !parts[1].hasPrefix("."),
              !parts[1].hasSuffix("."),
              !email.contains(" ") else { return false }
        return true
    }
}

// MARK: - Request DTOs

private nonisolated struct ResolveEventNamesParams: Encodable, Sendable {
    let p_emails: [String]
}

private nonisolated struct NewInvitationDTO: Encodable, Sendable {
    let event_id: String
    let inviter_id: String
    let invitee_name: String
    let invitee_email: String
    let token: String
    let status: String
    let role: String
}

private nonisolated struct ShareRolePatchDTO: Encodable, Sendable {
    let role: String
}
