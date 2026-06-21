//
//  EmailVerificationView.swift
//  A Seat Awaits
//
//  Shown after a confirmation-required sign-up. Displays the address awaiting
//  verification, a cooldown-aware "Resend verification email" button, and a path
//  to sign in once verified. Cooldown state lives on `AuthViewModel`, so it
//  survives transient view recreation. Feedback is generic — it never reveals
//  whether an account exists.
//

import SwiftUI

struct EmailVerificationView: View {
    @Bindable var model: AuthViewModel
    /// Return to the sign-in form once the user reports they've verified.
    var onContinueToSignIn: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "envelope.badge.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                    .padding(.top, 48)

                Text("Verify your email")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Brand.textPrimary)
                    .padding(.top, 24)

                Text("We sent a verification link to")
                    .font(.system(size: 16))
                    .foregroundStyle(Brand.textSecondary)
                    .padding(.top, 8)

                Text(model.pendingVerificationEmail ?? "your email")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
                    .padding(.top, 2)

                Text("Open it to confirm your account. The link expires after 24 hours. If it isn't in your inbox, check your spam folder.")
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(Brand.textSecondary)
                    .padding(.top, 16)

                if let info = model.verificationInfo {
                    Label(info, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Brand.successText)
                        .padding(.top, 16)
                }
                if let error = model.verificationError {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Brand.danger)
                        .padding(.top, 16)
                }

                // Cooldown-aware resend. TimelineView ticks the countdown each second.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let remaining = model.verificationCooldownRemaining
                    Button {
                        Task { await model.resendVerification() }
                    } label: {
                        HStack(spacing: 8) {
                            if model.isResendingVerification { ProgressView().tint(.white) }
                            Text(remaining > 0 ? "Resend in \(remaining)s" : "Resend verification email")
                        }
                    }
                    .buttonStyle(.primaryBrand)
                    .disabled(remaining > 0 || model.isResendingVerification)
                }
                .padding(.top, 28)

                Button("I've verified — Sign in") {
                    onContinueToSignIn()
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Brand.accent)
                .frame(maxWidth: .infinity)
                .padding(.top, 20)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .background(Brand.canvas)
    }
}
