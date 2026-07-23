//
//  AccountSecurityView.swift
//  A Seat Awaits
//
//  Native security management. Password accounts can change their password
//  (reauthenticated against the current one), request a reset email, and sign
//  out everywhere. Apple accounts see provider-appropriate guidance instead of a
//  nonexistent password form. All actions run through Supabase Auth; passwords
//  are never logged or persisted and the fields are marked privacy-sensitive.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct AccountSecurityView: View {
    @Bindable var store: AccountStore
    @Environment(AppState.self) private var appState

    @State private var current = ""
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var feedback: Feedback?
    @State private var resetFeedback: Feedback?
    @State private var showingSignOutAllConfirm = false
    @FocusState private var focus: Field?

    private enum Field { case current, new, confirm }
    private struct Feedback: Equatable { let kind: FeedbackBanner.Kind; let message: String }

    private var user: AuthUser? { store.snapshot?.authUser }
    private var isPasswordAccount: Bool { user?.isPasswordAccount ?? true }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if isPasswordAccount {
                    passwordCard
                    forgotPasswordCard
                } else {
                    providerCard
                }
                sessionsCard
            }
            .padding(18)
            .readableWidth(Layout.contentWidth)
        }
        .background(Brand.canvas.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
        .onTapGesture { focus = nil }
        .alert("Sign out of all devices?", isPresented: $showingSignOutAllConfirm) {
            Button("Sign Out Everywhere", role: .destructive) {
                Task { await appState.signOutEverywhere() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs you out on every device, including this one.")
        }
    }

    // MARK: - Change password

    private var canSubmit: Bool {
        !store.isChangingPassword && !current.isEmpty && !newPassword.isEmpty && !confirm.isEmpty
    }

    private var passwordCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change password")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)

            secureField("Current password", text: $current, field: .current, content: .password)
            secureField("New password", text: $newPassword, field: .new, content: .newPassword)
            secureField("Confirm new password", text: $confirm, field: .confirm, content: .newPassword)

            Text("Use at least \(AccountValidation.minPasswordLength) characters.")
                .font(.system(size: 13))
                .foregroundStyle(Brand.textSecondary)

            if let feedback {
                FeedbackBanner(kind: feedback.kind, message: feedback.message)
            }

            Button {
                Task { await changePassword() }
            } label: {
                if store.isChangingPassword {
                    HStack(spacing: 8) { ProgressView().tint(.white); Text("Updating…") }
                } else {
                    Text("Update Password")
                }
            }
            .buttonStyle(.primaryBrand)
            .disabled(!canSubmit)
            .opacity(canSubmit ? 1 : 0.5)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    private func secureField(_ title: String, text: Binding<String>, field: Field,
                             content: UITextContentType) -> some View {
        LabeledField(title: title, isFocused: focus == field) {
            SecureField(title, text: text)
                .textContentType(content)
                .focused($focus, equals: field)
                .privacySensitive()
        }
    }

    private func changePassword() async {
        focus = nil
        feedback = nil
        let result = await store.changePassword(current: current, new: newPassword, confirm: confirm)
        switch result {
        case .success:
            // Never persist or log passwords; clear the fields on completion.
            current = ""; newPassword = ""; confirm = ""
            feedback = Feedback(kind: .success, message: "Your password has been updated.")
        case .failure(let error):
            feedback = Feedback(kind: .error, message: AccountStore.message(for: error))
        }
    }

    // MARK: - Forgot password

    private var forgotPasswordCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Forgot your password?")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
            Text("We'll email a reset link to \(user?.email ?? "your address").")
                .font(.system(size: 13))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let resetFeedback {
                FeedbackBanner(kind: resetFeedback.kind, message: resetFeedback.message)
            }

            Button("Send Reset Email") {
                Task { await sendReset() }
            }
            .buttonStyle(.secondaryOutline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    private func sendReset() async {
        resetFeedback = nil
        switch await store.sendPasswordReset() {
        case .success:
            resetFeedback = Feedback(kind: .success, message: "Reset email sent. Check your inbox.")
        case .failure(let error):
            resetFeedback = Feedback(kind: .error, message: AccountStore.message(for: error))
        }
    }

    // MARK: - Apple / provider accounts

    private var providerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: user?.primaryProvider == "apple" ? "applelogo" : "person.badge.key")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                Text("Signed in with \(user?.providerLabel ?? "your provider")")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
            }
            Text("Your sign-in and password are managed by \(user?.providerLabel ?? "your provider"), so there's no separate password to change here. To manage sign-in or recover access, use your \(user?.providerLabel ?? "provider") account settings.")
                .font(.system(size: 14))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    // MARK: - Sessions

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sessions")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
            Text("Signs you out on every device where you're logged in.")
                .font(.system(size: 13))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(role: .destructive) {
                showingSignOutAllConfirm = true
            } label: {
                Text("Sign Out of All Devices")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.danger)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Brand.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }
}
