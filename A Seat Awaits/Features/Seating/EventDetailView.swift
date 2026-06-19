//
//  EventDetailView.swift
//  A Seat Awaits
//
//  The seating workspace for one event: a custom sub-header (event switcher +
//  collaborators), a segmented control switching between the Guests list, the
//  Tables floor plan, and a More options tab. Section 03 of the design spec.
//

import SwiftUI

struct EventDetailView: View {
    let event: Event
    @Environment(AppState.self) private var appState
    @State private var store: SeatingStore
    @State private var selection = 0
    @State private var showingAddGuest = false
    @State private var showingAddTable = false

    init(event: Event, supabase: SupabaseClient) {
        self.event = event
        _store = State(initialValue: SeatingStore(event: event, supabase: supabase))
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader

            Group {
                switch selection {
                case 0:
                    GuestListView(store: store)
                case 1:
                    FloorPlanView(store: store)
                default:
                    moreTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Brand.canvas)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showingAddGuest = true } label: { Label("Add Guest", systemImage: "person.badge.plus") }
                    Button { showingAddTable = true } label: { Label("Add Table", systemImage: "plus.square.on.square") }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddGuest) { AddGuestView(store: store) }
        .sheet(isPresented: $showingAddTable) { AddTableView(store: store) }
        .overlay {
            if store.isLoading && store.guests.isEmpty && store.tables.isEmpty {
                ProgressView("Loading…")
            }
        }
        .task { await store.loadAll() }
        .alert("Something went wrong",
               isPresented: Binding(get: { store.errorMessage != nil },
                                    set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    // MARK: - Custom workspace sub-header

    private var workspaceHeader: some View {
        VStack(spacing: 8) {
            HStack {
                // The back affordance is provided by the native nav bar.
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    Text(event.name)
                        .font(.system(size: 17, weight: .bold))
                        .tracking(-0.2)
                        .foregroundStyle(Brand.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Brand.slate400)
                }
                Spacer(minLength: 0)
                AvatarStack(names: collaboratorNames)
            }
            .frame(height: 40)

            BrandSegmentedControl(titles: ["Guests", "Tables", "More"], selection: $selection)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .background(Brand.card)
        .overlay(Brand.hairline.frame(height: 1), alignment: .bottom)
    }

    /// Collaborators to show in the avatar stack. We have no collaborator list in
    /// this store, so fall back to the signed-in planner's name.
    private var collaboratorNames: [String] {
        if let name = appState.currentUser?.displayName, !name.isEmpty {
            return [name]
        }
        return ["Planner"]
    }

    // MARK: - More tab

    private var moreTab: some View {
        ScrollView {
            VStack(spacing: 10) {
                infoRow(icon: "calendar", title: "Event", value: event.name)
                if let date = event.displayDate {
                    infoRow(icon: "clock", title: "Date", value: date)
                }
                if let location = event.location?.nilIfBlank {
                    infoRow(icon: "mappin.and.ellipse", title: "Location", value: location)
                }
                if event.qrCodeToken != nil {
                    NavigationLink {
                        if let supabase = appState.supabase {
                            FindYourTableView(supabase: supabase)
                        }
                    } label: {
                        moreRow(icon: "qrcode", title: "Find Your Table / QR",
                                trailing: "chevron.right")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(Brand.canvas)
    }

    private func infoRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Brand.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
                Text(value)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    private func moreRow(icon: String, title: String, trailing: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Brand.accent)
                .frame(width: 28)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Brand.textPrimary)
            Spacer(minLength: 0)
            Image(systemName: trailing)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.slate400)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }
}
