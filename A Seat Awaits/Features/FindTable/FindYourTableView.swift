//
//  FindYourTableView.swift
//  A Seat Awaits
//
//  The guest-facing lookup: pick an event, type a name, and see where that
//  guest is seated — the branded "Find your table" search and "You're all set"
//  result from the design (Section 06).
//

import SwiftUI

/// Encodable params for the `search_guests_by_qr_token` RPC.
private nonisolated struct GuestSearchParams: Encodable, Sendable {
    let p_token: String
    let p_query: String
    let p_limit: Int
}

/// Accent- and case-tolerant name matching for the guest lookup, so "Jose"
/// finds "José" and "renee" finds "Renée". Pure, so it is unit-tested.
nonisolated enum GuestNameMatcher {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Lowercased, accent-stripped, trimmed form for comparisons and grouping.
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces)
    }

    /// True when the text carries any combining marks / accents.
    static func hasDiacritics(_ text: String) -> Bool {
        text.folding(options: .diacriticInsensitive, locale: .current) != text
    }

    /// Whether `name` contains `term`, ignoring case and accents.
    static func matches(_ name: String, term: String) -> Bool {
        matchRange(in: name, term: term) != nil
    }

    /// The range of `term` inside `name` (in `name`'s own indices), preferring a
    /// match at the start of the name, then the first occurrence anywhere.
    static func matchRange(in name: String, term: String) -> Range<String.Index>? {
        let needle = term.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        return name.range(of: needle, options: options.union(.anchored))
            ?? name.range(of: needle, options: options)
    }
}

struct FindYourTableView: View {
    let supabase: SupabaseClient

