//
//  ImportGuestsView.swift
//  A Seat Awaits
//
//  Sheet entry point for bulk guest import. The backend AI import endpoint is
//  web-only, so this runs a fully on-device heuristic parser
//  (`GuestImportParser`) over pasted text or an imported CSV / plain-text file,
//  then pushes `ReviewImportView` for confirmation.
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportGuestsView: View {
    @Bindable var store: SeatingStore
    @Environment(\.dismiss) private var dismiss

    @State private var pasteText = ""
    @State private var parsed: [ParsedGuest] = []
    @State private var showReview = false
    @State private var showFileImporter = false
    @State private var importError: String?
    @FocusState private var editorFocused: Bool

    private let placeholder = """
    Adams, Layla & +1 — veg
    chris anderson (eng) table?
    Brown, Jackson - GF, w/ partner
    Olivia Brown — marketing
    """

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Brand.canvas.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        aiBanner
                            .padding(.top, 14)

                        dropZone
                            .padding(.top, 18)

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
                allowedContentTypes: [.commaSeparatedText, .plainText, .text, .utf8PlainText],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .alert("Couldn't read file",
                   isPresented: Binding(get: { importError != nil },
                                        set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    // MARK: - AI hint banner

    private var aiBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.purple)
            Text("We'll structure your list — names, households and dietary notes — then you review before importing.")
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

            Text("CSV or text file · tap to browse")
                .font(.system(size: 14))
                .foregroundStyle(Brand.textSecondary)
                .padding(.top, 4)

            Text("Exporting from a spreadsheet? Save it as CSV first.")
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
    }

    // MARK: - "or paste your list" divider

    private var orDivider: some View {
        HStack(spacing: 14) {
            Rectangle().fill(Brand.separator).frame(height: 1)
            Text("or paste your list")
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
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .bold))
                Text("Structure list")
            }
        }
        .buttonStyle(.primaryBrand)
        .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .opacity(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().fill(Brand.separator).frame(height: 1), alignment: .top)
    }

    // MARK: - Actions

    private func runImport() {
        editorFocused = false
        let results = GuestImportParser.parse(pasteText)
        guard !results.isEmpty else { return }
        parsed = results
        showReview = true
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let text = String(decoding: data, as: UTF8.self)
                // Append into the paste buffer so the user can review/edit.
                if pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pasteText = text
                } else {
                    pasteText += "\n" + text
                }
            } catch {
                importError = FriendlyError.message(for: error)
            }
        case .failure(let error):
            importError = FriendlyError.message(for: error)
        }
    }
}
