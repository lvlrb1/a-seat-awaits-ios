//
//  AccountDataExporter.swift
//  A Seat Awaits
//
//  Assembles the user's personal-data export locally from authenticated,
//  RLS-protected Supabase queries — never a privileged endpoint. The output is
//  versioned JSON written atomically to a temporary file for the share sheet.
//
//  No access/refresh tokens, Supabase or Stripe credentials, or unrelated
//  private collaborator data are ever included. If a section fails to load it is
//  reported as a partial export rather than silently dropped.
//

import Foundation

/// Result of a personal-data export: the file to share plus any sections that
/// couldn't be assembled (so the UI can tell the user it's partial).
nonisolated struct DataExportResult: Sendable {
    let url: URL
    let partialFailures: [String]
    var isPartial: Bool { !partialFailures.isEmpty }
}

/// Builds the personal-data export. Stateless aside from its inputs.
nonisolated struct AccountDataExporter {
    let supabase: SupabaseClient
    let authUser: AuthUser
    let profile: UserProfile?
    let subscription: SubscriptionRow?

    func run(now: Date) async throws -> DataExportResult {
        var failures: [String] = []

        // Helper: fetch a table as a JSON array, recording the section on failure.
        func fetchArray(_ section: String, _ table: String, _ query: [URLQueryItem]) async -> [Any] {
            do {
                let data = try await supabase.selectRaw(table, query: query)
                return (try JSONSerialization.jsonObject(with: data) as? [Any]) ?? []
            } catch {
                failures.append(section)
                return []
            }
        }

        // 1. Account (from already-authenticated state; no extra query).
        let account = buildAccount()

        // 2. Subscription (already loaded; curated columns only).
        let subscriptionJSON = buildSubscription()

        // 3. Events — RLS returns everything visible; split owned vs. shared.
        let allEvents = await fetchArray("events", "events",
            [URLQueryItem(name: "select", value: "*"),
             URLQueryItem(name: "order", value: "created_at.asc.nullslast")])
        let owned = allEvents.filter { ownerId(of: $0) == authUser.id }
        let shared = allEvents.filter { ownerId(of: $0) != authUser.id }
        let ownedIDs = owned.compactMap { ($0 as? [String: Any])?["id"] as? String }

        // 4. Per-event content for owned events (RLS also scopes these).
        //    Fetched sequentially so the shared `failures` log isn't mutated
        //    from concurrent tasks.
        var eventData: [String: Any]
        if ownedIDs.isEmpty {
            eventData = ["guests": [], "tables": [], "rooms": [], "shapes": [],
                         "guest_groups": [], "event_shares": [], "invitations": []]
        } else {
            let inOwned = inFilter(ownedIDs)
            let guests = await fetchArray("guests", "guests",
                [URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "event_id", value: inOwned)])
            let tables = await fetchArray("tables", "tables",
                [URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "event_id", value: inOwned)])
            let rooms = await fetchArray("rooms", "floorplan_rooms",
                [URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "event_id", value: inOwned)])
            let shapes = await fetchArray("shapes", "shapes",
                [URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "event_id", value: inOwned)])
            let groups = await fetchArray("guest_groups", "guest_groups",
                [URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "event_id", value: inOwned)])
            let eventShares = await fetchArray("event_shares", "event_shares",
                [URLQueryItem(name: "select", value: "id,event_id,email,role,created_at"),
                 URLQueryItem(name: "event_id", value: inOwned)])
            let invitations = await fetchArray("invitations", "event_invitations",
                [URLQueryItem(name: "select", value: "id,event_id,invitee_name,invitee_email,role,status,created_at"),
                 URLQueryItem(name: "inviter_id", value: "eq.\(authUser.id)")])

            eventData = [
                "guests": guests,
                "tables": tables,
                "rooms": rooms,
                "shapes": shapes,
                "guest_groups": groups,
                "event_shares": eventShares,
                "invitations": invitations,
            ]
        }

        // 5. Preferences — per-user, RLS-scoped to auth.uid().
        let templates = await fetchArray("floorplan_templates", "floorplan_templates",
            [URLQueryItem(name: "select", value: "*"),
             URLQueryItem(name: "user_id", value: "eq.\(authUser.id)")])
        let headerPrefs = await fetchArray("import_preferences", "import_user_header_prefs",
            [URLQueryItem(name: "select", value: "header_normalized,preferred_selected,updated_at"),
             URLQueryItem(name: "user_id", value: "eq.\(authUser.id)")])
        let importHistory = await fetchArray("import_history", "import_commits",
            [URLQueryItem(name: "select", value: "id,event_id,status,dedupe_mode,inserted_count,skipped_count,created_at"),
             URLQueryItem(name: "user_id", value: "eq.\(authUser.id)"),
             URLQueryItem(name: "order", value: "created_at.desc.nullslast")])

        let preferences: [String: Any] = [
            "floorplan_templates": templates,
            "import_header_preferences": headerPrefs,
            "import_history": importHistory,
        ]

        // Assemble the versioned document.
        var root: [String: Any] = [
            "export_info": [
                "format_version": "1.0",
                "exported_at": Self.isoNow(now),
                "user_id": authUser.id,
            ],
            "account": account,
            "subscription": subscriptionJSON,
            "events": ["owned": owned, "shared": shared],
            "event_data": eventData,
            "preferences": preferences,
        ]
        if !failures.isEmpty {
            root["export_info"] = [
                "format_version": "1.0",
                "exported_at": Self.isoNow(now),
                "user_id": authUser.id,
                "partial": true,
                "incomplete_sections": Array(Set(failures)).sorted(),
            ]
        }

        let json = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

        let name = "a-seat-awaits-data-export-\(AccountDate.stamp(now)).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try json.write(to: url, options: .atomic)

        return DataExportResult(url: url, partialFailures: Array(Set(failures)).sorted())
    }

    // MARK: - Section builders (no credentials)

    private func buildAccount() -> [String: Any] {
        var dict: [String: Any] = [
            "user_id": authUser.id,
            "email_verified": authUser.isEmailVerified,
            "auth_provider": authUser.primaryProvider,
        ]
        if let email = authUser.email { dict["email"] = email }
        if let pending = authUser.pendingEmail { dict["pending_email"] = pending }
        if let created = authUser.createdAt { dict["account_created_at"] = created }
        if let name = profile?.fullName { dict["full_name"] = name }
        if let tier = profile?.subscriptionTier { dict["subscription_tier"] = tier }
        if let status = profile?.subscriptionStatus { dict["subscription_status"] = status }
        if let updated = profile?.updatedAt { dict["profile_updated_at"] = updated }
        return dict
    }

    private func buildSubscription() -> [String: Any] {
        guard let sub = subscription else { return [:] }
        var dict: [String: Any] = [:]
        if let v = sub.plan { dict["plan"] = v }
        if let v = sub.status { dict["status"] = v }
        if let v = sub.stripePriceId { dict["stripe_price_id"] = v }
        if let v = sub.currentPeriodStart { dict["current_period_start"] = v }
        if let v = sub.currentPeriodEnd { dict["current_period_end"] = v }
        if let v = sub.cancelAtPeriodEnd { dict["cancel_at_period_end"] = v }
        if let v = sub.canceledAt { dict["canceled_at"] = v }
        if let v = sub.trialEnd { dict["trial_end"] = v }
        if let v = sub.createdAt { dict["created_at"] = v }
        if let v = sub.updatedAt { dict["updated_at"] = v }
        return dict
    }

    private func ownerId(of event: Any) -> String? {
        (event as? [String: Any])?["owner_id"] as? String
    }

    private func inFilter(_ ids: [String]) -> String { "in.(\(ids.joined(separator: ",")))" }

    private static func isoNow(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

// MARK: - Guest-list CSV export

/// Builds a CSV of an event's guest list (with table assignments) from
/// authenticated, RLS-scoped queries, written atomically for the share sheet.
nonisolated struct GuestListExporter {
    let supabase: SupabaseClient

    func run(event: Event, now: Date) async throws -> URL {
        let eventFilter = URLQueryItem(name: "event_id", value: "eq.\(event.id)")

        async let guestsTask = supabase.select(
            "guests",
            query: [URLQueryItem(name: "select", value: "*"), eventFilter,
                    URLQueryItem(name: "order", value: "name.asc")],
            as: [Guest].self)
        async let tablesTask = supabase.select(
            "tables",
            query: [URLQueryItem(name: "select", value: "id,name,event_id,width,height"), eventFilter],
            as: [SeatingTable].self)

        let guests = try await guestsTask
        let tables = try await tablesTask
        let tableNames = Dictionary(uniqueKeysWithValues: tables.map { ($0.id, $0.name) })

        var rows = ["Name,Email,Group,Table,Dietary Preference,Notes"]
        for guest in guests {
            let table = guest.tableId.flatMap { tableNames[$0] } ?? ""
            let fields = [
                guest.name,
                guest.email ?? "",
                guest.groupName ?? "",
                table,
                guest.dietaryPreference ?? "",
                guest.notes ?? "",
            ]
            rows.append(fields.map(Self.csvEscape).joined(separator: ","))
        }
        let csv = rows.joined(separator: "\r\n")

        let name = "guest-list-\(Self.sanitize(event.name))-\(AccountDate.stamp(now)).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try Data(csv.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Replaces every non-ASCII-alphanumeric character with `_`, matching the
    /// floor-plan export's filename scheme so downloads are consistent.
    static func sanitize(_ name: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        let cleaned = String(name.map { safe.contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "event" : cleaned
    }

    /// Quotes a field if it contains a comma, quote or newline (RFC 4180).
    static func csvEscape(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
