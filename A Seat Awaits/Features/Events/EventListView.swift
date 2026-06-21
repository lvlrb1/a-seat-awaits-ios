//
//  EventListView.swift
//  A Seat Awaits
//
//  The signed-in home: a plum-headed dashboard of the planner's events with
//  search, sort, pending-invite acceptance, per-event seating progress, and
//  create/open/delete.
//

import SwiftUI

struct EventListView: View {
    let supabase: SupabaseClient

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var scheme

    @State private var store: EventStore
    @State private var showingCreate = false
    @State private var searchText = ""
    @State private var sortDescending = false   // false = soonest first
    @State private var eventPendingDeletion: Event?

    init(supabase: SupabaseClient) {
        self.supabase = supabase
        _store = State(initialValue: EventStore(supabase: supabase))
    }

    // MARK: Derived data

    private var firstName: String {
        let name = appState.currentUser?.displayName ?? "Planner"
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    /// Time-aware greeting (F11) — no longer hard-coded to "Good evening".
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part: String
        switch hour {
        case 5..<12: part = "Good morning"
        case 12..<17: part = "Good afternoon"
        default: part = "Good evening"
        }
        return "\(part), \(firstName)"
    }

    private var avatarName: String { appState.currentUser?.displayName ?? "Planner" }

    /// Confirmation copy that names the event's scale before deletion (F1).
    private func deletionMessage(for event: Event) -> String {
        let total = store.progress(for: event.id)?.total ?? 0
        let scale: String
        if total > 0 {
            scale = "its \(total) guest\(total == 1 ? "" : "s"), tables and floor plan"
        } else {
            scale = "its tables and floor plan"
        }
        return "This permanently removes \(scale). You'll have a few seconds to undo."
    }

    /// Search-filtered, date-sorted events.
    private var visibleEvents: [Event] {
        let filtered: [Event]
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            filtered = store.events
        } else {
            filtered = store.events.filter {
                $0.name.lowercased().contains(query)
                    || ($0.location?.lowercased().contains(query) ?? false)
            }
        }
        return filtered.sorted { a, b in
            // nil dates sort last regardless of direction.
            switch (a.date, b.date) {
            case let (l?, r?): return sortDescending ? l > r : l < r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return false
            }
        }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Brand.canvas.ignoresSafeArea()

                content

