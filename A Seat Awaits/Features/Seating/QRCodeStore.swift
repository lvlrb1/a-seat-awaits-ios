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
            phase = .failed(Self.message(error,
                fallback: "Couldn't generate the QR code. Please try again."))
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

    // MARK: - Copy / share

    func copyLink() {
        guard let shareURL else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = shareURL.absoluteString
        #endif
        announce("Link copied.")
    }

    /// Writes the clean QR PNG to a temp file and triggers the share sheet.
    /// The PNG encode and file write run off the main actor, like `renderQR`.
    func share() async {
        guard let shareURL else { return }
        #if canImport(UIKit)
        let string = shareURL.absoluteString
        let rendered = qrImage
        let name = eventName
        let slug = eventSlug
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                let data = try rendered?.pngData() ?? QRCodeGenerator.png(for: string)
                return try QRImageExportFile.write(data, eventName: name, slug: slug)
            }.value
            shareItem = QRSharePayload(fileURL: url, link: shareURL, eventName: eventName)
        } catch {
            phase = .failed(Self.message(error,
                fallback: "Couldn't prepare the QR image to share. Please try again."))
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

    /// Server/network failures go through `FriendlyError` so no raw description
    /// ever shows; the generator's own curated copy is kept as-is, and anything
    /// else falls back to the caller's line.
    private static func message(_ error: Error, fallback: String) -> String {
        if let generation = error as? QRCodeGenerator.GenerationError {
            return generation.errorDescription ?? fallback
        }
        if error is SupabaseError || error is URLError || FriendlyError.isOffline(error) {
            return FriendlyError.message(for: error)
        }
        return fallback
    }
}
