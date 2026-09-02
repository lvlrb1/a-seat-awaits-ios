//
//  NetAuthTests.swift
//  A Seat AwaitsTests
//
//  Unit tests for the pure networking/auth logic added in the robustness pass:
//  GoTrue auth error mapping, cancellation detection and transport mapping,
//  deep-link parsing, and accent-tolerant guest-name matching. All off-network.
//

import Foundation
import Testing
@testable import A_Seat_Awaits

// MARK: - Auth error mapping

@Suite("GoTrue auth error mapping")
struct NetAuthErrorMappingTests {

    @Test("Invalid credentials (message form) get actionable guidance")
    func invalidCredentialsMessage() {
        let error = SupabaseError.http(status: 400, message: "Invalid login credentials")
        let message = FriendlyError.message(for: error)
        #expect(message == "That email or password doesn't match. Try again, or reset your password.")
    }

    @Test("Invalid credentials (error_code form) map the same way")
    func invalidCredentialsCode() {
        #expect(FriendlyError.authMessage(status: 400, message: "invalid_credentials")?.contains("doesn't match") == true)
    }

    @Test("User already registered maps to sign-in guidance on 422 and 400")
    func alreadyRegistered() {
        for status in [400, 422] {
            let message = FriendlyError.message(for: SupabaseError.http(status: status, message: "User already registered"))
            #expect(message == "An account with this email already exists. Sign in instead.")
        }
        #expect(FriendlyError.authMessage(status: 422, message: "user_already_exists") != nil)
    }

    @Test("Unconfirmed email asks the user to verify first")
    func emailNotConfirmed() {
        let message = FriendlyError.message(for: SupabaseError.http(status: 400, message: "Email not confirmed"))
        #expect(message == "Please verify your email first. Check your inbox for the confirmation link.")
    }

    @Test("Other 422 validation messages are not misreported as duplicates")
    func otherValidation() {
        #expect(FriendlyError.authMessage(status: 422, message: "Password should be at least 6 characters.") == nil)
        #expect(FriendlyError.authMessage(status: 500, message: "Invalid login credentials") == nil)
    }

    @Test("Auth mapping never contains dashes")
    func noDashes() {
        for raw in ["Invalid login credentials", "User already registered", "Email not confirmed"] {
            let message = FriendlyError.message(for: SupabaseError.http(status: 400, message: raw))
            #expect(!message.contains("—"))
            #expect(!message.contains("–"))
        }
    }

    @Test("Collaborators store falls back to friendly copy, never raw text")
    func collaboratorsFallback() {
        struct Weird: Error {}
        let message = CollaboratorsStore.message(for: Weird())
        #expect(!message.isEmpty)
        #expect(!message.contains("Weird"))
        let raw = "{\"code\":\"PGRST\"}"
        #expect(!CollaboratorsStore.message(for: SupabaseError.http(status: 400, message: raw)).contains("{"))
    }
}

// MARK: - Cancellation

@Suite("Cancellation handling")
struct NetCancellationTests {

    @Test("CancellationError and URLError.cancelled are both cancellations")
    func detection() {
        #expect(FriendlyError.isCancellation(CancellationError()))
        #expect(FriendlyError.isCancellation(URLError(.cancelled)))
        #expect(!FriendlyError.isCancellation(URLError(.notConnectedToInternet)))
        #expect(!FriendlyError.isCancellation(SupabaseError.offline))
    }

    @Test("The client maps a cancelled load to CancellationError, not a transport error")
    func transportMapping() {
        #expect(SupabaseClient.mapTransportError(URLError(.cancelled)) is CancellationError)
        #expect(SupabaseClient.mapTransportError(CancellationError()) is CancellationError)
        if case SupabaseError.offline = SupabaseClient.mapTransportError(URLError(.timedOut)) {
        } else {
            Issue.record("Timed out should map to .offline")
        }
        if case SupabaseError.transport = SupabaseClient.mapTransportError(URLError(.badServerResponse)) {
        } else {
            Issue.record("Unknown URLError should map to .transport")
        }
    }

