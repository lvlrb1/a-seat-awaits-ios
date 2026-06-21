//
//  QRCodeStore.swift
//  A Seat Awaits
//
//  Owns the QR-code feature's state for one event: ensuring a public lookup
//  token exists (creating one for the owner when missing), building the public
//  URL, generating the QR image, and the copy/share actions. Generation runs
//  off the main actor; token creation lives here, never in a SwiftUI view body.
//

import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// PATCH payload to persist a freshly-minted token to `public.events`.
private nonisolated struct EventTokenPatch: Encodable, Sendable {
    let qr_code_token: String
}

/// PATCH payload that clears the token (sets it to SQL NULL), disabling the
/// public guest lookup entirely (F15).
private nonisolated struct EventTokenClearPatch: Encodable, Sendable {
    func encode(to encoder: Encoder) throws {
        enum K: String, CodingKey { case qr_code_token }
        var c = encoder.container(keyedBy: K.self)
        try c.encodeNil(forKey: .qr_code_token)
    }
}

@MainActor
@Observable
final class QRCodeStore {

    enum Phase: Equatable {
        case loading
        case ready
        /// No token, and the signed-in user isn't the owner who could create one.
        case missingTokenOwnerOnly
        /// The owner disabled the public guest lookup (F15).
        case disabled
        case failed(String)
    }

    let eventName: String
    private let eventID: String
    private let eventSlug: String?
    private let ownerID: String
    private let currentUserID: String?
    private let baseURL: URL
    private let supabase: SupabaseClient

    private(set) var phase: Phase = .loading
    private(set) var token: String?
    private(set) var shareURL: URL?
    #if canImport(UIKit)
    private(set) var qrImage: UIImage?
    #endif

    /// Transient, accessibility-announced confirmation (e.g. "Link copied.").
    var copyFeedback: String?
    /// Drives the share sheet once a temp PNG is ready.
    var shareItem: QRSharePayload?

    /// Guards against re-running token resolution on repeat `.task`/appearances —
    /// a valid token must never be rotated automatically.
    private var hasPrepared = false
    private var feedbackTask: Task<Void, Never>?

    var isOwner: Bool { currentUserID != nil && currentUserID == ownerID }

    init(event: Event, supabase: SupabaseClient, currentUserID: String?, baseURL: URL) {
        self.eventName = event.name
        self.eventID = event.id
        self.eventSlug = event.slug
        self.ownerID = event.ownerId
        self.token = event.qrCodeToken?.nilIfBlank
        self.currentUserID = currentUserID
        self.baseURL = baseURL
        self.supabase = supabase
    }

    /// Ensures a token exists, builds the public URL, and renders the QR.
    /// Idempotent: never creates a second token and never rotates a valid one.
    /// Safe to call from `.task`.
    func prepare() async {
        guard !hasPrepared else { return }
        hasPrepared = true
        await ensureTokenThenRender()
    }

    /// Retry after a failure. Re-resolves the token only if one still doesn't
    /// exist — it never replaces a token that was already created/printed.
    func retry() async {
        await ensureTokenThenRender()
    }

    private func ensureTokenThenRender() async {
        phase = .loading

        if token == nil {
            guard isOwner else {
                phase = .missingTokenOwnerOnly
                return
            }
            guard let candidate = SecureToken.generate() else {
                phase = .failed("Couldn't create a secure guest link. Please try again.")
                return
            }
            do {
                token = try await persistToken(candidate)
            } catch {
                phase = .failed(Self.message(error,
                    fallback: "Couldn't create the guest link. Please try again."))
                return
            }
        }

        guard let token, let url = GuestLookupURL.make(base: baseURL, token: token) else {
            phase = .failed("Couldn't build the guest link.")
            return
        }
        shareURL = url
        await renderQR(for: url)
    }

