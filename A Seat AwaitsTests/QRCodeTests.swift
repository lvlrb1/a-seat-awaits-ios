//
//  QRCodeTests.swift
//  A Seat AwaitsTests
//
//  Unit tests for the local QR-code feature: secure token generation, the
//  public `/r/{token}` URL builder, the on-device QR image generator, and the
//  share-file naming.
//

import Testing
import Foundation
#if canImport(UIKit)
import UIKit
#endif
@testable import A_Seat_Awaits

// MARK: - SecureToken

@Test func secureTokenIsURLSafeAndUnpadded() throws {
    let token = try #require(SecureToken.generate())
    #expect(!token.isEmpty)
    #expect(!token.contains("+"))
    #expect(!token.contains("/"))
    #expect(!token.contains("="))
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    #expect(token.allSatisfy { allowed.contains($0) })
}

@Test func secureTokenHasAtLeast128BitsOfEntropy() throws {
    // 16 bytes (128 bits) → 22 base64url chars with no padding.
    let token = try #require(SecureToken.generate(byteCount: 16))
    #expect(token.count == 22)
}

@Test func secureTokensAreUnique() throws {
    let a = try #require(SecureToken.generate())
    let b = try #require(SecureToken.generate())
    #expect(a != b)
}

// MARK: - GuestLookupURL

@Test func guestLookupURLBuildsCanonicalPath() throws {
    let base = URL(string: "https://aseatawaits.com")!
    let url = try #require(GuestLookupURL.make(base: base, token: "abc123"))
    #expect(url.absoluteString == "https://aseatawaits.com/r/abc123")
}

@Test func guestLookupURLNormalisesTrailingSlashes() throws {
    let base = URL(string: "https://staging.aseatawaits.com///")!
    let url = try #require(GuestLookupURL.make(base: base, token: "tok"))
    #expect(url.absoluteString == "https://staging.aseatawaits.com/r/tok")
}

@Test func guestLookupURLRejectsBlankToken() {
    let base = URL(string: "https://aseatawaits.com")!
    #expect(GuestLookupURL.make(base: base, token: "") == nil)
    #expect(GuestLookupURL.make(base: base, token: "   ") == nil)
}

// MARK: - QRImageExportFile naming

@Test func exportFileNamePrefersSlug() {
    let name = QRImageExportFile.fileName(eventName: "Smith & Jones Wedding", slug: "smith-jones-2026")
    #expect(name == "event-smith-jones-2026-qrcode.png")
}

@Test func exportFileNameSanitizesEventName() {
    let name = QRImageExportFile.fileName(eventName: "Smith & Jones Wedding!", slug: nil)
    #expect(name == "event-smith-jones-wedding-qrcode.png")
}

@Test func exportFileNameFallsBackForEmptyInput() {
    let name = QRImageExportFile.fileName(eventName: "   ", slug: nil)
    #expect(name == "event-share-qrcode.png")
}

// MARK: - QRCodeGenerator

#if canImport(UIKit)
@Test func qrGeneratorProducesPrintReadySquareImage() throws {
    let image = try QRCodeGenerator.image(for: "https://aseatawaits.com/r/sample-token",
                                          minimumPixelSize: 1024)
    let cg = try #require(image.cgImage)
    #expect(cg.width == cg.height)                  // not stretched
    #expect(cg.width >= 1024)                        // print-ready resolution
}

@Test func qrGeneratorEmitsNonEmptyPNG() throws {
    let data = try QRCodeGenerator.png(for: "https://aseatawaits.com/r/sample-token")
    #expect(data.count > 0)
    // PNG signature: 0x89 'P' 'N' 'G'.
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
    #expect(Array(data.prefix(4)) == signature)
}

@Test func qrGeneratorIsDeterministic() throws {
    let a = try QRCodeGenerator.png(for: "https://aseatawaits.com/r/same")
    let b = try QRCodeGenerator.png(for: "https://aseatawaits.com/r/same")
    #expect(a == b)
}

@Test func qrGeneratorRejectsEmptyInput() {
    #expect(throws: QRCodeGenerator.GenerationError.self) {
        _ = try QRCodeGenerator.image(for: "")
    }
}
#endif
