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

            if events.isEmpty {
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
                                .font(.system(size: 13, weight: .semibold))
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
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .preferredColorScheme(nil)
    }

    private var searchHeader: some View {
        VStack(spacing: 0) {
            // Glass logo tile (54pt) with a chair/sofa symbol.
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.white.opacity(0.14))
                .frame(width: 54, height: 54)
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                )
                .overlay(
                    Image(systemName: "sofa.fill")
                        .font(.system(size: 25, weight: .regular))
                        .foregroundStyle(.white)
                )

            if let name = selectedEvent?.name {
                Text(name.uppercased())
                    .font(.system(size: 14, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(Brand.lilac)
                    .multilineTextAlignment(.center)
                    .padding(.top, 22)
            }

            Text("Find your table")
                .font(.system(size: 34, weight: .heavy))
                .tracking(-0.5)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            Text("Type your name to see where you're seated.")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.top, 10)
        }
    }

    // White search input (radius 16, ~58pt, strong shadow).
    private var searchInput: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Brand.slate400)
            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("Your name")
                        .font(.system(size: 17))
                        .foregroundStyle(Brand.slate400)
                }
                TextField("", text: $query)
                    .font(.system(size: 17, weight: .semibold))
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
                        .font(.system(size: 18))
                        .foregroundStyle(Brand.slate300)
                }
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

    private func suggestionRow(_ guest: GuestSearchResult) -> some View {
        HStack(spacing: 12) {
            InitialsAvatar(name: guest.name, size: 38)
            Text(highlightedName(guest.name))
                .font(.system(size: 16))
                .foregroundStyle(Brand.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Brand.slate300)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    /// Bolds the matched prefix of the name against the current query.
    private func highlightedName(_ name: String) -> AttributedString {
        var attr = AttributedString(name)
        attr.font = .system(size: 16)
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return attr }
        if let range = name.range(of: term, options: [.caseInsensitive, .anchored]) {
            // Matched prefix from the start of the name.
            if let attrRange = Range(range, in: attr) {
                attr[attrRange].font = .system(size: 16, weight: .bold)
            }
        } else if let range = name.range(of: term, options: .caseInsensitive) {
            // Fall back to first occurrence anywhere.
            if let attrRange = Range(range, in: attr) {
                attr[attrRange].font = .system(size: 16, weight: .bold)
            }
        }
        return attr
    }

    private var noMatchHint: some View {
        Text("No guest found by that name yet — keep typing or check the spelling.")
            .font(.system(size: 13))
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
                        .font(.system(size: 12, weight: .semibold))
                    Text(selectedEvent?.name ?? "Choose event")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .bold))
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
                .font(.system(size: 13))
            Text("A Seat Awaits · Where every guest matters")
                .font(.system(size: 13))
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
                            .font(.system(size: 13, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(Brand.lilac)
                            .multilineTextAlignment(.center)
                        Text("You're all set")
                            .font(.system(size: 26, weight: .heavy))
                            .tracking(-0.3)
                            .foregroundStyle(.white)
                    }
                    .padding(.top, 24)

                    resultCard(result)
                        .padding(.top, 24)

                    Button("Search a different name") {
                        backToSearch()
                    }
                    .buttonStyle(.secondaryOutline)
                    .padding(.top, 18)

                    Spacer(minLength: 24)

                    Text("A Seat Awaits · Where every guest matters")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.slate400)
                        .padding(.top, 28)
                        .padding(.bottom, 20)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.light)
    }

    private func resultCard(_ result: GuestSearchResult) -> some View {
        VStack(spacing: 0) {
            Text("Your table")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Brand.slate500)

            Text(result.tableNumber)
                .font(.system(size: 72, weight: .heavy))
                .tracking(-2)
                .foregroundStyle(Brand.plum)
                .padding(.top, 8)

            // Seat pill.
            HStack(spacing: 8) {
                Text(result.tableDescription?.nilIfBlank ?? "Seat assigned")
                    .font(.system(size: 14, weight: .bold))
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
                        .font(.system(size: 15))
                        .foregroundStyle(Brand.teal)
                    Text("Seated with \(group)")
                        .font(.system(size: 14))
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
        do {
            events = try await supabase.select(
                "events",
                query: [URLQueryItem(name: "select", value: "*"),
                        URLQueryItem(name: "order", value: "created_at.desc")],
                as: [Event].self
            )
            if selectedEvent == nil { selectedEvent = events.first }
        } catch {
            errorMessage = error.localizedDescription
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

        let params = GuestSearchParams(p_token: token, p_query: term, p_limit: 8)
        do {
            let results = try await supabase.rpc(
                "search_guests_by_qr_token",
                params: params,
                as: [GuestSearchResult].self
            )
            if Task.isCancelled { return }
            suggestions = results
            errorMessage = nil
        } catch {
            if Task.isCancelled { return }
            suggestions = []
            errorMessage = error.localizedDescription
        }
    }
}
