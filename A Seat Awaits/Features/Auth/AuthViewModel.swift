//
//  AuthViewModel.swift
//  A Seat Awaits
//

import Foundation
import Observation
import AuthenticationServices
import CryptoKit

@MainActor
@Observable
final class AuthViewModel {
    enum Mode { case signUp, signIn }

    var mode: Mode = .signUp
    var fullName = ""
    var email = ""
    var password = ""

    var isSubmitting = false
    var errorMessage: String?
    var infoMessage: String?

    // Password-reset sheet state (separate from the sign-in form's banners).
    var resetEmail = ""
    var isSendingReset = false
    var resetError: String?
    var resetSent = false
    /// When the next reset request is allowed (server-provided cooldown). Held on
    /// the view model so it survives transient view recreation.
    var resetCooldownEndsAt: Date?

    // Email-verification state (after a sign-up that needs confirmation).
    var needsEmailVerification = false
    var pendingVerificationEmail: String?
    var isResendingVerification = false
    var verificationInfo: String?
    var verificationError: String?
    /// When the next verification resend is allowed (server-provided cooldown).
    var verificationCooldownEndsAt: Date?

    private let supabase: SupabaseClient
    private let emailService: EmailService
    private let onAuthenticated: (AuthUser) -> Void

    init(supabase: SupabaseClient, onAuthenticated: @escaping (AuthUser) -> Void) {
        self.supabase = supabase
        self.emailService = EmailService(invoker: supabase)
        self.onAuthenticated = onAuthenticated
    }

    var canSubmit: Bool {
        let emailOK = email.contains("@") && email.contains(".")
        let passOK = password.count >= 6
        let nameOK = mode == .signIn || !fullName.trimmingCharacters(in: .whitespaces).isEmpty
        return emailOK && passOK && nameOK && !isSubmitting
    }

    func toggleMode() {
        mode = (mode == .signUp) ? .signIn : .signUp
        errorMessage = nil
        infoMessage = nil
    }

    func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        infoMessage = nil
        defer { isSubmitting = false }
        do {
            switch mode {
            case .signUp:
                let result = try await supabase.signUp(
                    email: email.trimmingCharacters(in: .whitespaces),
                    password: password,
                    fullName: fullName.trimmingCharacters(in: .whitespaces)
                )
                switch result {
                case .signedIn(let user):
                    onAuthenticated(user)
                case .confirmationRequired:
                    // Drive the deliberate (edge + Resend) verification path,
                    // not GoTrue's default email. The view switches to the
                    // verification stage on `needsEmailVerification`.
                    await beginVerification(email: email.trimmingCharacters(in: .whitespaces))
                }
            case .signIn:
                let user = try await supabase.signIn(
                    email: email.trimmingCharacters(in: .whitespaces),
                    password: password
                )
                onAuthenticated(user)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Sign in with Apple

    /// A fresh raw nonce per attempt; Apple receives its SHA256, Supabase the raw value.
    private var currentNonce: String?

    /// Configures the Apple authorization request with scopes and a hashed nonce.
    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let error):
            // User cancellation shouldn't read as an error.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            errorMessage = error.localizedDescription
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8),
                  let nonce = currentNonce else {
                errorMessage = "Apple sign-in did not return a valid token."
                return
            }
            let name = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }.joined(separator: " ")
            isSubmitting = true
            defer { isSubmitting = false }
            do {
                let user = try await supabase.signInWithApple(idToken: idToken, nonce: nonce,
                                                              fullName: name.isEmpty ? nil : name)
                onAuthenticated(user)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if random < charset.count * Int(UInt8.max / UInt8(charset.count)) {
                result.append(charset[Int(random) % charset.count])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Prepares the reset sheet: pre-fills the email already typed on the form
    /// and clears any prior result so each open starts fresh.
    func prepareReset() {
        resetEmail = email.trimmingCharacters(in: .whitespaces)
        resetError = nil
        resetSent = false
    }

    /// Requests a password-reset email via the rate-limited edge function. The
    /// response is intentionally generic — we always show the same "if an account
    /// exists…" confirmation and never reveal whether the address has an account.
    func sendPasswordReset() async {
        let trimmed = resetEmail.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("@"), trimmed.contains(".") else {
            resetError = "Enter a valid email address."
            return
        }
        guard resetCooldownRemaining == 0 else { return }
        resetError = nil
        isSendingReset = true
        defer { isSendingReset = false }
        do {
            let response = try await emailService.sendPasswordReset(to: trimmed)
            resetSent = true
            startCooldown(\.resetCooldownEndsAt, seconds: response.retryAfterSeconds ?? 60)
        } catch let error as EdgeFunctionError {
            // A 429 is still a generic "sent" outcome — honor the cooldown.
            if let retry = error.retryAfterSeconds {
                resetSent = true
                startCooldown(\.resetCooldownEndsAt, seconds: retry)
            } else {
                resetError = error.localizedDescription
            }
        } catch {
            resetError = friendly(error)
        }
    }

    // MARK: - Email verification

    /// Begins the verification flow after a confirmation-required sign-up: records
    /// the pending address, switches the UI to the verification stage, and sends
    /// the first verification email.
    func beginVerification(email: String) async {
        pendingVerificationEmail = email
        needsEmailVerification = true
        verificationError = nil
        verificationInfo = nil
        await resendVerification(initial: true)
    }

    /// Sends (or resends) the verification email, honoring the server cooldown.
    func resendVerification(initial: Bool = false) async {
        guard let email = pendingVerificationEmail else { return }
        guard initial || verificationCooldownRemaining == 0 else { return }
        verificationError = nil
        isResendingVerification = true
        defer { isResendingVerification = false }
        do {
            let response = try await emailService.sendVerificationEmail(to: email)
            verificationInfo = "We sent a verification link to \(email). Check your inbox — it may take a minute."
            startCooldown(\.verificationCooldownEndsAt, seconds: response.retryAfterSeconds ?? 60)
        } catch let error as EdgeFunctionError {
            if let retry = error.retryAfterSeconds {
                verificationInfo = "We sent a verification link to \(email). Check your inbox — it may take a minute."
                startCooldown(\.verificationCooldownEndsAt, seconds: retry)
            } else {
                verificationError = error.localizedDescription
            }
        } catch {
            verificationError = friendly(error)
        }
    }

    /// Seconds remaining before another verification resend is allowed.
    var verificationCooldownRemaining: Int { remaining(verificationCooldownEndsAt) }
    /// Seconds remaining before another reset request is allowed.
    var resetCooldownRemaining: Int { remaining(resetCooldownEndsAt) }

    // MARK: - Helpers

    private func startCooldown(_ keyPath: ReferenceWritableKeyPath<AuthViewModel, Date?>, seconds: Int) {
        self[keyPath: keyPath] = Date().addingTimeInterval(TimeInterval(max(1, seconds)))
    }

    private func remaining(_ endsAt: Date?) -> Int {
        guard let endsAt else { return 0 }
        return max(0, Int(ceil(endsAt.timeIntervalSinceNow)))
    }

    /// Maps offline/transport errors to friendly copy; everything else uses its
    /// own localized description.
    private func friendly(_ error: Error) -> String {
        if let supa = error as? SupabaseError { return supa.errorDescription ?? "Something went wrong." }
        return error.localizedDescription
    }
}
