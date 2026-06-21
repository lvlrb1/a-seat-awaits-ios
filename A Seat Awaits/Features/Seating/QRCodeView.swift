//
//  QRCodeView.swift
//  A Seat Awaits
//
//  The "Share Event" screen: a scannable guest QR code with the public link,
//  share / copy / open actions, and a privacy note. The QR image is generated
//  locally (Core Image) and shared as a clean PNG — never a screenshot of the
//  screen. Presentation here; all logic lives in `QRCodeStore`.
//

import SwiftUI

struct QRCodeView: View {
    @State private var store: QRCodeStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingRegenerateConfirm = false
    @State private var showingDisableConfirm = false

    init(event: Event, supabase: SupabaseClient, currentUserID: String?, baseURL: URL) {
        _store = State(initialValue: QRCodeStore(event: event,
                                                 supabase: supabase,
                                                 currentUserID: currentUserID,
                                                 baseURL: baseURL))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    qrSection
                    if let url = store.shareURL { linkLabel(url) }
                    actions
                    privacyNote
                    if store.isOwner && store.phase == .ready {
                        ownerControls
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(Brand.canvas)
            .navigationTitle("Share Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Regenerate guest link?",
                                isPresented: $showingRegenerateConfirm,
                                titleVisibility: .visible) {
                Button("Regenerate Link", role: .destructive) {
                    Task { await store.regenerateLink() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A new link and QR code will be created. Every code or link you've already shared will stop working.")
            }
            .confirmationDialog("Disable guest lookup?",
                                isPresented: $showingDisableConfirm,
                                titleVisibility: .visible) {
                Button("Disable Lookup", role: .destructive) {
                    Task { await store.disableLink() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Guests will no longer be able to look up their seat. Every code or link you've already shared will stop working. You can create a new link later.")
            }
        }
        .task { await store.prepare() }
        #if canImport(UIKit)
        .sheet(item: $store.shareItem) { payload in
            ShareSheet(items: [
                QRCodeShareItem(fileURL: payload.fileURL,
                                title: "Find your table at \(payload.eventName)"),
                payload.link
            ])
        }
        #endif
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 6) {
            Text("Scan to find your seat")
                .font(.system(size: 15))
                .foregroundStyle(Brand.textSecondary)
            Text(store.eventName)
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.2)
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    @ViewBuilder private var qrSection: some View {
        switch store.phase {
        case .loading, .ready:
            whiteQRCard
        case .missingTokenOwnerOnly:
            notice(icon: "qrcode",
                   title: "No guest link yet",
                   message: "This event does not have a guest lookup link yet. Only the event owner can create one.")
        case .disabled:
            VStack(spacing: 14) {
                notice(icon: "lock.fill",
                       title: "Guest lookup is off",
                       message: "Previously shared codes and links no longer work. Create a new link whenever you're ready to share again.")
                if store.isOwner {
                    Button("Create New Link") { Task { await store.regenerateLink() } }
                        .buttonStyle(.primaryBrand)
                }
            }
        case .failed(let message):
            VStack(spacing: 14) {
                notice(icon: "exclamationmark.triangle.fill",
                       title: "Couldn’t create the QR code",
                       message: message)
                Button("Retry") { Task { await store.retry() } }
                    .buttonStyle(.secondaryOutline)
            }
        }
    }

    /// Always-white card so the exported-style code reads correctly in light and
    /// dark mode. While generating, a ProgressView fills the same frame so the
    /// user never sees an empty white square that looks like a finished code.
    private var whiteQRCard: some View {
        ZStack {
            #if canImport(UIKit)
            if store.phase == .ready, let image = store.qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("QR code that opens the guest seating page")
            } else {
                ProgressView()
                    .tint(Brand.plum)
                    .accessibilityLabel("Generating QR code")
            }
            #else
            ProgressView().tint(Brand.plum)
            #endif
        }
        .frame(width: 248, height: 248)
        .padding(20)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06))
        )
        .shadow(color: Color.black.opacity(0.10), radius: 18, y: 10)
    }

    private func linkLabel(_ url: URL) -> some View {
        Text(url.absoluteString)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Brand.textSecondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .accessibilityLabel("Public link: \(url.absoluteString)")
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button { Task { await store.share() } } label: {
                Label("Share QR Code", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.primaryBrand)
            .disabled(store.phase != .ready)

            Button { store.copyLink() } label: {
                Label("Copy Link", systemImage: "link")
            }
            .buttonStyle(.secondaryOutline)
            .disabled(store.shareURL == nil)

            if let url = store.shareURL {
                Link(destination: url) {
                    Text("Open Guest Page")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.accent)
                }
                .padding(.top, 2)
            }

            if let feedback = store.copyFeedback {
                Text(feedback)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.success)
                    .transition(.opacity)
                    .accessibilityHidden(true) // already announced via VoiceOver
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.copyFeedback)
    }

    /// Owner-only link management: rotate the token if a link leaks, or turn the
    /// public lookup off entirely from the phone (F15).
    private var ownerControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MANAGE LINK")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Brand.slate400)

            Button { showingRegenerateConfirm = true } label: {
                managementRow(icon: "arrow.triangle.2.circlepath",
                              title: "Regenerate link",
                              subtitle: "Replace this link if it's been over-shared.")
            }
            .buttonStyle(.plain)

            Button { showingDisableConfirm = true } label: {
                managementRow(icon: "lock.slash",
                              title: "Disable guest lookup",
                              subtitle: "Turn off seat lookup for this event.",
                              destructive: true)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .brandCard()
    }

    private func managementRow(icon: String, title: String, subtitle: String,
                               destructive: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(destructive ? Brand.danger : Brand.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(destructive ? Brand.danger : Brand.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var privacyNote: some View {
        Text("Anyone with this code or link can search for a guest’s seating assignment. Share it only with your event attendees.")
            .font(.system(size: 12))
            .foregroundStyle(Brand.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }

    private func notice(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Brand.accent)
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .brandCard()
    }
}
