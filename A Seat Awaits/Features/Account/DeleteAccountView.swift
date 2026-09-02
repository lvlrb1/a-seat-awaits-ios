//
//  DeleteAccountView.swift
//  A Seat Awaits
//
//  Permanent account deletion. The app invokes an authenticated Edge Function;
//  the service-role credential stays server-side and the user identity is
//  derived from the verified JWT. This screen makes the consequences explicit,
//  requires a typed confirmation, and never redirects to a website.
//

import SwiftUI

struct DeleteAccountView: View {
    @Bindable var store: AccountStore

    @State private var confirmationText = ""
    @State private var errorMessage: String?
    @State private var showingFinalConfirmation = false
    @FocusState private var focused: Bool

    private var canProceed: Bool {
        AccountDeletion.isConfirmed(confirmationText) && !store.isDeletingAccount
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                warningCard
                consequencesCard
                confirmCard
            }
            .padding(18)
            .readableWidth(Layout.contentWidth)
        }
        .background(Brand.canvas.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .navigationTitle("Delete Account")
        .navigationBarTitleDisplayMode(.inline)
        .onTapGesture { focused = false }
    }

    private var warningCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Brand.danger)
            Text("This can't be undone")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
            Text("Deleting your account permanently removes your data. Consider exporting it first from Data & Privacy.")
                .font(.system(size: 14))
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .brandCard()
    }

    private var consequencesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What gets deleted")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
            ForEach(consequences, id: \.self) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Brand.danger)
                        .frame(width: 18)
                    Text(item)
                        .font(.system(size: 14))
                        .foregroundStyle(Brand.textSecondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    private let consequences = [
        "Your profile and sign-in",
        "All events you own, with their guests, tables and floor plans",
        "Saved floor-plan templates and import preferences",
        "Your subscription record and all Event Passes",
    ]

    private var confirmCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Type \(requiredPhrase) to confirm")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Brand.textPrimary)

            LabeledField(title: "Confirmation", isFocused: focused) {
                TextField(requiredPhrase, text: $confirmationText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focused)
            }

            Text("Deletion is completed securely in the app. You will be signed out as soon as your account and data are removed.")
                .font(.system(size: 13))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if hasPotentialRecurringBilling {
                FeedbackBanner(
                    kind: .info,
                    message: "Deleting your account does not cancel recurring billing managed by Apple or Stripe. Cancel with your billing provider first to avoid future charges.")
            }

            if let errorMessage {
                FeedbackBanner(kind: .error, message: errorMessage)
            }

            Button(role: .destructive) {
                focused = false
                showingFinalConfirmation = true
            } label: {
                HStack(spacing: 8) {
                    if store.isDeletingAccount {
                        ProgressView().tint(.white)
                    }
                    Text(store.isDeletingAccount ? "Deleting Account…" : "Delete My Account")
                        .font(.system(size: 17, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(canProceed ? Brand.danger : Brand.slate300,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canProceed)
            .accessibilityHint("Permanently deletes your account and data")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
        .alert("Permanently delete your account?", isPresented: $showingFinalConfirmation) {
            Button("Delete Account", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Your account, owned events, guest lists, floor plans, and saved preferences will be permanently removed.")
        }
    }

    private var requiredPhrase: String { AccountDeletion.requiredPhrase }

    private var hasPotentialRecurringBilling: Bool {
        guard let snapshot = store.snapshot,
              snapshot.billingProvider != BillingProvider.none else { return false }
        switch snapshot.policy.status {
        case .canceled, .incompleteExpired:
            return false
        default:
            return true
        }
    }

    private func deleteAccount() async {
        errorMessage = nil
        switch await store.deleteAccount(confirmation: confirmationText) {
        case .success:
            break // RootView moves to onboarding when AppState becomes signed out.
        case .failure(let error):
            errorMessage = AccountStore.message(for: error)
        }
    }
}
