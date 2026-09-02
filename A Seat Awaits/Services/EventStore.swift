//
//  EventStore.swift
//  A Seat Awaits
//
//  Loads and creates the signed-in planner's events via Supabase/PostgREST.
//

import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

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

/// Encodable params for the `swap_event_pass` RPC.
nonisolated struct SwapEventPassParams: Encodable, Sendable {
    let p_event_id: String
    let p_pass_id: String
}

/// Encodable params for the `event_seating_summary` RPC.
nonisolated struct SeatingSummaryParams: Encodable, Sendable {
    let p_event_ids: [String]
}

/// Empty body for RPCs that take no arguments (PostgREST still expects `{}`).
nonisolated struct EmptyRPCParams: Encodable, Sendable {}

/// Body / response of the `provision-sample-event` Edge Function.
nonisolated struct ProvisionSampleEventBody: Encodable, Sendable {}
nonisolated struct ProvisionSampleEventResponse: Decodable, Sendable {
    let ok: Bool
    let eventId: String?
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
    /// True when the last events load threw — distinguishes "you have no
    /// events" from "we couldn't load your events" so the dashboard never
    /// shows a misleading empty state after a network failure.
    private(set) var loadFailed = false
    /// True once a load has finished (success or failure) at least once.
    private(set) var hasLoaded = false

    /// Shared undo banner for reversible actions on the dashboard (event delete).
    let undo = UndoToast()

    /// A delete that has been hidden locally but not yet committed to the server,
    /// so the user can undo it. Only one is ever in flight.
    private var pendingDelete: (event: Event, index: Int, task: Task<Void, Never>)?

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
            loadFailed = false
            hasLoaded = true
        } catch {
            // A cancelled load (the dashboard left the screen) is not a
            // failure: leave the previous state alone and stay silent.
            guard !FriendlyError.isCancellation(error) else { return }
            loadFailed = true
            hasLoaded = true
            errorMessage = FriendlyError.message(for: error)
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
            guard !FriendlyError.isCancellation(error) else { return }
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
            guard !FriendlyError.isCancellation(error) else { return }
            errorMessage = FriendlyError.message(for: error)
        }
    }

    // MARK: - Sample event

    /// Asks the `provision-sample-event` Edge Function for the caller's
    /// one-time sample event (idempotent server-side, once-ever marker; see the
    /// function for the contract). Returns whether the call succeeded so the
    /// caller can retry later; never throws, since the sample is a nice-to-have
    /// and the dashboard works without it.
    static func provisionSampleEvent(using supabase: SupabaseClient) async -> Bool {
        do {
            _ = try await supabase.invokeFunction("provision-sample-event",
                                                  body: ProvisionSampleEventBody(),
                                                  as: ProvisionSampleEventResponse.self)
            return true
        } catch {
            return false
        }
    }

    /// Retries sample-event provisioning from the dashboard (after the sign-up
    /// call failed) and reloads the events on success.
    @discardableResult
    func provisionSampleEventAndReload() async -> Bool {
        guard await Self.provisionSampleEvent(using: supabase) else { return false }
        await load()
        return true
    }

    /// Creates an event. `owner_id` is assigned by the database default
    /// (`auth.uid()`), matching the web backend, so it is not sent here.
    ///
    /// `preferredPassId`: the creation trigger always claims the caller's
    /// OLDEST unattached Event Pass. When the user picked a different pass in
    /// the create form, the `swap_event_pass` RPC re-attaches their choice —
    /// best-effort, mirroring the web (`server/api/events.post.ts`): worst
    /// case the trigger's pick stays and the event is never left uncovered.
    @discardableResult
    func create(name: String, date: String?, location: String?, description: String?,
                preferredPassId: String? = nil) async throws -> Event {
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
        if let passId = preferredPassId {
            _ = try? await supabase.rpc(
                "swap_event_pass",
                params: SwapEventPassParams(p_event_id: event.id, p_pass_id: passId),
                as: Bool.self)
        }
        events.insert(event, at: 0)
        return event
    }

    /// Deletes an event with a 5-second undo window. The row is hidden locally
    /// immediately and the server delete (which cascades to guests, tables, rooms
    /// and the floor plan) is deferred so an accidental delete can be reversed
    /// before any data is destroyed. A confirmation precedes this in the UI (F1).
    func deleteWithUndo(_ event: Event) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        // Only one deferred delete in flight: commit any prior one now.
        flushPendingDelete()

        let removed = events.remove(at: index)
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(UndoToast.defaultDuration))
            guard !Task.isCancelled else { return }
            await self?.commitDelete(removed)
        }
        pendingDelete = (removed, index, task)

        undo.show("Deleted “\(removed.name).”") { [weak self] in
            self?.cancelPendingDelete(restoring: removed, at: index)
        }
    }

    /// Re-shows a pending-deleted event (Undo tapped) before its commit fires.
    private func cancelPendingDelete(restoring event: Event, at index: Int) {
        guard pendingDelete?.event.id == event.id else { return }
        pendingDelete?.task.cancel()
        pendingDelete = nil
        events.insert(event, at: min(index, events.count))
    }

    /// Commits a deferred event delete to the server. On failure the row is
    /// restored and a friendly message surfaced.
    private func commitDelete(_ event: Event) async {
        guard pendingDelete?.event.id == event.id else { return }
        let index = pendingDelete?.index ?? events.count
        pendingDelete = nil
        do {
            try await supabase.delete("events", query: [URLQueryItem(name: "id", value: "eq.\(event.id)")])
        } catch {
            events.insert(event, at: min(index, events.count))
            guard !FriendlyError.isCancellation(error) else { return }
            errorMessage = FriendlyError.message(for: error)
        }
    }

    /// Immediately commits any pending delete (e.g. before the dashboard tears
    /// down, another delete starts, or the app is backgrounded), skipping the
    /// remaining undo window. When backgrounding, the commit runs inside a
    /// UIKit background task so the request isn't lost if the app is
    /// suspended or killed within the undo window.
    func flushPendingDelete() {
        guard let pending = pendingDelete else { return }
        pending.task.cancel()
        #if canImport(UIKit)
        let handle = BackgroundTaskHandle()
        handle.begin()
        Task {
            await commitDelete(pending.event)
            handle.end()
        }
        #else
        Task { await commitDelete(pending.event) }
        #endif
    }
}

#if canImport(UIKit)
/// Keeps the app alive long enough to finish one network request after it
/// moves to the background.
@MainActor
private final class BackgroundTaskHandle {
    private var id: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        id = UIApplication.shared.beginBackgroundTask(withName: "event-delete") { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif

/// `nonisolated`: used from nonisolated model types (`Event`, `EventPass`,
/// collaborator DTOs); under MainActor default isolation a plain extension
/// would be main-actor-bound and warn at every such call site.
nonisolated extension String {
    /// Returns nil when the string is empty/whitespace, otherwise the trimmed value.
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
