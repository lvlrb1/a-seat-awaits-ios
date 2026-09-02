//
//  ImportGuestsView.swift
//  A Seat Awaits
//
//  Sheet entry point for bulk guest import. "Structure list" sends a pasted/CSV
//  list — or an uploaded Excel (.xlsx/.xls) file — to the `ai-import-guests`
//  Supabase Edge Function, which extracts every guest (adults, partners and
//  children, parity with the web app), then pushes `ReviewImportView`. For
//  text/CSV, if the AI call fails (offline, plan-gated, or AI error) it falls
//  back to the on-device `GuestImportParser`; Excel has no offline fallback.
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportGuestsView: View {
    @Bindable var store: SeatingStore
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var showingPaywall = false

    /// AI structuring is a paid feature (Standard/Premium Event Pass, or the
    /// Pro plan — Starter passes exclude it). Free accounts keep the on-device
    /// parser for typed/pasted lists; Excel needs the AI Edge Function, so it's
    /// blocked when gated. The edge function enforces this server-side — the
    /// gate keeps the UI honest.
    private var aiAllowed: Bool { store.entitlement.aiImport }

    /// The event is already at its plan/pass guest cap — importing more would
    /// only bounce off the DB trigger, so block it up front with upgrade copy.
    /// Engages only after the entitlement has loaded (same rule as AddGuestView).
    private var atCapacity: Bool {
        store.entitlementLoaded && store.guests.count >= store.entitlement.guestCap
    }

    /// A binary spreadsheet the user picked (Excel). Text/CSV files load into the
    /// paste editor instead; only true spreadsheets are held as an attachment.
    private struct PickedFile: Equatable {
        let data: Data
        let name: String
    }

    @State private var pasteText = ""
    @State private var pickedFile: PickedFile?
    @State private var parsed: [ParsedGuest] = []
    @State private var showReview = false
    @State private var showFileImporter = false
    @State private var importError: String?
    @State private var isStructuring = false
    @FocusState private var editorFocused: Bool

    /// File types the picker accepts: Excel + CSV/text.
    private static var allowedTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText, .plainText, .text, .utf8PlainText, .spreadsheet]
        if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
        if let xls = UTType(filenameExtension: "xls") { types.append(xls) }
        return types
    }

    /// Whether there's anything to structure (a file or some pasted text).
    private var hasInput: Bool {
        pickedFile != nil || !pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let placeholder = """
    Jordan Avery
    Sam & Riley Brooks
    Patel, Anjali
    Olivia Brown
    """

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Brand.canvas.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        if aiAllowed {
                            aiBanner
                                .padding(.top, 14)
                        } else {
                            aiUpsellBanner
                                .padding(.top, 14)
                        }

                        if atCapacity {
                            capacityBanner
                                .padding(.top, 12)
                        } else if let room = store.remainingGuestCapacity {
                            roomHint(room)
                                .padding(.top, 10)
                        }

                        dropZone
                            .padding(.top, 18)

                        if let file = pickedFile {
                            selectedFileChip(file)
                                .padding(.top, 12)
                        }

                        orDivider
                            .padding(.top, 20)

                        pasteEditor
                            .padding(.top, 16)

                        // Spacer so the pinned CTA never overlaps content.
                        Color.clear.frame(height: 96)
                    }
                    .padding(.horizontal, 20)
                }
                .scrollDismissesKeyboard(.interactively)

                importButton
            }
            .background(Brand.canvas)
            .safeAreaInset(edge: .top) {
                SheetHeader(title: "Import guests", onCancel: { dismiss() })
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .background(Brand.canvas)
            }
            .navigationBarHidden(true)
            .navigationDestination(isPresented: $showReview) {
                ReviewImportView(parsed: parsed, store: store, onFinish: { dismiss() })
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: Self.allowedTypes,
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .alert("Couldn't import",
                   isPresented: Binding(get: { importError != nil },
                                        set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .sheet(isPresented: $showingPaywall, onDismiss: {
                Task { await store.loadEntitlement() }
            }) {
                if let supabase = appState.supabase {
                    PaywallView(supabase: supabase, appState: appState,
                                mode: .plans(eventId: store.event.id))
                }
            }
        }
        .overlay {
            if isStructuring {
                StructuringOverlay()
                    .transition(.opacity)
            }
        }
    }

    // MARK: - AI hint banner

    /// Shown instead of `aiBanner` when the account isn't entitled to AI
    /// import: the built-in parser still handles typed/pasted names, and the
    /// button sells an Event Pass (or Pro) for AI structuring + Excel.
    private var aiUpsellBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.purple)
                Text("AI import is included with a Standard or Premium Event Pass, or the Pro plan.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text("Typed or pasted names still import with the built-in parser. Upgrade to structure messy lists and Excel files with AI.")
                .font(.system(size: 12))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("View plans") { showingPaywall = true }
                .buttonStyle(.secondaryOutline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Brand.plumChipFillSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.plumChipFill, lineWidth: 1)
        )
    }

    private var aiBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.purple)
            Text("We'll organize your list into guests you can review before importing.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.accent)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Brand.plumChipFillSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.plumChipFill, lineWidth: 1)
        )
    }

    /// Sets expectations before the planner pastes a list: how many guests this
    /// event can still take. The review step trims a longer list to fit rather
    /// than failing part way through.
    private func roomHint(_ room: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "person.2")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.textSecondary)
            Text("Room for \(room.formatted()) more \(room == 1 ? "guest" : "guests") on \(store.entitlement.guestCapSourceLabel).")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Blocks the import when the event is already at its guest cap.
    private var capacityBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Guest limit reached", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.warningText)
            Text("This event has \(store.guests.count) of \(store.entitlement.guestCap) guests on \(store.entitlement.guestCapSourceLabel). Upgrade to import more.")
                .font(.system(size: 12))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("View plans") { showingPaywall = true }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.warningFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.warningText.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Upload drop-zone

    private var dropZone: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Brand.primaryFill)
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "arrow.up")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                )
                .shadow(color: Brand.plum.opacity(0.5), radius: 12, x: 0, y: 10)

            Text("Upload a file")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
                .padding(.top, 14)

            Text(aiAllowed ? "Excel, CSV or text file · tap to browse"
                           : "CSV or text file · tap to browse")
                .font(.system(size: 14))
                .foregroundStyle(Brand.textSecondary)
                .padding(.top, 4)

            Text(aiAllowed ? "Supports .xlsx, .xls, .csv and plain text."
                           : "Supports .csv and plain text. Excel needs AI import.")
                .font(.system(size: 12))
                .foregroundStyle(Brand.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 3)

            Button("Choose file") { showFileImporter = true }
                .buttonStyle(.secondaryOutline)
                .frame(width: 160)
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Brand.control.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                .foregroundStyle(Brand.slate300)
        )
        // The copy says "tap to browse" — the whole card must honor that, not
        // just the small "Choose file" pill (which keeps working; taps inside
        // it are consumed by the Button before reaching this gesture).
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { showFileImporter = true }
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Selected spreadsheet chip

    private func selectedFileChip(_ file: PickedFile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Brand.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Ready to structure")
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.textSecondary)
            }
            Spacer(minLength: 0)
            Button {
                pickedFile = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Brand.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove file")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Brand.fieldFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.fieldBorder, lineWidth: 1)
        )
    }

    // MARK: - "or paste your list" divider

    private var orDivider: some View {
        HStack(spacing: 14) {
            Rectangle().fill(Brand.separator).frame(height: 1)
            Text("or type names, one per line")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Brand.textTertiary)
                .fixedSize()
            Rectangle().fill(Brand.separator).frame(height: 1)
        }
    }

    // MARK: - Paste editor

    private var pasteEditor: some View {
        ZStack(alignment: .topLeading) {
            if pasteText.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Brand.textTertiary)
                    .lineSpacing(5)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 22)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $pasteText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Brand.textPrimary)
                .tint(Brand.plum)
                .lineSpacing(5)
                .focused($editorFocused)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
        .frame(minHeight: 200)
        .background(Brand.fieldFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(editorFocused ? Brand.plum : Brand.fieldBorder, lineWidth: 1.5)
        )
    }

    // MARK: - Pinned import CTA

    private var importButton: some View {
        Button(action: runImport) {
            HStack(spacing: 9) {
                if isStructuring {
                    ProgressView()
                        .tint(.white)
                    Text("Structuring…")
                } else {
                    // Sparkles promise AI — show a plain glyph when the list
                    // will be structured by the on-device parser instead.
                    Image(systemName: aiAllowed ? "sparkles" : "text.badge.checkmark")
                        .font(.system(size: 18, weight: .bold))
                    Text("Submit")
                }
            }
        }
        .buttonStyle(.primaryBrand)
        .disabled(!hasInput || isStructuring || atCapacity)
        .opacity(!hasInput || isStructuring || atCapacity ? 0.5 : 1)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().fill(Brand.separator).frame(height: 1), alignment: .top)
    }

    // MARK: - Actions

    private func runImport() {
        editorFocused = false
        guard hasInput, !isStructuring, !atCapacity else { return }

        // A picked spreadsheet wins over pasted text.
        let input: GuestImportInput
        if let file = pickedFile {
            input = .file(data: file.data, name: file.name)
        } else {
            input = .text(pasteText)
        }

        withAnimation(.easeInOut(duration: 0.3)) { isStructuring = true }
        Task {
            let started = Date()
            let outcome = await structuredGuests(for: input)
            // Hold the animation briefly so it never just flashes on fast results.
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 0.9 {
                try? await Task.sleep(nanoseconds: UInt64((0.9 - elapsed) * 1_000_000_000))
            }
            withAnimation(.easeInOut(duration: 0.3)) { isStructuring = false }
            switch outcome {
            case .success(let results) where !results.isEmpty:
                parsed = results
                showReview = true
            case .success:
                importError = "We couldn't find any names in that list. Check the format and try again."
            case .failure(let message):
                importError = message
            }
        }
    }

    /// Either parsed guests or a friendly message to surface. (A plain enum rather
    /// than `Result`, whose failure type must conform to `Error` — `String` doesn't.)
    private enum StructuringOutcome {
        case success([ParsedGuest])
        case failure(String)
    }

    /// Structures the input with the AI Edge Function. For text/CSV it falls back
    /// to the on-device parser on any failure; Excel is binary so it has no
    /// offline fallback — a failure there surfaces a friendly message.
    /// Un-entitled accounts skip the AI call entirely and use the parser.
    private func structuredGuests(for input: GuestImportInput) async -> StructuringOutcome {
        guard aiAllowed else {
            switch input {
            case .text(let text):
                return .success(GuestImportParser.parse(text))
            case .file:
                // Unreachable: the file picker rejects spreadsheets when gated.
                return .failure("Excel import requires a Standard or Premium Event Pass, or the Pro plan.")
            }
        }
        do {
            return .success(try await store.aiStructureGuests(input))
        } catch {
            switch input {
            case .text(let text):
                return .success(GuestImportParser.parse(text))
            case .file:
                return .failure(FriendlyError.message(for: error))
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let ext = url.pathExtension.lowercased()
                if ext == "xlsx" || ext == "xls" {
                    // Binary spreadsheet — parsed server-side by the AI Edge
                    // Function, so it's a paid-only input.
                    guard aiAllowed else {
                        importError = "Excel files are structured with AI import, included with a Standard or Premium Event Pass or the Pro plan. Export your sheet as CSV, or upgrade to import it directly."
                        return
                    }
                    // Hold it as an attachment; clearing pasteText keeps the
                    // input unambiguous.
                    pickedFile = PickedFile(data: data, name: url.lastPathComponent)
                } else {
                    // Text / CSV — load into the paste editor so it stays editable.
                    let text = String(decoding: data, as: UTF8.self)
                    pickedFile = nil
                    if pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        pasteText = text
                    } else {
                        pasteText += "\n" + text
                    }
                }
            } catch {
                importError = FriendlyError.message(for: error)
            }
        case .failure(let error):
            importError = FriendlyError.message(for: error)
        }
    }
}
