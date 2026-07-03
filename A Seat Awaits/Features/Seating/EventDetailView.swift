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
    @State private var showingExport = false
    @State private var showingQRCode = false
    @State private var showingCollaborators = false
    @State private var exportingGuestList = false
    @State private var exportedGuestList: ExportedDocument?

    /// Anything worth putting in a floor-plan PDF.
    private var hasFloorPlan: Bool {
        !store.tables.isEmpty || !store.shapes.isEmpty || !store.rooms.isEmpty
    }

    init(event: Event, supabase: SupabaseClient) {
        self.event = event
        _store = State(initialValue: SeatingStore(event: event, supabase: supabase))
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader

            if store.isOffline {
                OfflineBanner()
            }

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
        .undoSnackbar(store.undo)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Open the export sheet on the Tables tab when there's a plan to export.
            if selection == 1 && hasFloorPlan {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingExport = true } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export floor plan as PDF")
                }
            }
            if store.canEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showingAddGuest = true } label: { Label("Add Guest", systemImage: "person.badge.plus") }
                        Button { showingAddTable = true } label: { Label("Add Table", systemImage: "plus.square.on.square") }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddGuest) { AddGuestView(store: store) }
        .sheet(isPresented: $showingAddTable) { AddTableView(store: store) }
        .sheet(isPresented: $showingExport) {
            ExportFloorPlanSheet(event: event, tables: store.tables, guests: store.guests,
                                 shapes: store.shapes, rooms: store.rooms)
        }
        .sheet(isPresented: $showingQRCode) {
            if let supabase = appState.supabase {
                QRCodeView(event: event, supabase: supabase,
                           currentUserID: appState.currentUser?.id,
                           baseURL: appState.publicSiteURL)
            }
        }
        .sheet(isPresented: $showingCollaborators) {
            if let supabase = appState.supabase {
                EventCollaboratorsView(
                    event: event, supabase: supabase, siteURL: appState.publicSiteURL,
                    ownerName: appState.currentUser?.displayName ?? "You",
                    ownerEmail: appState.currentUser?.email ?? "")
            }
        }
        #if canImport(UIKit)
        .sheet(item: $exportedGuestList) { doc in
            ShareSheet(items: [doc.url])
        }
        #endif
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
                Text(event.name)
                    .font(.system(size: 17, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
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

    /// Collaborators to show in the avatar stack, sourced from the event's
    /// `event_collaborators` RPC. Falls back to the signed-in planner's name
    /// until the list loads (or if the event has no shares).
    private var collaboratorNames: [String] {
        let names = store.collaborators.map(\.displayName).filter { !$0.isEmpty }
        if !names.isEmpty { return names }
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
                // Manage who can collaborate on this event. Owner-only: only the
                // owner may invite or change access (enforced by RLS server-side).
                if store.role == .owner {
                    Button {
                        showingCollaborators = true
                    } label: {
                        moreRow(icon: "person.2", title: "Collaborators",
                                trailing: "chevron.right",
                                badge: store.collaborators.count > 1 ? "\(store.collaborators.count - 1)" : nil)
                    }
                    .buttonStyle(.plain)
                }

                // Generate / share the event's guest QR code. Opens the
                // event-specific Share Event screen (no event re-selection).
                Button {
                    showingQRCode = true
                } label: {
                    moreRow(icon: "qrcode", title: "Guest QR Code",
                            trailing: "chevron.right")
                }
                .buttonStyle(.plain)

                // Export this event's guest list as a CSV via the share sheet.
                // Disabled until there are guests to export.
                Button {
                    Task { await exportGuestList() }
                } label: {
                    moreRow(icon: "square.and.arrow.up", title: "Export Guest List",
                            trailing: exportingGuestList ? nil : "chevron.right",
                            showsProgress: exportingGuestList)
                }
                .buttonStyle(.plain)
                .disabled(store.guests.isEmpty || exportingGuestList)
                .opacity(store.guests.isEmpty ? 0.5 : 1)
            }
            .padding(16)
        }
        .background(Brand.canvas)
    }

    private func exportGuestList() async {
        guard !exportingGuestList, !store.guests.isEmpty,
              let supabase = appState.supabase else { return }
        exportingGuestList = true
        defer { exportingGuestList = false }
        do {
            let url = try await GuestListExporter(supabase: supabase).run(event: event, now: Date())
            exportedGuestList = ExportedDocument(url: url)
        } catch {
            store.errorMessage = FriendlyError.message(for: error)
        }
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

    private func moreRow(icon: String, title: String, trailing: String?,
                         showsProgress: Bool = false, badge: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Brand.accent)
                .frame(width: 28)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Brand.textPrimary)
            Spacer(minLength: 0)
            if let badge {
                Text(badge)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Brand.accent)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Brand.plumChipFill, in: Capsule())
            }
            if showsProgress {
                ProgressView()
            } else if let trailing {
                Image(systemName: trailing)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.slate400)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }
}
