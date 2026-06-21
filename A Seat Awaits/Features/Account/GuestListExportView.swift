//
//  GuestListExportView.swift
//  A Seat Awaits
//
//  A native event selector for exporting a single event's guest list as a CSV
//  spreadsheet, assembled from authenticated, RLS-scoped Supabase queries and
//  shared via the system share sheet. Entitlement (export & print) is shown via
//  `PlanPolicy`; the row is never a dead or misleading link to a web page.
//

import SwiftUI

struct GuestListExportView: View {
    @Bindable var store: AccountStore
    let policy: PlanPolicy
    @Environment(\.openURL) private var openURL

    @State private var events: [Event] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var exportingEventID: String?
    @State private var exportError: String?
    @State private var exported: ExportedDocument?

    private var canExport: Bool { policy.canExportAndPrint }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !canExport { entitlementCard }
                content
            }
            .padding(18)
        }
        .background(Brand.canvas.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .navigationTitle("Export Guest Lists")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadEventsIfNeeded() }
        .refreshable { await loadEvents() }
        #if canImport(UIKit)
        .sheet(item: $exported) { doc in
            ShareSheet(items: [doc.url])
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if let exportError {
            FeedbackBanner(kind: .error, message: exportError)
        }
        if isLoading {
            ProgressView("Loading events…")
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if let loadError {
            errorState(loadError)
        } else if events.isEmpty {
            emptyState
        } else {
            eventsList
        }
    }

    private var entitlementCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Brand.warning)
                Text("Export isn't included in your plan")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
            }
            Text("Exporting and printing is available on Essentials and above. You can still browse your events below.")
                .font(.system(size: 13))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if AccountLinks.externalUpgradeEnabled {
                Button("View Plans") { openURL(AccountLinks.upgrade) }
                    .buttonStyle(.secondaryOutline)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    private var eventsList: some View {
        VStack(spacing: 8) {
            AccountSectionHeader(title: "Choose an event")
            AccountCardGroup {
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { AccountRowDivider(inset: 16) }
                    eventRow(event)
                }
            }
        }
    }

    private func eventRow(_ event: Event) -> some View {
        Button {
            Task { await export(event) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)
                        .multilineTextAlignment(.leading)
                    if let date = event.displayDate {
                        Text(date)
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                if exportingEventID == event.id {
                    ProgressView()
                } else {
                    Image(systemName: canExport ? "square.and.arrow.up" : "lock")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(canExport ? Brand.accent : Brand.slate300)
                }
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canExport || exportingEventID != nil)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 32))
                .foregroundStyle(Brand.slate300)
            Text("No events yet")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
            Text("Create an event and add guests, then export the list here.")
                .font(.system(size: 14))
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(Brand.warning)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { Task { await loadEvents() } }
                .buttonStyle(.secondaryOutline)
                .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Data

    private func loadEventsIfNeeded() async {
        if events.isEmpty && loadError == nil { await loadEvents() }
    }

    private func loadEvents() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            events = try await store.fetchOwnedEvents()
        } catch {
            loadError = AccountStore.message(for: error)
        }
    }

    private func export(_ event: Event) async {
        guard canExport, exportingEventID == nil else { return }
        exportingEventID = event.id
        exportError = nil
        defer { exportingEventID = nil }
        switch await store.exportGuestList(for: event) {
        case .success(let url):
            exported = ExportedDocument(url: url)
        case .failure(let error):
            exportError = AccountStore.message(for: error)
        }
    }
}