    @State private var events: [Event] = []
    @State private var selectedEvent: Event?
    @State private var query = ""
    @State private var suggestions: [GuestSearchResult] = []
    @State private var result: GuestSearchResult?
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    /// True until the first events load completes, so the "No events yet"
    /// state never flashes on the first frame.
    @State private var isLoadingEvents = true
    /// Set when the events load failed; renders a Retry state instead of the
    /// misleading empty state.
    @State private var eventsLoadError: String?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    resultScreen(result)
                } else {
                    searchScreen
                }
            }
            .navigationBarHidden(true)
            .task { await loadEvents() }
        }
    }

    // MARK: - Search screen (plum hero)

    private var searchScreen: some View {
        ZStack {
            HeroBackground()

            if events.isEmpty && isLoadingEvents {
                loadingState
            } else if events.isEmpty, let eventsLoadError {
                loadFailedState(eventsLoadError)
            } else if events.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        searchHeader
                            .padding(.top, 28)

                        searchInput
                            .padding(.top, 26)

                        if !suggestions.isEmpty {
                            suggestionCard
                                .padding(.top, 12)
                        }

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .scaledFont(size: 13, weight: .semibold)
                                .foregroundStyle(.white)
                                .padding(.top, 14)
                        }

                        if !query.isEmpty && suggestions.isEmpty && !isSearching && errorMessage == nil {
                            noMatchHint
                                .padding(.top, 14)
                        }

                        eventControl
                            .padding(.top, 22)

                        Spacer(minLength: 28)

                        footer
                            .padding(.top, 32)
                            .padding(.bottom, 20)
                    }
                    .padding(.horizontal, 30)
                    .frame(maxWidth: .infinity)
                    .readableWidth(Layout.formWidth)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await loadEvents() }
            }
        }
        .preferredColorScheme(nil)
    }

    private var searchHeader: some View {
        VStack(spacing: 0) {
            // Glass logo tile (54pt) with the brand chair mark.
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.white.opacity(0.14))
                .frame(width: 54, height: 54)
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                )
                .overlay(
                    Image("BrandChair")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                )

            if let name = selectedEvent?.name {
                Text(name.uppercased())
                    .scaledFont(size: 14, weight: .bold)
                    .tracking(0.7)
                    .foregroundStyle(Brand.lilac)
                    .multilineTextAlignment(.center)
                    .padding(.top, 22)
            }

            Text("Find your table")
                .scaledFont(size: 34, weight: .heavy)
                .tracking(-0.5)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            Text("Type your name to see where you're seated.")
                .scaledFont(size: 15)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.top, 10)
        }
    }

    // White search input (radius 16, ~58pt, strong shadow).
    private var searchInput: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 18, weight: .semibold)
                .foregroundStyle(Brand.textSecondary)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("Your name")
                        .scaledFont(size: 17)
                        .foregroundStyle(Brand.textSecondary)
                        .accessibilityHidden(true)
                }
                TextField("", text: $query)
                    .accessibilityLabel("Guest name")
                    .scaledFont(size: 17, weight: .semibold)
                    .foregroundStyle(Brand.ink)
                    .tint(Brand.plum)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onChange(of: query) { _, _ in scheduleSearch() }
            }
            if isSearching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 18)
                        .foregroundStyle(Brand.textSecondary)
                        // Glyph stays 18pt; hit target meets 44pt.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 17, x: 0, y: 14)
    }

    // Live suggestion card.
    private var suggestionCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, guest in
                Button {
                    selectResult(guest)
                } label: {
                    suggestionRow(guest)
                }
                .buttonStyle(.plain)

                if index < suggestions.count - 1 {
                    Divider().overlay(Brand.slate100)
                        .padding(.leading, 16)
                }
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 17, x: 0, y: 14)
    }

    /// Folded (case- and accent-insensitive) names that appear more than once
    /// in the current suggestions, so colliding rows can be disambiguated (F16).
    private var collidingNames: Set<String> {
        var counts: [String: Int] = [:]
        for guest in suggestions { counts[GuestNameMatcher.fold(guest.name), default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.map(\.key))
    }

    private func suggestionRow(_ guest: GuestSearchResult) -> some View {
        // Only same-name guests get a household subtitle — never extra PII.
        let isAmbiguous = collidingNames.contains(GuestNameMatcher.fold(guest.name))
        let disambiguator = isAmbiguous ? guest.groupName?.nilIfBlank : nil
        return HStack(spacing: 12) {
            InitialsAvatar(name: guest.name, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlightedName(guest.name))
                    .scaledFont(size: 16)
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)
                if isAmbiguous {
                    Text(disambiguator.map { "Household · \($0)" } ?? "Tap to confirm it's you")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(Brand.slate500)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .scaledFont(size: 14, weight: .bold)
                .foregroundStyle(Brand.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    /// Bolds the matched part of the name against the current query (prefix
    /// first, then first occurrence), ignoring case and accents.
    private func highlightedName(_ name: String) -> AttributedString {
        var attr = AttributedString(name)
        attr.font = .system(size: 16)
        if let range = GuestNameMatcher.matchRange(in: name, term: query),
           let attrRange = Range(range, in: attr) {
            attr[attrRange].font = .system(size: 16, weight: .bold)
        }
        return attr
    }

    private var noMatchHint: some View {
        Text("No guest found by that name yet. Keep typing or check the spelling.")
            .scaledFont(size: 13)
            .foregroundStyle(.white.opacity(0.65))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
    }

    // Secondary event picker — small/de-emphasized.
    @ViewBuilder
    private var eventControl: some View {
        if events.count > 1 {
            Menu {
                ForEach(events) { event in
                    Button {
                        selectedEvent = event
                        clearSearch()
                    } label: {
                        if event.id == selectedEvent?.id {
                            Label(event.name, systemImage: "checkmark")
                        } else {
                            Text(event.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .scaledFont(size: 12, weight: .semibold)
                    Text(selectedEvent?.name ?? "Choose event")
                        .scaledFont(size: 13, weight: .semibold)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .scaledFont(size: 10, weight: .bold)
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.white.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "sofa")
                .scaledFont(size: 13)
            Text("A Seat Awaits · Where every guest matters")
                .scaledFont(size: 13)
        }
        .foregroundStyle(.white.opacity(0.55))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No events yet", systemImage: "magnifyingglass")
                .foregroundStyle(.white)
        } description: {
            Text("Create an event and add guests to use Find Your Table.")
                .foregroundStyle(.white.opacity(0.8))
        } actions: {
            Button("Refresh") { Task { await loadEvents() } }
                .buttonStyle(.heroOutline)
                .padding(.top, 8)
        }
    }

    private var loadingState: some View {
        ProgressView("Loading events…")
            .tint(.white)
            .foregroundStyle(.white.opacity(0.8))
    }

    private func loadFailedState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't load your events", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.white)
        } description: {
            Text(message)
                .foregroundStyle(.white.opacity(0.8))
        } actions: {
            Button("Retry") { Task { await loadEvents() } }
                .buttonStyle(.heroOutline)
                .padding(.top, 8)
        }
    }

    // MARK: - Result screen (light surface with plum band)

    private func resultScreen(_ result: GuestSearchResult) -> some View {
        ZStack(alignment: .top) {
            Color.hex("#FAF7FC").ignoresSafeArea()

            // Plum top band with a lavender orb.
            LinearGradient(colors: [Brand.plum, Brand.plumGradientEnd],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(height: 300)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Brand.lilac.opacity(0.4))
                        .frame(width: 240, height: 240)
                        .blur(radius: 70)
                        .offset(x: 60, y: -90)
                }
                .clipped()
                .ignoresSafeArea(edges: .top)

            ScrollView {
                VStack(spacing: 0) {
                    // Header on the band.
                    VStack(spacing: 6) {
                        Text("WELCOME, \(firstName(result.name))".uppercased())
                            .scaledFont(size: 13, weight: .bold)
                            .tracking(0.6)
                            .foregroundStyle(Brand.lilac)
                            .multilineTextAlignment(.center)
                        Text("You're all set")
                            .scaledFont(size: 26, weight: .heavy)
                            .tracking(-0.3)
                            .foregroundStyle(.white)
                    }
                    .padding(.top, 24)

                    resultCard(result)
                        .padding(.top, 24)

                    Button("Search a Different Name") {
                        backToSearch()
                    }
                    .buttonStyle(.secondaryOutline)
                    .padding(.top, 18)

                    Spacer(minLength: 24)

                    Text("A Seat Awaits · Where every guest matters")
                        .scaledFont(size: 12)
                        .foregroundStyle(Brand.textSecondary)
                        .padding(.top, 28)
                        .padding(.bottom, 20)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
                .readableWidth(Layout.formWidth)
            }
        }
        .preferredColorScheme(.light)
    }

    private func resultCard(_ result: GuestSearchResult) -> some View {
        VStack(spacing: 0) {
            Text("Your table")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(Brand.slate500)

            Text(result.tableNumber)
                .scaledFont(size: 72, weight: .heavy)
                .tracking(-2)
                .foregroundStyle(Brand.plum)
                .padding(.top, 8)

            // Seat pill.
            HStack(spacing: 8) {
                Text(result.tableDescription?.nilIfBlank ?? "Seat assigned")
                    .scaledFont(size: 14, weight: .bold)
                    .lineLimit(1)
            }
            .foregroundStyle(Brand.purple)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Brand.plumChipFill, in: Capsule())
            .padding(.top, 8)

            // Seated-with line.
            if let group = result.groupName?.nilIfBlank {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.fill")
                        .scaledFont(size: 15)
                        .foregroundStyle(Brand.teal)
                    Text("Seated with \(group)")
                        .scaledFont(size: 14)
                        .foregroundStyle(Brand.slate600)
                }
                .padding(.top, 18)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 24)
        .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Brand.plum.opacity(0.4), radius: 25, x: 0, y: 18)
    }

    private func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    // MARK: - Actions

    private func selectResult(_ guest: GuestSearchResult) {
        searchTask?.cancel()
        suggestions = []
        result = guest
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        #endif
    }

    private func backToSearch() {
        result = nil
        query = ""
        suggestions = []
        errorMessage = nil
    }

    private func clearSearch() {
        searchTask?.cancel()
        query = ""
        suggestions = []
        errorMessage = nil
    }

    // MARK: - Data

    private func loadEvents() async {
        eventsLoadError = nil
        do {
            events = try await supabase.select(
                "events",
                query: [URLQueryItem(name: "select", value: "*"),
                        URLQueryItem(name: "order", value: "created_at.desc")],
                as: [Event].self
            )
            if selectedEvent == nil || !events.contains(where: { $0.id == selectedEvent?.id }) {
                selectedEvent = events.first
            }
            isLoadingEvents = false
        } catch {
            // Navigating away cancels the `.task`; that is not a failure.
            guard !FriendlyError.isCancellation(error) else { return }
            isLoadingEvents = false
            eventsLoadError = FriendlyError.message(for: error)
        }
    }

    /// Debounced live search (>= 2 chars) against the RPC.
    private func scheduleSearch() {
        searchTask?.cancel()
        errorMessage = nil

        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else {
            suggestions = []
            isSearching = false
            return
        }

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 280_000_000)
            if Task.isCancelled { return }
            await runSearch(term)
        }
    }

    private func runSearch(_ term: String) async {
        guard let event = selectedEvent, let token = event.qrCodeToken else {
            suggestions = []
            return
        }
        isSearching = true
        defer { isSearching = false }

        do {
            var results = try await search(term: term, token: token)
            // The RPC is a plain ILIKE, so an accented query ("José") misses a
            // name stored without the accent. Retry once with the accents
            // stripped. (The reverse, "Jose" finding "José", needs unaccent in
            // the RPC and is matched client-side for highlighting only.)
            if results.isEmpty, GuestNameMatcher.hasDiacritics(term) {
                let folded = GuestNameMatcher.fold(term)
                if folded.count >= 2 {
                    results = try await search(term: folded, token: token)
                }
            }
            if Task.isCancelled { return }
            suggestions = results
            errorMessage = nil
        } catch {
            if Task.isCancelled || FriendlyError.isCancellation(error) { return }
            suggestions = []
            errorMessage = FriendlyError.message(for: error)
        }
    }

    private func search(term: String, token: String) async throws -> [GuestSearchResult] {
        try await supabase.rpc(
            "search_guests_by_qr_token",
            params: GuestSearchParams(p_token: token, p_query: term, p_limit: 8),
            as: [GuestSearchResult].self
        )
    }
}
