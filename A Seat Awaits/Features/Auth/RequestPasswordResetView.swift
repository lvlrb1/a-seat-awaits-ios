//
//  RequestPasswordResetView.swift
//  A Seat Awaits
//
//  Presented from the sign-in form's "Forgot?" affordance. Sends a password-reset
//  request through the rate-limited edge function and always shows the SAME
//  generic confirmation — it never reveals whether an account exists. Cooldown
//  lives on `AuthViewModel` so it survives sheet recreation.
//

import SwiftUI

struct RequestPasswordResetView: View {
    @Bindable var model: AuthViewModel
    var onDismiss: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if model.resetSent {
                    Image(systemName: "envelope.badge.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(Brand.accent)
                        .padding(.bottom, 20)
                    Text("Check your inbox")
                        .font(.system(size: 24, weight: .bold))
                        .tracking(-0.4)
                        .foregroundStyle(Brand.textPrimary)
                    // Generic copy — no account-existence signal.
                    Text("If an account exists for that email, we sent password-reset instructions. It can take a minute to arrive — check spam if you don't see it.")
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .foregroundStyle(Brand.textSecondary)
                        .padding(.top, 10)

                    Button("Done") { onDismiss() }
                        .buttonStyle(.primaryBrand)
                        .padding(.top, 28)
                } else {
                    Text("Reset your password")
                        .font(.system(size: 24, weight: .bold))
                        .tracking(-0.4)
                        .foregroundStyle(Brand.textPrimary)
                    Text("Enter the email for your account and we'll send a link to set a new password.")
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .foregroundStyle(Brand.textSecondary)
                        .padding(.top, 10)

                    LabeledField(title: "Email", isFocused: focused) {
                        TextField("", text: $model.resetEmail, prompt: Text("Email").foregroundStyle(Brand.slate400))
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .submitLabel(.send)
                            .onSubmit {
                                focused = false
                                Task { await model.sendPasswordReset() }
                            }
                    }
                    .padding(.top, 24)

                    if let err = model.resetError {
                        Label(err, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Brand.danger)
                            .padding(.top, 10)
                    }

                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let remaining = model.resetCooldownRemaining
                        Button {
                            focused = false
                            Task { await model.sendPasswordReset() }
                        } label: {
                            HStack(spacing: 8) {
                                if model.isSendingReset { ProgressView().tint(.white) }
                                Text(remaining > 0 ? "Resend in \(remaining)s" : "Send reset link")
                            }
                        }
                        .buttonStyle(.primaryBrand)
                        .disabled(model.isSendingReset || remaining > 0)
                    }
                    .padding(.top, 24)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .background(Brand.canvas)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { onDismiss() }
                        .foregroundStyle(Brand.accent)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
