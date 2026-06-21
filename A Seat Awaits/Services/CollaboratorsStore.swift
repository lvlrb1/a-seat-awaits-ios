//
//  CollaboratorsStore.swift
//  A Seat Awaits
//
//  Loads and mutates the Account → Collaborators management screen entirely
//  through the authenticated `SupabaseClient` (PostgREST + RPCs), with row-level
//  security as the only authorization boundary. No Nuxt / web API, no service
//  role key, no direct Keychain or `auth.users` access.
//
//  The raw rows (owned events, active shares, pending invitations, resolved
//  names) are cached so that after a successful mutation the overview can be
//  rebuilt locally via `CollaboratorsOverview.build(...)` — keeping per-event
//  usage and the global aggregation consistent without a full reload. The
//  remove-from-all path is the exception: it always reloads authoritative state.
//

import Foundation

@MainActor
@Observable
final class CollaboratorsStore {

    private let supabase: SupabaseClient

    private(set) var overview: CollaboratorsOverview?
    private(set) var isLoading = false
    /// True once a load has completed at least once (so we can tell "still
    /// loading" from "loaded but empty").
    private(set) var hasLoaded = false
    var errorMessage: String?

    // Row-scoped operation state so a single mutation never disables the screen.
    private(set) var updatingRoleShareIDs: Set<String> = []
    private(set) var deletingShareIDs: Set<String> = []
    private(set) var deletingInvitationIDs: Set<String> = []
    private(set) var removingAllEmails: Set<String> = []

    // Cached authoritative rows backing the current overview.
    private var policy: CollaborationPlanPolicy = .free
    private var ownedEvents: [OwnedEventRow] = []
    private var shares: [EventShareRecord] = []
    private var invitations: [PendingInvitationRecord] = []
    private var resolvedNames: [String: String] = [:]

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    // MARK: - Load

