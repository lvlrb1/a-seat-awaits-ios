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

/// Patch to mark an invitation accepted.
nonisolated struct InviteStatusPatch: Encodable, Sendable {
    let status: String
}

@MainActor
@Observable
final class EventStore {
    private let supabase: SupabaseClient

    private(set) var events: [Event] = []
    private(set) var progress: [String: EventProgress] = [:]
    private(set) var pendingInvites: [EventInvitation] = []
    private(set) var isLoading = false
    var errorMessage: String?

    /// Lightweight row used to compute per-event seating progress.
    private nonisolated struct GuestProgressRow: Decodable, Sendable {
        let eventId: String
        let tableId: String?
        enum CodingKeys: String, CodingKey {
            case eventId = "event_id"
            case tableId = "table_id"
        }
    }

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

    /// Aggregates seating progress for every event the planner can see in a
    /// single query (RLS scopes the rows to those they own/share).
    func loadProgress() async {
        do {
            let rows = try await supabase.select(
                "guests",
                query: [URLQueryItem(name: "select", value: "event_id,table_id")],
                as: [GuestProgressRow].self
            )
            var map: [String: EventProgress] = [:]
            for row in rows {
                var p = map[row.eventId] ?? EventProgress(seated: 0, total: 0)
                p.total += 1
                if row.tableId != nil { p.seated += 1 }
                map[row.eventId] = p
            }
            progress = map
        } catch {
            // Non-fatal: cards just render without a percentage.
        }
    }

    /// Best-effort fetch of pending invitations addressed to the current user.
    func loadInvites(myEmail: String?) async {
        guard let myEmail, !myEmail.isEmpty else { pendingInvites = []; return }
        let base = [
            URLQueryItem(name: "invitee_email", value: "eq.\(myEmail)"),
            URLQueryItem(name: "status", value: "eq.pending"),
        ]
        // Try the rich query (event + inviter names); fall back to a plain read
        // if the embeds are blocked by RLS.
        do {
            pendingInvites = try await supabase.select(
                "event_invitations",
                query: [URLQueryItem(name: "select", value: "*,event:events(name),inviter:users(full_name)")] + base,
                as: [EventInvitation].self
            )
        } catch {
            do {
                pendingInvites = try await supabase.select(
                    "event_invitations",
                    query: [URLQueryItem(name: "select", value: "*")] + base,
                    as: [EventInvitation].self
                )
            } catch {
                pendingInvites = []
            }
        }
    }

    /// Best-effort accept: marks the invitation accepted. (Server-side share
    /// creation is handled by the backend trigger / web flow.)
    func acceptInvite(_ invite: EventInvitation) async {
        do {
            _ = try await supabase.update(
                "event_invitations",
                values: InviteStatusPatch(status: "accepted"),
                query: [URLQueryItem(name: "id", value: "eq.\(invite.id)")],
                returning: [EventInvitation].self
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