    @Test("A cancellation never produces a scary message")
    func neutralMessage() {
        let message = FriendlyError.message(for: CancellationError())
        #expect(!message.localizedCaseInsensitiveContains("wrong"))
        #expect(!message.localizedCaseInsensitiveContains("offline"))
    }

    @Test("GoTrue error_code is decoded as a last-resort message")
    func errorCodeDecoding() throws {
        let json = #"{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}"#
        let body = try JSONDecoder().decode(SupabaseErrorBody.self, from: Data(json.utf8))
        #expect(body.bestMessage == "Invalid login credentials")
        #expect(body.errorCode == "invalid_credentials")
    }
}

// MARK: - Deep links

@Suite("Deep-link parsing")
struct NetDeepLinkTests {

    @Test("Universal invite link yields the token")
    func inviteUniversal() {
        let url = URL(string: "https://aseatawaits.com/invite/abc123")!
        #expect(DeepLinkRouter.parse(url) == .inviteToken("abc123"))
    }

    @Test("Custom-scheme invite link yields the token")
    func inviteCustomScheme() {
        let url = URL(string: "aseatawaits://invite/abc123")!
        #expect(DeepLinkRouter.parse(url) == .inviteToken("abc123"))
    }

    @Test("Recovery tokens are read from the URL fragment")
    func recoveryFragment() {
        let url = URL(string: "https://aseatawaits.com/auth/reset#access_token=AT&refresh_token=RT&type=recovery")!
        #expect(DeepLinkRouter.parse(url) == .recovery(accessToken: "AT", refreshToken: "RT"))
    }

    @Test("Confirmation links with tokens are recognised")
    func confirmQuery() {
        let url = URL(string: "https://www.aseatawaits.com/auth/confirm?access_token=AT&refresh_token=RT&type=signup")!
        #expect(DeepLinkRouter.parse(url) == .emailConfirmed(accessToken: "AT", refreshToken: "RT"))
    }

    @Test("Foreign hosts and missing tokens are unhandled")
    func unhandled() {
        #expect(DeepLinkRouter.parse(URL(string: "https://evil.example/invite/abc")!) == .unhandled)
        #expect(DeepLinkRouter.parse(URL(string: "https://aseatawaits.com/auth/reset")!) == .unhandled)
        #expect(DeepLinkRouter.parse(URL(string: "https://aseatawaits.com/pricing")!) == .unhandled)
    }
}

// MARK: - Guest name matching

@Suite("Accent-tolerant guest name matching")
struct NetGuestNameMatcherTests {

    @Test("Folding strips accents and case")
    func fold() {
        #expect(GuestNameMatcher.fold("  José Núñez ") == "jose nunez")
        #expect(GuestNameMatcher.fold("Renée") == GuestNameMatcher.fold("RENEE"))
    }

    @Test("Diacritic detection")
    func diacritics() {
        #expect(GuestNameMatcher.hasDiacritics("José"))
        #expect(!GuestNameMatcher.hasDiacritics("Jose"))
    }

    @Test("Unaccented query matches accented name and vice versa")
    func symmetricMatch() {
        #expect(GuestNameMatcher.matches("José Núñez", term: "jose"))
        #expect(GuestNameMatcher.matches("Jose Nunez", term: "José"))
        #expect(GuestNameMatcher.matches("Zoë Adams", term: "zoe ad"))
        #expect(!GuestNameMatcher.matches("Olivia Brown", term: "jack"))
    }

    @Test("Match range prefers the start of the name and stays in the original string")
    func range() {
        let name = "Anna-Marie Ánna"
        let range = GuestNameMatcher.matchRange(in: name, term: "anna")
        #expect(range != nil)
        #expect(range.map { String(name[$0]) } == "Anna")
        let inner = GuestNameMatcher.matchRange(in: "Sean Ó Brien", term: "o b")
        #expect(inner.map { String("Sean Ó Brien"[$0]) } == "Ó B")
        #expect(GuestNameMatcher.matchRange(in: "Olivia", term: "   ") == nil)
    }
}
