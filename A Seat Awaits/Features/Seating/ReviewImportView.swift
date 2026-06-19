//
//  ReviewImportView.swift
//  A Seat Awaits
//
//  Step 2 of the on-device import flow: shows the cleaned-up, structured guests
//  parsed from pasted text, lets the user eyeball them (amber rows flag
//  unresolved plus-one / partner hints), then writes each one via
//  `store.addGuest(...)` and dismisses the whole flow.
//

import SwiftUI

struct ReviewImportView: View {
    let parsed: [ParsedGuest]
    @Bindable var store: SeatingStore
    /// Called after a successful import so the presenting sheet can dismiss.
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            Brand.canvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 10) {
                    legend
                        .padding(.top, 12)
                        .padding(.bottom, 2)

                    ForEach(parsed) { guest in
                        ParsedGuestRow(guest: guest)
                    }

                    Color.clear.frame(height: 96)
                }
                .padding(.horizontal, 16)
            }

            confirmFooter
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                }
                .tint(Brand.accent)
            }
            ToolbarItem(placement: .principal) {
                Text("Review import")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
            }
        }
        .toolbarBackground(Brand.card, for: .navigationBar)
        .safeAreaInset(edge: .top) { summaryBanner }
        .alert("Import failed",
               isPresented: Binding(get: { importError != nil },
                                    set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .interactiveDismissDisabled(isImporting)
    }

    // MARK: - Summary banner

    private var summaryBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Brand.successText)
            Text(summaryText)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Brand.successText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(Brand.successFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.successBorder, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Brand.card)
    }

    private var summaryText: String {
        let n = parsed.count
        let h = parsed.householdCount
        let d = parsed.dietaryCount
        return "\(n) \(n == 1 ? "guest" : "guests") parsed · \(h) \(h == 1 ? "household" : "households") · \(d) dietary \(d == 1 ? "note" : "notes")"
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 8) {
            TagPill.neutral("Name")
            TagPill.household("Household")
            TagPill.dietary("Dietary")
            Spacer(minLength: 0)
        }
    }

    // MARK: - Confirm footer

    private var confirmFooter: some View {
        Button(action: { Task { await importAll() } }) {
            if isImporting {
                ProgressView().tint(.white)
            } else {
                Text("Confirm & import \(parsed.count) \(parsed.count == 1 ? "guest" : "guests")")
            }
        }
        .buttonStyle(PrimaryButtonStyle(isLoading: isImporting))
        .disabled(isImporting || parsed.isEmpty)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().fill(Brand.separator).frame(height: 1), alignment: .top)
    }

    // MARK: - Import

    private func importAll() async {
        isImporting = true
        importError = nil
        defer { isImporting = false }
        do {
            for guest in parsed {
                try await store.addGuest(
                    name: guest.name,
                    groupId: nil,
                    groupName: guest.group,
                    notes: guest.plusOneHint,
                    dietary: guest.dietary
                )
            }
            onFinish()
        } catch {
            importError = error.localizedDescription
        }
    }
}

// MARK: - Parsed guest row

private struct ParsedGuestRow: View {
    let guest: ParsedGuest

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(guest.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    if let hint = plusOneShort {
                        Text(hint)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Brand.textTertiary)
                    }
                }

                if hasBadges {
                    HStack(spacing: 6) {
                        if let group = guest.group {
                            TagPill.household(group)
                        }
                        if let dietary = guest.dietary {
                            TagPill.dietary(dietary)
                        }
                        if guest.needsReview {
                            TagPill(text: confirmText,
                                    fg: Brand.warningText,
                                    bg: Brand.warningFill)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            if guest.needsReview {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Brand.slate400)
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Brand.success)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background {
            if guest.needsReview {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Brand.inviteBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Brand.warningBorder, lineWidth: 1)
                    )
            }
        }
        .modifier(NonReviewCard(needsReview: guest.needsReview))
    }

    private var hasBadges: Bool {
        guest.group != nil || guest.dietary != nil || guest.needsReview
    }

    /// Short trailing name annotation, e.g. "+1" / "+ partner".
    private var plusOneShort: String? {
        guard let hint = guest.plusOneHint?.lowercased() else { return nil }
        if hint.contains("partner") { return "+ partner" }
        if hint.contains("guest") { return "+ guest" }
        return "+1"
    }

    private var confirmText: String {
        guard let hint = guest.plusOneHint?.lowercased() else { return "Confirm…" }
        if hint.contains("partner") { return "Confirm partner name" }
        if hint.contains("guest") { return "Confirm guest name" }
        return "Confirm +1 name"
    }
}

/// Applies the standard `.brandCard` only to non-review rows (review rows carry
/// their own amber styling).
private struct NonReviewCard: ViewModifier {
    let needsReview: Bool
    func body(content: Content) -> some View {
        if needsReview {
            content
        } else {
            content.brandCard(radius: 14)
        }
    }
}
