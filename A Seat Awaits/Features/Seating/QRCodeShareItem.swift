//
//  QRCodeShareItem.swift
//  A Seat Awaits
//
//  Temp-file persistence and the `UIActivityViewController` item source for
//  sharing the clean QR-code PNG (Messages, Mail, AirDrop, Save Image, Save to
//  Files, Print). Shares the plain QR image — never a screenshot of the screen.
//

import Foundation
#if canImport(UIKit)
import UIKit
import LinkPresentation
import UniformTypeIdentifiers
#endif

/// Identifiable payload that drives the QR share sheet (`.sheet(item:)`).
struct QRSharePayload: Identifiable {
    let id = UUID()
    /// The clean QR PNG on disk.
    let fileURL: URL
    /// The public guest-lookup link, shared alongside the image.
    let link: URL
    let eventName: String
}

/// Writes the QR PNG to a temp file with a web-matching, filesystem-safe name.
nonisolated enum QRImageExportFile {

    /// Writes `data` to `event-{slug}-qrcode.png` (preferred) or
    /// `event-{sanitized-name}-qrcode.png`, atomically replacing any prior file.
    static func write(_ data: Data, eventName: String, slug: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName(eventName: eventName, slug: slug))
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// `event-{slug-or-name}-qrcode.png`. Mirrors the web export's naming.
    static func fileName(eventName: String, slug: String?) -> String {
        let base: String
        if let slug = slug?.trimmingCharacters(in: .whitespacesAndNewlines), !slug.isEmpty {
            base = sanitize(slug)
        } else {
            base = sanitize(eventName)
        }
        return "event-\(base)-qrcode.png"
    }

    /// Lowercased, collapsing every run of non-`[a-z0-9]` characters to a single
    /// hyphen and trimming leading/trailing hyphens — matches the web's
    /// `replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')`.
    static func sanitize(_ value: String) -> String {
        var out = ""
        var lastWasHyphen = false
        for ch in value.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "share" : trimmed
    }
}

#if canImport(UIKit)
/// Describes the QR PNG to `UIActivityViewController` so share targets get clean
/// metadata: an explicit `public.png` type, a useful Mail subject, and a titled
/// preview. The file URL is the payload, so Save Image / Save to Files / AirDrop
/// / Print all receive the real PNG.
final class QRCodeShareItem: NSObject, UIActivityItemSource {
    let fileURL: URL
    let title: String

    init(fileURL: URL, title: String) {
        self.fileURL = fileURL
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { fileURL }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { fileURL }

    func activityViewController(_ controller: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?) -> String { title }

    func activityViewController(_ controller: UIActivityViewController,
                                dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        UTType.png.identifier
    }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = fileURL
        if let image = UIImage(contentsOfFile: fileURL.path) {
            metadata.iconProvider = NSItemProvider(object: image)
        }
        return metadata
    }
}
#endif
