//
//  GuestLookupLink.swift
//  A Seat Awaits
//
//  Pure helpers for the public guest-lookup link: secure token generation and
//  the canonical `{site}/r/{token}` URL. No Supabase, SwiftUI, or Event
//  knowledge here — kept tiny and testable.
//

import Foundation
import Security

/// Cryptographically secure, URL-safe token generation.
nonisolated enum SecureToken {

    /// Generates a URL-safe, unpadded base64 token from `byteCount` bytes of
    /// secure randomness (default 16 bytes = 128 bits). Returns nil only if the
    /// system RNG is unavailable.
    static func generate(byteCount: Int = 16) -> String? {
        guard byteCount > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, byteCount, base)
        }
        guard status == errSecSuccess else { return nil }

        // base64url, no padding.
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Builds the canonical public guest-lookup URL: `{base}/r/{token}`.
nonisolated enum GuestLookupURL {

    /// Normalises `base` (trimming any trailing slashes to avoid `//r/`) and
    /// appends `/r/{token}`. Returns nil for a blank token or un-formable URL.
    static func make(base: URL, token: String) -> URL? {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return nil }

        var origin = base.absoluteString
        while origin.hasSuffix("/") { origin.removeLast() }
        guard !origin.isEmpty else { return nil }

        return URL(string: "\(origin)/r/\(trimmedToken)")
    }
}
