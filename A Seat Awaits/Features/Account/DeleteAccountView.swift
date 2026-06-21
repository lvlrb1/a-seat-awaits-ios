//
//  DeleteAccountView.swift
//  A Seat Awaits
//
//  Permanent account deletion. Deleting `auth.users` and canceling the Stripe
//  subscription are privileged operations that cannot run safely with a user JWT
//  and the app ships no service-role key or Edge Function for them, so the final
//  step is completed on the secure account page. This screen makes the
//  consequences explicit and requires a typed confirmation before opening it.
//

import SwiftUI

struct DeleteAccountView: View {
    @Bindable var store: AccountStore
    @Environment(\.openURL) private var openURL

    @State private var confirmationText = ""
    private let requiredPhrase = "DELETE"
    @FocusState private var focused: Bool

    private var canProceed: Bool {
        confirmationText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == requiredPhrase
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                warningCard
                consequencesCard
                confirmCard
            }
            .padding(18)
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
        "Your subscription (canceled as part of deletion)",
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

            Text("For your security, account deletion is completed on our website. We'll open your account page where you can permanently delete it.")
                .font(.system(size: 13))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(role: .destructive) {
                openURL(AccountLinks.accountSettings)
            } label: {
                Text("Continue to Delete Account")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(canProceed ? Brand.danger : Brand.slate300,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canProceed)
            .accessibilityHint("Opens your account page in the browser to complete deletion")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }
}