    private func renderQR(for url: URL) async {
        #if canImport(UIKit)
        let string = url.absoluteString
        do {
            let image = try await Task.detached(priority: .userInitiated) {
                try QRCodeGenerator.image(for: string, correctionLevel: .medium)
            }.value
            qrImage = image
            phase = .ready
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription
                ?? "Couldn't generate the QR code. Please try again.")
        }
        #else
        phase = .ready
        #endif
    }

    /// Persists `candidate` to `public.events`, filtered by `id` AND `owner_id`,
    /// and returns the token Supabase actually stored.
    private func persistToken(_ candidate: String) async throws -> String {
        guard let ownerFilter = currentUserID else { throw SupabaseError.notAuthenticated }
        let updated: [Event] = try await supabase.update(
            "events",
            values: EventTokenPatch(qr_code_token: candidate),
            query: [URLQueryItem(name: "id", value: "eq.\(eventID)"),
                    URLQueryItem(name: "owner_id", value: "eq.\(ownerFilter)")],
            returning: [Event].self)
        guard let saved = updated.first?.qrCodeToken?.nilIfBlank else {
            throw SupabaseError.http(status: 403,
                                     message: "The guest link couldn't be saved for this event.")
        }
        return saved
    }

    // MARK: - Rotate / disable the public link (owner only, F15)

    /// Mints a brand-new token, invalidating every previously shared code/QR, and
    /// re-renders. Owner-only; the UI gates this behind a confirmation.
    func regenerateLink() async {
        guard isOwner else { return }
        guard let candidate = SecureToken.generate() else {
            phase = .failed("Couldn't create a secure guest link. Please try again.")
            return
        }
        phase = .loading
        do {
            token = try await persistToken(candidate)
        } catch {
            phase = .failed(Self.message(error,
                fallback: "Couldn't regenerate the guest link. Please try again."))
            return
        }
        guard let token, let url = GuestLookupURL.make(base: baseURL, token: token) else {
            phase = .failed("Couldn't build the guest link.")
            return
        }
        shareURL = url
        await renderQR(for: url)
        announce("New guest link created. Previously shared codes no longer work.")
    }

    /// Disables the public guest lookup by clearing the token. Existing codes/QRs
    /// stop resolving. Owner-only; the UI gates this behind a confirmation.
    func disableLink() async {
        guard isOwner, let ownerFilter = currentUserID else { return }
        phase = .loading
        do {
            _ = try await supabase.update(
                "events",
                values: EventTokenClearPatch(),
                query: [URLQueryItem(name: "id", value: "eq.\(eventID)"),
                        URLQueryItem(name: "owner_id", value: "eq.\(ownerFilter)")],
                returning: [EmptyRow].self)
        } catch {
            phase = .failed(Self.message(error,
                fallback: "Couldn't disable the guest link. Please try again."))
            return
        }
        token = nil
        shareURL = nil
        #if canImport(UIKit)
        qrImage = nil
        #endif
        phase = .disabled
        announce("Guest lookup disabled. Existing codes no longer work.")
    }

    // MARK: - Copy / share

    func copyLink() {
        guard let shareURL else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = shareURL.absoluteString
        #endif
        announce("Link copied.")
    }

    /// Writes the clean QR PNG to a temp file and triggers the share sheet.
    func share() async {
        guard let shareURL else { return }
        #if canImport(UIKit)
        do {
            let data: Data
            if let png = qrImage?.pngData() {
                data = png
            } else {
                data = try QRCodeGenerator.png(for: shareURL.absoluteString)
            }
            let url = try QRImageExportFile.write(data, eventName: eventName, slug: eventSlug)
            shareItem = QRSharePayload(fileURL: url, link: shareURL, eventName: eventName)
        } catch {
            phase = .failed("Couldn't prepare the QR image to share. Please try again.")
        }
        #endif
    }

    private func announce(_ message: String) {
        copyFeedback = message
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
        // Auto-clear so no permanent success banner lingers onscreen.
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.copyFeedback = nil
        }
    }

    private static func message(_ error: Error, fallback: String) -> String {
        (error as? LocalizedError)?.errorDescription ?? fallback
    }
}
