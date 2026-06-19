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

    private let supabase: SupabaseClient
    private let onAuthenticated: (AuthUser) -> Void

    init(supabase: SupabaseClient, onAuthenticated: @escaping (AuthUser) -> Void) {
        self.supabase = supabase
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
                    infoMessage = "Check your inbox to confirm your email, then sign in."
                    mode = .signIn
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

    func sendPasswordReset() async {
        guard email.contains("@") else {
            errorMessage = "Enter your email first to reset your password."
            return
        }
        do {
            try await supabase.sendPasswordReset(email: email.trimmingCharacters(in: .whitespaces))
            infoMessage = "Password reset email sent."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