                FloatingButton(title: "Create Event") { showingCreate = true }
                    .padding(.trailing, 20)
                    .padding(.bottom, 24)
            }
            .undoSnackbar(store.undo)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingCreate) {
                CreateEventView(store: store)
            }
            .confirmationDialog(
                eventPendingDeletion.map { "Delete “\($0.name)”?" } ?? "Delete event?",
                isPresented: Binding(get: { eventPendingDeletion != nil },
                                     set: { if !$0 { eventPendingDeletion = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Event", role: .destructive) {
                    if let event = eventPendingDeletion {
                        store.deleteWithUndo(event)
                    }
                    eventPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { eventPendingDeletion = nil }
            } message: {
                if let event = eventPendingDeletion {
                    Text(deletionMessage(for: event))
                }
            }
            .refreshable { await store.loadDashboard(myEmail: appState.currentUser?.email) }
            .task {
                if store.events.isEmpty {
                    await store.loadDashboard(myEmail: appState.currentUser?.email)
                }
            }
            .alert("Something went wrong",
                   isPresented: Binding(get: { store.errorMessage != nil },
                                        set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let events = visibleEvents

        List {
            // Header band — full-bleed, scrolls with the content.
            header
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if store.isLoading && store.events.isEmpty {
                ProgressView("Loading events…")
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else if store.events.isEmpty {
                emptyState
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                sortRow(count: events.count)
                    .listRowInsets(EdgeInsets(top: 18, leading: 22, bottom: 4, trailing: 22))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                ForEach(store.pendingInvites) { invite in
                    InviteCard(invite: invite) { await store.acceptInvite(invite) }
                        .cardRow()
                }

                ForEach(events) { event in
                    ZStack {
                        EventCard(event: event, progress: store.progress(for: event.id))
                        NavigationLink {
                            EventDetailView(event: event, supabase: supabase)
                        } label: { EmptyView() }
                        .opacity(0)
                    }
                    .cardRow()
                    // Swipe is gated by a confirmation that names the event and its
                    // scale (F1); allowsFullSwipe off so a stray swipe can't delete.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            eventPendingDeletion = event
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                    // Non-swipe path for VoiceOver / Switch Control users (A11y-2).
                    .contextMenu {
                        Button(role: .destructive) {
                            eventPendingDeletion = event
                        } label: { Label("Delete Event", systemImage: "trash") }
                    }
                }

                // Clearance for the floating button.
                Color.clear
                    .frame(height: 80)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .listRowSpacing(0)
        .scrollContentBackground(.hidden)
        .background(Brand.canvas)
        .ignoresSafeArea(edges: .top)
        .environment(\.defaultMinListRowHeight, 0)
    }

    // MARK: Header band

    private var header: some View {
        ZStack(alignment: .topLeading) {
            Brand.heroGradient(scheme)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Brand.lilac.opacity(0.40))
                        .frame(width: 280, height: 280)
                        .blur(radius: 70)
                        .offset(x: 70, y: -90)
                }
                .clipped()

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    Text(greeting)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    GlassAvatar(name: avatarName, size: 38)
                }

                Text("My Events")
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(.white)
                    .padding(.top, 8)

                SearchField(text: $searchText, placeholder: "Search events", onPlum: true)
                    .padding(.top, 16)
            }
            .padding(.horizontal, 24)
            // Clear the status bar / dynamic island (top safe area is ignored).
            .padding(.top, 64)
            .padding(.bottom, 20)
        }
        .frame(minHeight: 230)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Sub-header

    private func sortRow(count: Int) -> some View {
        HStack {
            Text("\(count) event\(count == 1 ? "" : "s") · sorted by date")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.slate400)
            Spacer()
            Button {
                withAnimation(.snappy(duration: 0.2)) { sortDescending.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(sortDescending ? "Latest" : "Soonest")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .rotationEffect(.degrees(sortDescending ? 180 : 0))
                }
                .foregroundStyle(Brand.accent)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No events yet", systemImage: "calendar.badge.plus")
        } description: {
            Text("Create your first event to start building a seating chart.")
        } actions: {
            Button("Create Event") { showingCreate = true }
                .buttonStyle(.borderedProminent)
                .tint(Brand.plum)
        }
        .frame(minHeight: 340)
    }
}

// MARK: - List row styling for cards

private extension View {
    /// Card list rows: edge insets matching the dashboard gutter, no separator,
    /// clear background so the card shape shows on the canvas.
    func cardRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 7, leading: 18, bottom: 7, trailing: 18))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

// MARK: - Pending invite card

private struct InviteCard: View {
    let invite: EventInvitation
    let onAccept: () async -> Void

    @State private var isAccepting = false

    var body: some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Brand.warningFill)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Brand.warningText)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("\(invite.inviterName) invited you")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                Text("\(invite.roleLabel) · “\(invite.eventName)”")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.inviteSubtitle)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                guard !isAccepting else { return }
                isAccepting = true
                Task { await onAccept(); isAccepting = false }
            } label: {
                Text("Accept")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(Brand.warningText, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    // Visual pill stays 34pt; hit target meets 44pt (A11y-5).
                    .contentShape(Rectangle())
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(isAccepting)
        }
        .padding(14)
        .background(Brand.inviteBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Brand.warningBorder, lineWidth: 1)
        )
    }
}

// MARK: - Event card

private struct EventCard: View {
    let event: Event
    let progress: EventProgress?

    private var subtitle: String? {
        let date = event.displayDate
        let loc = event.location?.nilIfBlank
        switch (date, loc) {
        case let (d?, l?): return "\(d) · \(l)"
        case let (d?, nil): return d
        case let (nil, l?): return l
        case (nil, nil): return nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(event.name)
                    .font(.system(size: 18, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(2)

                if let subtitle {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Brand.textTertiary)
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 5)
                }

                if let p = progress, p.total > 0 {
                    HStack(spacing: 7) {
                        TagPill.seated("\(p.seated) seated")
                        TagPill.open("\(p.open) open")
                    }
                    .padding(.top, 12)
                }
            }

            Spacer(minLength: 0)

            if let p = progress, p.total > 0 {
                ProgressRing(progress: p.fraction, size: 60)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }
}
