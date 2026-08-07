//
//  FloorPlanImportService.swift
//  A Seat Awaits
//
//  Thin, injectable wrapper over the `ai-import-floorplan` Supabase Edge
//  Function. Mirrors `GuestImportService`: the app never holds the AI key — it
//  invokes an authenticated, rate-limited, plan-gated Edge Function that owns
//  the vision model, prompt, and layout geometry (see [[ios-architecture]]).
//

import Foundation

/// Calls the AI floor-plan-import Edge Function and returns its canvas-ready
/// plan. Stateless and `Sendable`, so it can be created on demand from any actor.
struct FloorPlanImportService: Sendable {

    private let invoker: any GuestImportFunctionInvoking

    init(invoker: any GuestImportFunctionInvoking) {
        self.invoker = invoker
    }

    /// Sends the floor plan file (PNG/JPEG/WebP/PDF, ≤10 MB) for analysis.
    /// Analysis runs a multi-run vision consensus and typically takes 20–60 s.
    /// Throws `EdgeFunctionError` (plan gate / rate limit / AI failure) or a
    /// transport error — there is no on-device fallback for vision.
    func analyze(eventId: String, fileData: Data, filename: String,
                 contentType: String) async throws -> AiFloorplanImportResponse {
        let body = AiFloorplanImportRequest(eventId: eventId,
                                            fileBase64: fileData.base64EncodedString(),
                                            filename: filename,
                                            contentType: contentType)
        return try await invoker.invokeFunction("ai-import-floorplan", body: body,
                                                as: AiFloorplanImportResponse.self)
    }
}
