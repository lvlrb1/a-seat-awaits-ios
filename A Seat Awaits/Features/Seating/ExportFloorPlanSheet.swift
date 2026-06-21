//
//  ExportFloorPlanSheet.swift
//  A Seat Awaits
//
//  "Export & Print Floor Plan" sheet. Generates the PDF on-device with
//  `FloorPlanPDFRenderer` (a native port of the web app's renderer), saves the
//  bytes to a temp file, and hands them to the native share sheet.
//

import SwiftUI

struct ExportFloorPlanSheet: View {
    let event: Event
    /// Snapshot of the floor-plan data to render.
    let tables: [SeatingTable]
    let guests: [Guest]
    let shapes: [DecorShape]
    let rooms: [FloorPlanRoom]

    @Environment(\.dismiss) private var dismiss

    /// Opt-in, matching the web app's default-off toggle.
    @State private var includeGuestList = false
    @State private var isExporting = false
    @State private var errorMessage: String?
    /// Drives the native share sheet once the PDF is saved.
    @State private var exported: ExportedDocument?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    intro
                    guestListToggle
                    if let errorMessage {
                        errorNotice(errorMessage)
                    }
                }
                .padding(20)
            }
            .background(Brand.canvas)
            .safeAreaInset(edge: .bottom) { footer }
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
        #if canImport(UIKit)
        .sheet(item: $exported) { doc in
            ShareSheet(items: [FloorPlanActivityItem(url: doc.url, title: "\(event.name) — Floor Plan")]) {
                dismiss()
            }
        }
        #endif
    }

    // MARK: - Sections

    private var intro: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Brand.accent.opacity(0.12))
                Image(systemName: "printer.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Brand.accent)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 6) {
                Text("A polished, shareable PDF")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                Text("Your floor plan is drawn as a clean vector seating chart — tables, chairs, rooms, and decor, fit to the page and ready to print or share.")
                    .font(.system(size: 14))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    private var guestListToggle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $includeGuestList) {
                Text("Include guest list pages")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
            }
            .tint(Brand.accent)
            .disabled(isExporting)

            Text("Append printable pages listing each table with its guests, sorted by last name.")
                .font(.system(size: 13))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    private func errorNotice(_ message: String) -> some View {
        Label {
            Text(message).font(.system(size: 14, weight: .medium))
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

    // MARK: - Export flow

    private func export() async {
        // Guard against duplicate requests from a double-tap.
        guard !isExporting else { return }
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }

        // Snapshot the data so the render can run off the main actor.
        let event = event
        let tables = tables, guests = guests, shapes = shapes, rooms = rooms
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
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't generate the floor-plan PDF. Please try again."
        }
    }
}
