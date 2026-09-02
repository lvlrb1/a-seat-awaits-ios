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
    /// Templates sheet with the save-name prompt pre-opened ("Save as Template").
    @State private var showingSaveTemplate = false
    @State private var showingQRCode = false
    @State private var showingCollaborators = false
    @State private var exportingGuestList = false
    @State private var exportedGuestList: ExportedDocument?

    /// The event's Event Pass, if the signed-in user owns one for it (RLS
    /// returns only the purchaser's rows, so collaborators see nothing).
    @State private var eventPass: EventPass?
    @State private var showingPassUpgrade = false
    /// The guest being steered to a seat on the floor plan ("Seat on Floor
    /// Plan" from the Guests tab). Non-nil puts the Tables tab in assign mode.
    @State private var seatingGuest: Guest?

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
                    GuestListView(store: store) { guest in
                        seatingGuest = guest
                        withAnimation(.snappy(duration: 0.2)) { selection = 1 }
                    }
                case 1:
                    FloorPlanView(store: store,
                                  assigning: seatingGuest,
                                  onFinishAssigning: { seatingGuest = nil })
                default:
                    moreTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Brand.canvas)
        .undoSnackbar(store.undo)
        // Leaving the Tables tab mid-assign cancels the assign, so a stale
        // "SEATING" banner never greets the planner on their way back.
        .onChange(of: selection) { _, newValue in
            if newValue != 1 { seatingGuest = nil }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Floor-plan actions on the Tables tab once there's a plan. Editors
            // get a menu (export + save as template); viewers keep the one-tap
            // export button — a single-item menu would just add a tap.
            if selection == 1 && hasFloorPlan {
                ToolbarItem(placement: .topBarTrailing) {
                    if store.canEdit {
                        Menu {
                            Button { showingExport = true } label: {
                                Label("Export & Print PDF…", systemImage: "printer")
                            }
                            Button { showingSaveTemplate = true } label: {
                                Label("Save as Template…", systemImage: "square.and.arrow.down")
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Export or save floor plan")
                    } else {
                        Button { showingExport = true } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Export floor plan as PDF")
                    }
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
                    .accessibilityLabel("Add guest or table")
                }
            }
        }
        .sheet(isPresented: $showingAddGuest) { AddGuestView(store: store) }
        .sheet(isPresented: $showingAddTable) { AddTableView(store: store) }
        .sheet(isPresented: $showingExport) {
            ExportFloorPlanSheet(store: store)
        }
        .sheet(isPresented: $showingSaveTemplate) {
            TemplatesView(store: store, promptSaveOnAppear: true)
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
        .sheet(isPresented: $showingPassUpgrade, onDismiss: {
            Task {
                await loadEventPass()
                // A tier change can unlock feature gates (export, AI import).
                await store.loadEntitlement()
            }
        }) {
            if let supabase = appState.supabase, let tier = eventPass?.passTier {
                PaywallView(supabase: supabase, appState: appState,
                            mode: .upgrade(eventId: event.id, from: tier))
            }
        }
        .overlay {
            if store.isLoading && store.guests.isEmpty && store.tables.isEmpty {
                ProgressView("Loading…")
            }
        }
        .task {
            // Only the first appearance loads; the store keeps the workspace
            // warm across tab switches and re-appearances. Pull-to-refresh on
            // the Guests tab remains the explicit reload.
            if store.guests.isEmpty && store.tables.isEmpty {
                await store.loadAll()
            }
            if eventPass == nil {
                await loadEventPass()
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

    // MARK: - Custom workspace sub-header

    private var workspaceHeader: some View {
        VStack(spacing: 8) {
            HStack {
                // The back affordance is provided by the native nav bar.
                Spacer(minLength: 0)
                Text(event.name)
                    .scaledFont(size: 17, weight: .bold)
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

                if let pass = eventPass {
                    passCard(pass)
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
                // event-specific Share Event screen (no event re-selection);
                // the row is named after the screen it opens.
                Button {
                    showingQRCode = true
                } label: {
                    moreRow(icon: "qrcode", title: "Share Event",
                            trailing: "chevron.right")
                }
                .buttonStyle(.plain)

                // The branded floor-plan PDF (same sheet as the Tables-tab
                // toolbar icon; paid-gated inside). Disabled until the plan
                // has anything to draw.
                Button {
                    showingExport = true
                } label: {
                    moreRow(icon: "printer", title: "Export & Print Floor Plan",
                            trailing: "chevron.right")
                }
                .buttonStyle(.plain)
                .disabled(!hasFloorPlan)
                .opacity(hasFloorPlan ? 1 : 0.5)

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
            .readableWidth(Layout.contentWidth)
        }
        .background(Brand.canvas)
    }

    // MARK: - Event Pass

    /// Loads the event's pass. Errors are non-fatal — the More tab simply
    /// doesn't show a pass card (collaborators and legacy subscribers won't
    /// have one).
    private func loadEventPass() async {
        guard let supabase = appState.supabase else { return }
        do {
            let rows = try await supabase.select(
                "event_passes",
                query: [
                    URLQueryItem(name: "select", value: EventPass.selectColumns),
                    URLQueryItem(name: "event_id", value: "eq.\(event.id)"),
                ],
                as: [EventPass].self)
            eventPass = rows.first
        } catch {
            // Non-fatal: no pass card.
        }
    }

    /// The pass that covers this event: tier, guest cap, AI-import usage, and
    /// the in-place upgrade entry point (display only — caps are enforced
    /// server-side).
    private func passCard(_ pass: EventPass) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "ticket")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(Brand.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Event Pass")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(Brand.textSecondary)
                    Text(pass.tierDisplayName)
                        .scaledFont(size: 16, weight: .semibold)
                        .foregroundStyle(Brand.textPrimary)
                }
                Spacer(minLength: 0)
                if !pass.isActive {
                    Text("Refunded")
                        .scaledFont(size: 11, weight: .bold)
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(Brand.danger)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Brand.danger.opacity(0.12), in: Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Up to \(pass.guestCap.formatted()) guests")
                    .scaledFont(size: 13)
                    .foregroundStyle(Brand.textSecondary)
                if pass.aiImportCap > 0 {
                    Text("AI imports used: \(pass.aiImportsUsed) of \(pass.aiImportCap)")
                        .scaledFont(size: 13)
                        .foregroundStyle(Brand.textSecondary)
                }
            }

            if pass.isActive, let tier = pass.passTier, !tier.upgradeTargets.isEmpty,
               store.role == .owner {
                Button("Upgrade Pass") { showingPassUpgrade = true }
                    .buttonStyle(.secondaryOutline)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
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
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(Brand.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(Brand.textSecondary)
                Text(value)
                    .scaledFont(size: 16, weight: .semibold)
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
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(Brand.accent)
                .frame(width: 28)
            Text(title)
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(Brand.textPrimary)
            Spacer(minLength: 0)
            if let badge {
                Text(badge)
                    .scaledFont(size: 13, weight: .bold)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(Brand.accent)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Brand.plumChipFill, in: Capsule())
            }
            if showsProgress {
                ProgressView()
            } else if let trailing {
                Image(systemName: trailing)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(Brand.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }
}