    /// Loads everything. Existing content is preserved while reloading (so
    /// pull-to-refresh doesn't flash an empty screen).
    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false; hasLoaded = true }

        do {
            guard let userId = await supabase.currentUser?.id else {
                throw SupabaseError.notAuthenticated
            }

            // 1. Plan policy from public.users.
            policy = try await loadPolicy(userId: userId)

            // 2. Owned events.
            ownedEvents = try await loadOwnedEvents(userId: userId)
            let ownedIDs = ownedEvents.map(\.id)

            guard !ownedIDs.isEmpty else {
                shares = []
                invitations = []
                resolvedNames = [:]
                rebuild()
                return
            }

            // 3 & 4. Active shares and pending invitations (RLS-scoped).
            shares = try await loadShares(eventIDs: ownedIDs)
            invitations = try await loadPendingInvitations(userId: userId, eventIDs: ownedIDs)

            // 5. Resolve display names for share / invitation emails.
            resolvedNames = try await resolveNames()

            rebuild()
        } catch {
            errorMessage = Self.message(for: error)
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

    private func loadOwnedEvents(userId: String) async throws -> [OwnedEventRow] {
        try await supabase.select(
            "events",
            query: [
                URLQueryItem(name: "select", value: "id,name,owner_id,created_at"),
                URLQueryItem(name: "owner_id", value: "eq.\(userId)"),
                URLQueryItem(name: "order", value: "created_at.asc.nullslast"),
            ],
            as: [OwnedEventRow].self)
    }

    private func loadShares(eventIDs: [String]) async throws -> [EventShareRecord] {
        try await supabase.select(
            "event_shares",
            query: [
                URLQueryItem(name: "select", value: "id,event_id,email,role,created_at"),
                URLQueryItem(name: "event_id", value: Self.inFilter(eventIDs)),
            ],
            as: [EventShareRecord].self)
    }

    private func loadPendingInvitations(userId: String, eventIDs: [String]) async throws -> [PendingInvitationRecord] {
        try await supabase.select(
            "event_invitations",
            query: [
                URLQueryItem(name: "select",
                             value: "id,event_id,inviter_id,invitee_name,invitee_email,role,status,created_at"),
                URLQueryItem(name: "inviter_id", value: "eq.\(userId)"),
                URLQueryItem(name: "status", value: "eq.pending"),
                URLQueryItem(name: "event_id", value: Self.inFilter(eventIDs)),
            ],
            as: [PendingInvitationRecord].self)
    }

    /// Calls `resolve_collaborator_names(p_emails)` for the distinct emails we
    /// need. Returns a map keyed by normalized email. Never queries auth.users.
    private func resolveNames() async throws -> [String: String] {
        var seen = Set<String>()
        var emails: [String] = []
        for email in shares.map(\.email) + invitations.compactMap(\.inviteeEmail) {
            let key = CollaboratorsOverview.normalize(email: email)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            emails.append(email)
        }
        guard !emails.isEmpty else { return [:] }

        let rows = try await supabase.rpc(
            "resolve_collaborator_names",
            params: ResolveNamesParams(p_emails: emails),
            as: [ResolvedCollaboratorName].self)

        var map: [String: String] = [:]
        for row in rows {
            if let name = row.fullName?.nilIfBlank {
                map[CollaboratorsOverview.normalize(email: row.email)] = name
            }
        }
        return map
    }

    private func rebuild() {
        overview = CollaboratorsOverview.build(
            policy: policy,
            ownedEvents: ownedEvents,
            shares: shares,
            invitations: invitations,
            resolvedNames: resolvedNames)
    }

    // MARK: - Change role (active shares only)

    /// Updates an active share's role. Scoped by both share id and event id as a
    /// defensive check. Non-optimistic: local state changes only after the
    /// server returns the updated row, so an unauthorized change is never shown.
    func changeRole(collaborator: EventCollaborator, to newRole: CollaboratorRole) async {
        guard collaborator.isActive,
              collaborator.role != newRole,
              !updatingRoleShareIDs.contains(collaborator.id) else { return }

        updatingRoleShareIDs.insert(collaborator.id)
        defer { updatingRoleShareIDs.remove(collaborator.id) }
        errorMessage = nil

        do {
            let rows = try await supabase.update(
                "event_shares",
                values: ShareRolePatch(role: newRole.dbValue),
                query: CollaboratorMutationQuery.scoped(rowID: collaborator.id, eventID: collaborator.eventId),
                returning: [EventShareRecord].self)

            guard let updated = rows.first else {
                // Nothing matched — likely already changed/removed. Reconcile.
                errorMessage = "That collaborator could not be found. Refreshing…"
                await load()
                return
            }

            // Reconcile with the returned row.
            if let idx = shares.firstIndex(where: { $0.id == updated.id }) {
                shares[idx] = updated
            }
            rebuild()
        } catch {
            // No optimistic change was applied, so the previous role still shows.
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: - Revoke a pending invitation

    func revokeInvitation(_ collaborator: EventCollaborator) async {
        guard collaborator.isPending,
              !deletingInvitationIDs.contains(collaborator.id) else { return }

        deletingInvitationIDs.insert(collaborator.id)
        defer { deletingInvitationIDs.remove(collaborator.id) }
        errorMessage = nil

        do {
            try await supabase.delete(
                "event_invitations",
                query: CollaboratorMutationQuery.scoped(rowID: collaborator.id, eventID: collaborator.eventId))
            invitations.removeAll { $0.id == collaborator.id }
            rebuild()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: - Remove from one event

    func removeFromEvent(_ collaborator: EventCollaborator) async {
        guard collaborator.isActive,
              !deletingShareIDs.contains(collaborator.id) else { return }

        deletingShareIDs.insert(collaborator.id)
        defer { deletingShareIDs.remove(collaborator.id) }
        errorMessage = nil

        do {
            try await supabase.delete(
                "event_shares",
                query: CollaboratorMutationQuery.scoped(rowID: collaborator.id, eventID: collaborator.eventId))
            shares.removeAll { $0.id == collaborator.id }
            rebuild()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: - Remove a person from all owned events

    /// Deletes every active share and pending invitation for one person across
    /// owned events. Each delete is scoped by both id and event id; we never
    /// issue an unscoped delete by email. Because these are independent
    /// RLS-protected requests (not a transaction), partial failure is reported
    /// honestly and authoritative state is always reloaded afterward.
    func removeFromAll(_ person: GlobalCollaborator) async {
        guard !removingAllEmails.contains(person.normalizedEmail) else { return }

        removingAllEmails.insert(person.normalizedEmail)
        defer { removingAllEmails.remove(person.normalizedEmail) }
        errorMessage = nil

        var failures = 0
        for entry in person.entries {
            let table = entry.isActive ? "event_shares" : "event_invitations"
            do {
                try await supabase.delete(
                    table,
                    query: CollaboratorMutationQuery.scoped(rowID: entry.id, eventID: entry.eventId))
            } catch {
                failures += 1
            }
        }

        // Always reconcile with authoritative state.
        await load()

        if failures > 0 {
            errorMessage = "Some of \(person.displayName)'s access could not be removed (\(failures) of \(person.entries.count)). The list has been refreshed — please try again."
        }
    }

    // MARK: - Helpers

    private static func inFilter(_ ids: [String]) -> String {
        "in.(\(ids.joined(separator: ",")))"
    }

    /// Maps a thrown error to a user-facing message (never silently swallowed).
    static func message(for error: Error) -> String {
        guard let supabaseError = error as? SupabaseError else {
            return error.localizedDescription
        }
        switch supabaseError {
        case .notAuthenticated:
            return "You're signed out. Please sign in again to manage collaborators."
        case .http(let status, let message):
            switch status {
            case 401:
                return "You're signed out. Please sign in again to manage collaborators."
            case 403:
                return "Only the event owner can manage access to these events."
            case 404, 406:
                return "That record was already removed. Pull to refresh."
            default:
                return message.isEmpty ? "Something went wrong (HTTP \(status))." : message
            }
        case .transport:
            return "Network problem. Check your connection and try again."
        case .offline:
            return "You're offline. Check your connection and try again."
        case .decoding(let message):
            return "Couldn't read the server response. \(message)"
        case .notConfigured(let message):
            return message
        }
    }
}

// MARK: - Mutation filters

/// Pure builders for the PostgREST filters used by collaborator mutations. Every
/// role change and delete is scoped by *both* the row id and its event id as a
/// defensive check; these helpers exist so that requirement can be unit tested.
nonisolated enum CollaboratorMutationQuery {
    /// `id = eq.<rowID>` AND `event_id = eq.<eventID>`.
    static func scoped(rowID: String, eventID: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "id", value: "eq.\(rowID)"),
            URLQueryItem(name: "event_id", value: "eq.\(eventID)"),
        ]
    }
}

// MARK: - Request DTOs

private nonisolated struct ResolveNamesParams: Encodable, Sendable {
    let p_emails: [String]
}

private nonisolated struct ShareRolePatch: Encodable, Sendable {
    let role: String
}
