//
//  FloorPlanPDF.swift
//  A Seat Awaits
//
//  Persists and shares the floor-plan PDF that the web (Nuxt) server renders.
//  The app does NOT draw the floor plan itself — the server owns the complete
//  vector design (tables, chairs, rooms, shapes, the guest-list pages, the
//  branded frame, scaling, sorting, pagination). The bytes returned by the
//  server are written to disk and shared unchanged, byte-for-byte.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
import LinkPresentation
import UniformTypeIdentifiers
#endif

// MARK: - Saving the server PDF

/// Writes the server-rendered PDF to a temporary file for sharing. The data is
/// never modified — only saved.
enum FloorPlanExportFile {

    /// Writes `data` to a temp file named
    /// `floorplan_{sanitized-event-name}_{yyyy-MM-dd}.pdf`, atomically replacing
    /// any prior export of the same event so stale bytes can't be reused.
    static func write(_ data: Data, eventName: String, date: Date = Date()) throws -> URL {
        let url = temporaryURL(eventName: eventName, date: date)
        // Drop a previous export at this path first; `.atomic` then writes via a
        // temp file and renames, so a reader never sees a half-written PDF.
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Destination URL for an export, matching the web app's download name.
    static func temporaryURL(eventName: String, date: Date) -> URL {
        let name = "floorplan_\(sanitize(eventName))_\(Self.dateStamp.string(from: date)).pdf"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    /// Replaces every non-ASCII-alphanumeric character with `_`, mirroring the
    /// web export's `replace(/[^a-z0-9]/gi, '_')` so the iOS and web downloads
    /// share a filename and nothing unsafe reaches the filesystem.
    static func sanitize(_ name: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        let cleaned = String(name.map { safe.contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "event" : cleaned
    }

    private static let dateStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Share sheet

#if canImport(UIKit)
/// Describes the exported PDF to `UIActivityViewController` so share targets get
/// clean metadata: a Mail subject, an explicit `com.adobe.pdf` type, and a
/// titled preview in the sheet header. Falls back to the file URL for the actual
/// payload, so Save to Files / AirDrop / Print all receive the real document.
final class FloorPlanActivityItem: NSObject, UIActivityItemSource {
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { url }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { url }

    func activityViewController(_ controller: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?) -> String { title }

    func activityViewController(_ controller: UIActivityViewController,
                                dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        UTType.pdf.identifier
    }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = url
        metadata.url = url
        metadata.iconProvider = NSItemProvider(object: UIImage(systemName: "doc.richtext") ?? UIImage())
        return metadata
    }
}

/// Thin wrapper around `UIActivityViewController` for sharing the exported PDF
/// (Save to Files, Print, AirDrop, Mail, …). Works on both iPhone and iPad.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    /// Called when the activity sheet is dismissed (after sharing or cancel).
    var onComplete: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete?() }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

/// Identifiable wrapper so an exported file URL can drive a `.sheet(item:)`.
struct ExportedDocument: Identifiable {
    let id = UUID()
    let url: URL
}
