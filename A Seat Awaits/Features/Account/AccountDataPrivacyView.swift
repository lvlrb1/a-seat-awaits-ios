//
//  AccountDataPrivacyView.swift
//  A Seat Awaits
//
//  Data & Privacy: download a local, RLS-scoped export of your data, read the
//  legal documents, and reach account deletion. The export is assembled by
//  `AccountStore` from authenticated Supabase queries and shared via the system
//  share sheet — it never includes tokens, credentials or Stripe secrets.
//
//  Analytics/crash-reporting preferences are intentionally omitted: the app ships
//  no analytics or crash-reporting SDK, so a toggle here would control nothing
//  and mislead the user.
//

import SwiftUI

struct AccountDataPrivacyView: View {
    @Bindable var store: AccountStore
    @Environment(\.openURL) private var openURL

    @State private var exportError: String?
    @State private var partialNotice: String?
    @State private var exported: ExportedDocument?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                exportCard
                legalCard
                deleteCard
            }
            .padding(18)
        }
        .background(Brand.canvas.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .navigationTitle("Data & Privacy")
        .navigationBarTitleDisplayMode(.inline)
        #if canImport(UIKit)
        .sheet(item: $exported) { doc in
            ShareSheet(items: [doc.url])
        }
        #endif
    }

    // MARK: - Export

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Brand.accent.opacity(0.12))
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Brand.accent)
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Download My Data")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    Text("A JSON file with your profile, subscription, events, guests, floor plans and preferences.")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let partialNotice {
                FeedbackBanner(kind: .info, message: partialNotice)
            }
            if let exportError {
                FeedbackBanner(kind: .error, message: exportError)
            }

            Button {
                Task { await exportData() }
            } label: {
                if store.isExporting {
                    HStack(spacing: 8) { ProgressView().tint(.white); Text("Preparing…") }
                } else {
                    Text("Export My Data")
                }
            }
            .buttonStyle(.primaryBrand)
            .disabled(store.isExporting)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    private func exportData() async {
        exportError = nil
        partialNotice = nil
        switch await store.exportPersonalData() {
        case .success(let result):
            if result.isPartial {
                partialNotice = "Some sections couldn't be included (\(result.partialFailures.joined(separator: ", "))). The export is partial."
            }
            exported = ExportedDocument(url: result.url)
        case .failure(let error):
            exportError = AccountStore.message(for: error)
        }
    }

    // MARK: - Legal

    private var legalCard: some View {
        AccountCardGroup {
            AccountButtonRow(icon: "hand.raised.circle", title: "Privacy Policy") {
                openURL(AccountLinks.privacyPolicy)
            }
            AccountRowDivider()
            AccountButtonRow(icon: "doc.text", title: "Terms of Service") {
                openURL(AccountLinks.termsOfService)
            }
        }
    }

    // MARK: - Delete

    private var deleteCard: some View {
        AccountCardGroup {
            NavigationLink {
                DeleteAccountView(store: store)
            } label: {
                AccountRowLabel(icon: "trash",
                                title: "Delete Account",
                                subtitle: "Permanently delete your account and data.",
                                tint: Brand.danger)
            }
            .buttonStyle(.plain)
        }
    }
}
