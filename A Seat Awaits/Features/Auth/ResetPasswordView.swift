//
//  ResetPasswordView.swift
//  A Seat Awaits
//
//  Presented after a password-recovery universal link establishes a recovery
//  session (see DeepLinkRouter + AppState.handleDeepLink). Lets the user choose a
//  new password, applied via GoTrue `PUT /user`. Recovery tokens are never shown
//  or logged.
//

import SwiftUI

struct ResetPasswordView: View {
    let supabase: SupabaseClient
    var onDone: () -> Void

    @State private var password = ""
    @State private var confirm = ""
    @State private var showPassword = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var didReset = false
    @FocusState private var focused: Field?

    private enum Field { case password, confirm }

    private var canSave: Bool {
        password.count >= 6 && password == confirm && !isSaving
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if didReset {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(Brand.successText)
                            .padding(.top, 40)
                        Text("Password updated")
                            .font(.system(size: 26, weight: .bold))
                            .tracking(-0.5)
                            .foregroundStyle(Brand.textPrimary)
                            .padding(.top, 20)
                        Text("Your password has been changed. You're all set.")
                            .font(.system(size: 15))
                            .foregroundStyle(Brand.textSecondary)
                            .padding(.top, 8)
                        Button("Continue") { onDone() }
                            .buttonStyle(.primaryBrand)
                            .padding(.top, 28)
                    } else {
                        Text("Set a new password")
                            .font(.system(size: 26, weight: .bold))
                            .tracking(-0.5)
                            .foregroundStyle(Brand.textPrimary)
                            .padding(.top, 40)
                        Text("Choose a new password for your account. Use at least 6 characters.")
                            .font(.system(size: 15))
                            .lineSpacing(3)
                            .foregroundStyle(Brand.textSecondary)
                            .padding(.top, 8)

                        VStack(alignment: .leading, spacing: 16) {
                            LabeledField(title: "New password", isFocused: focused == .password) {
                                Group {
                                    if showPassword {
                                        TextField("••••••••••", text: $password)
                                    } else {
                                        SecureField("••••••••••", text: $password)
                                    }
                                }
                                .textContentType(.newPassword)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .focused($focused, equals: .password)
                                .submitLabel(.next)
                                .onSubmit { focused = .confirm }
                            }

                            LabeledField(title: "Confirm password", isFocused: focused == .confirm) {
                                Group {
                                    if showPassword {
                                        TextField("••••••••••", text: $confirm)
                                    } else {
                                        SecureField("••••••••••", text: $confirm)
                                    }
                                }
                                .textContentType(.newPassword)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .focused($focused, equals: .confirm)
                                .submitLabel(.go)
                                .onSubmit { Task { await save() } }
                            }

                            Toggle("Show password", isOn: $showPassword)
                                .font(.system(size: 14))
                                .tint(Brand.plum)
                        }
                        .padding(.top, 24)

                        if !confirm.isEmpty && password != confirm {
                            Label("Passwords don't match.", systemImage: "exclamationmark.circle.fill")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Brand.danger)
                                .padding(.top, 12)
                        }
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Brand.danger)
                                .padding(.top, 12)
                        }

                        Button {
                            focused = nil
                            Task { await save() }
                        } label: {
                            HStack(spacing: 8) {
                                if isSaving { ProgressView().tint(.white) }
                                Text("Update password")
                            }
                        }
                        .buttonStyle(.primaryBrand)
                        .disabled(!canSave)
                        .padding(.top, 26)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            .background(Brand.canvas)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            _ = try await supabase.updateAuthUser(password: password)
            didReset = true
        } catch {
            errorMessage = (error as? SupabaseError)?.errorDescription ?? error.localizedDescription
        }
    }
}
