//
//  ExportFloorPlanSheet.swift
//  A Seat Awaits
//
//  "Export & Print Floor Plan" sheet. Generates the PDF on-device with
//  `FloorPlanPDFRenderer` (a native port of the web app's renderer), saves the
//  bytes to a temp file, and hands them to the native share sheet.
//

import StoreKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ExportFloorPlanSheet: View {
    /// Source of the floor-plan data and the viewer's entitlement. Export &
    /// print is a paid feature — the sheet shows an upgrade gate (mirroring the
    /// web modal) until `store.entitlement` grants it.
    @Bindable var store: SeatingStore

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(\.requestReview) private var requestReview

    private var event: Event { store.event }
    /// Strict gate: Free until the entitlement resolves. The local renderer has
    /// no server backstop, so this check is the enforcement.
    private var canExport: Bool { store.entitlement.exportAndPrint }

    /// Opt-in, matching the web app's default-off toggle.
    @State private var includeGuestList = false
    @State private var isExporting = false
    @State private var errorMessage: String?
    /// Drives the native share sheet once the PDF is saved.
    @State private var exported: ExportedDocument?
    @State private var showingPaywall = false

    #if canImport(UIKit)
    /// Rasterized page 1 of the PDF, shown as the preview (the web modal
    /// snapshots the live canvas the same way).
    @State private var preview: UIImage?
    @State private var isLoadingPreview = true
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if canExport {
                        intro
                        #if canImport(UIKit)
                        previewCard
                        #endif
                        guestListToggle
                        if let errorMessage {
                            errorNotice(errorMessage)
                        }
                    } else {
                        upgradeGate
                    }
                }
                .padding(20)
            }
            .background(Brand.canvas)
            .safeAreaInset(edge: .bottom) {
                if canExport { footer }
            }
            .navigationTitle("Export & Print Floor Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isExporting)
                }
            }
        }
        // Block swipe-to-dismiss mid-export so a request can't be orphaned.
        .interactiveDismissDisabled(isExporting)
        // Self-heal a not-yet-loaded entitlement, then render the preview once
        // (and again if a purchase mid-sheet flips the gate open).
        .task(id: canExport) {
            if !store.entitlementLoaded { await store.loadEntitlement() }
            #if canImport(UIKit)
            if canExport, preview == nil { await loadPreview() }
            #endif
        }
        .sheet(isPresented: $showingPaywall, onDismiss: {
            Task { await store.loadEntitlement() }
        }) {
            if let supabase = appState.supabase {
                PaywallView(supabase: supabase, appState: appState,
                            mode: .plans(eventId: event.id))
            }
        }
        #if canImport(UIKit)
        .sheet(item: $exported) { doc in
            ShareSheet(items: [FloorPlanActivityItem(url: doc.url, title: "\(event.name) Floor Plan")]) { completed in
                dismiss()
                // A shared/saved export is a moment of delight: the only place
                // in this flow the rating prompt may be requested (once per app
                // version). A cancelled share sheet never prompts.
                if completed { ReviewPromptGate.requestIfEligible(requestReview) }
            }
        }
        #endif
    }

    // MARK: - Sections

    /// The web modal's "Available on paid plans" state, selling an Event Pass
    /// (or Pro) instead of rendering the export options.
    private var upgradeGate: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Brand.accent.opacity(0.12))
                Image(systemName: "sparkles")
                    .scaledFont(size: 24, weight: .semibold)
                    .foregroundStyle(Brand.accent)
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)

            Text("Available on paid plans")
                .scaledFont(size: 17, weight: .bold)
                .foregroundStyle(Brand.textPrimary)

            Text("Export and print a beautifully branded floor plan PDF. Included with any Event Pass, or with Pro.")
                .scaledFont(size: 14)
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showingPaywall = true
            } label: {
                Label("View Plans", systemImage: "sparkles")
            }
            .buttonStyle(.primaryBrand)
            .padding(.top, 4)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .brandCard()
    }

    private var intro: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Brand.accent.opacity(0.12))
                Image(systemName: "printer.fill")
                    .scaledFont(size: 20, weight: .semibold)
                    .foregroundStyle(Brand.accent)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 6) {
                Text("A polished, shareable PDF")
                    .scaledFont(size: 16, weight: .bold)
                    .foregroundStyle(Brand.textPrimary)
                Text("Your floor plan is drawn as a clean vector seating chart: tables, chairs, rooms, and decor, fit to the page and ready to print or share.")
                    .scaledFont(size: 14)
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    #if canImport(UIKit)
    /// Mirrors the web modal's floor-plan snapshot: page 1 of the PDF,
    /// rasterized once when the sheet appears. Hidden entirely if the
    /// preview fails — it's optional, like the web's canvas capture.
    @ViewBuilder
    private var previewCard: some View {
        if let preview {
            Image(uiImage: preview)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Brand.hairline)
                )
                .padding(12)
                .frame(maxWidth: .infinity)
                .brandCard()
        } else if isLoadingPreview {
            VStack(spacing: 10) {
                ProgressView().tint(Brand.accent)
                Text("Loading preview…")
                    .scaledFont(size: 13)
                    .foregroundStyle(Brand.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
            .brandCard()
        }
    }
    #endif

    private var guestListToggle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $includeGuestList) {
                Text("Include guest list pages")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(Brand.textPrimary)
            }
            .tint(Brand.accent)
            .disabled(isExporting)

            Text("Append printable pages listing each table with its guests, sorted by last name.")
                .scaledFont(size: 13)
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    private func errorNotice(_ message: String) -> some View {
        Label {
            Text(message).scaledFont(size: 14, weight: .medium)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(Brand.collisionStroke)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    private var footer: some View {
        Button {
            Task { await export() }
        } label: {
            if isExporting {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Generating PDF…")
                }
            } else {
                Text("Export PDF")
            }
        }
        .buttonStyle(.primaryBrand)
        .disabled(isExporting)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Brand.card)
        .overlay(Brand.hairline.frame(height: 1), alignment: .top)
    }

    // MARK: - Preview

    #if canImport(UIKit)
    private func loadPreview() async {
        let event = event
        let tables = store.tables, guests = store.guests,
            shapes = store.shapes, rooms = store.rooms

        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            let data = FloorPlanPDFRenderer.render(event: event, tables: tables, guests: guests,
                                                   shapes: shapes, rooms: rooms,
                                                   includeGuestList: false)
            guard let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider),
                  let page = document.page(at: 1) else { return nil }

            let box = page.getBoxRect(.mediaBox)
            guard box.width > 0, box.height > 0 else { return nil }
            let scale: CGFloat = 2
            let size = CGSize(width: box.width * scale, height: box.height * scale)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                // PDF pages are bottom-up; flip into UIKit's top-down space.
                ctx.cgContext.translateBy(x: 0, y: size.height)
                ctx.cgContext.scaleBy(x: scale, y: -scale)
                ctx.cgContext.drawPDFPage(page)
            }
        }.value

        preview = image
        isLoadingPreview = false
    }
    #endif

    // MARK: - Export flow

    private func export() async {
        // Guard against duplicate requests from a double-tap. The entitlement
        // check backs up the UI gate (the footer isn't shown when gated).
        guard !isExporting, canExport else { return }
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }

        // Snapshot the data so the render can run off the main actor.
        let event = event
        let tables = store.tables, guests = store.guests,
            shapes = store.shapes, rooms = store.rooms
        let includeGuestList = includeGuestList

        do {
            let data = await Task.detached(priority: .userInitiated) {
                FloorPlanPDFRenderer.render(event: event, tables: tables, guests: guests,
                                            shapes: shapes, rooms: rooms,
                                            includeGuestList: includeGuestList)
            }.value
            let url = try FloorPlanExportFile.write(data, eventName: event.name)
            exported = ExportedDocument(url: url)
        } catch {
            // The file write is local, so a network-flavoured line would be
            // wrong; `FriendlyError` still owns the wording for anything it
            // recognises (offline, cancellation), and the rest gets one calm
            // export-specific fallback rather than a raw description.
            errorMessage = FriendlyError.isOffline(error) || FriendlyError.isCancellation(error)
                ? FriendlyError.message(for: error)
                : "Couldn't generate the floor-plan PDF. Please try again."
        }
    }
}
