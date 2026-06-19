//
//  EventStore.swift
//  A Seat Awaits
//
//  Loads and creates the signed-in planner's events via Supabase/PostgREST.
//

import Foundation
import Observation

/// Insert payload for a new event. `owner_id` is set by the DB default.
nonisolated struct NewEventDTO: Encodable, Sendable {
    let name: String
    let date: String?
    let location: String?
    let description: String?
}

/// Encodable params for the `accept_event_invitation` RPC.
nonisolated struct AcceptInviteParams: Encodable, Sendable {
    let p_token: String
}

/// Encodable params for the `event_seating_summary` RPC.
nonisolated struct SeatingSummaryParams: Encodable, Sendable {
    let p_event_ids: [String]
}

/// Empty body for RPCs that take no arguments (PostgREST still expects `{}`).
nonisolated struct EmptyRPCParams: Encodable, Sendable {}

@MainActor
@Observable
final class EventStore {
    private let supabase: SupabaseClient

    private(set) var events: [Event] = []
    private(set) var progress: [String: EventProgress] = [:]
    private(set) var pendingInvites: [EventInvitation] = []
    private(set) var isLoading = false
    var errorMessage: String?

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    func progress(for eventId: String) -> EventProgress? { progress[eventId] }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            events = try await supabase.select(
                "events",
                query: [
                    URLQueryItem(name: "select", value: "*"),
                    URLQueryItem(name: "order", value: "date.asc.nullslast"),
                ],
                as: [Event].self
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        await loadProgress()
    }

    /// Loads the dashboard: events, per-event seating progress, and any pending
    /// collaboration invitations addressed to `myEmail`.
    func loadDashboard(myEmail: String?) async {
        await load()
        await loadInvites(myEmail: myEmail)
    }

    /// Aggregates seating progress for every visible event server-side via the
    /// `event_seating_summary` RPC (counts + capacity computed in one call, RLS
    /// scopes the rows to those the planner owns/shares).
    func loadProgress() async {
        guard !events.isEmpty else { progress = [:]; return }
        do {
            let rows = try await supabase.rpc(
                "event_seating_summary",
                params: SeatingSummaryParams(p_event_ids: events.map(\.id)),
                as: [EventSeatingSummary].self
            )
            var map: [String: EventProgress] = [:]
            for row in rows {
                map[row.eventId] = EventProgress(seated: row.seatedGuests, total: row.totalGuests)
            }
            progress = map
        } catch {
            // Non-fatal: cards just render without a percentage.
        }
    }

    /// Fetches the pending invitations addressed to the current user via the
    /// `list_my_pending_invites` RPC, which scopes rows to `auth.email()`.
    func loadInvites(myEmail: String?) async {
        guard let myEmail, !myEmail.isEmpty else { pendingInvites = []; return }
        do {
            pendingInvites = try await supabase.rpc(
                "list_my_pending_invites",
                params: EmptyRPCParams(),
                as: [EventInvitation].self
            )
        } catch {
            pendingInvites = []
        }
    }

    /// Accepts an invitation via the `accept_event_invitation` RPC, which
    /// validates the invitee and creates the `event_shares` row server-side,
    /// then refreshes the dashboard so the newly shared event appears.
    func acceptInvite(_ invite: EventInvitation) async {
        do {
            _ = try await supabase.rpc(
                "accept_event_invitation",
                params: AcceptInviteParams(p_token: invite.token),
                as: String.self
            )
            pendingInvites.removeAll { $0.id == invite.id }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Creates an event. `owner_id` is assigned by the database default
    /// (`auth.uid()`), matching the web backend, so it is not sent here.
    @discardableResult
    func create(name: String, date: String?, location: String?, description: String?) async throws -> Event {
        let created = try await supabase.insert(
            "events",
            values: NewEventDTO(name: name,
                                date: date?.nilIfBlank,
                                location: location?.nilIfBlank,
                                description: description?.nilIfBlank),
            returning: [Event].self
        )
        guard let event = created.first else {
            throw SupabaseError.decoding("Event creation returned no row.")
        }
        events.insert(event, at: 0)
        return event
    }

    func delete(_ event: Event) async {
        do {
            try await supabase.delete("events", query: [URLQueryItem(name: "id", value: "eq.\(event.id)")])
            events.removeAll { $0.id == event.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension String {
    /// Returns nil when the string is empty/whitespace, otherwise the trimmed value.
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
