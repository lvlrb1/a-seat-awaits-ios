//
//  QRCodeGenerator.swift
//  A Seat Awaits
//
//  Pure, dependency-free QR-code image generation. Turns a String/URL into a
//  crisp, standards-compliant, print-ready PNG entirely on-device with Core
//  Image — no network, no remote QR service. Knows nothing about Event,
//  Supabase, navigation, or SwiftUI so it stays trivially testable.
//

import CoreImage
import CoreImage.CIFilterBuiltins
#if canImport(UIKit)
import UIKit
#endif

nonisolated enum QRCodeGenerator {

    /// Error-correction level. Higher levels tolerate more damage but produce
    /// denser codes. `M` (~15%) is the standard default; `Q` (~25%) is sturdier.
    enum CorrectionLevel: String {
        case medium = "M"
        case quartile = "Q"
    }

    enum GenerationError: LocalizedError {
        case emptyInput
        case generationFailed

        var errorDescription: String? {
            switch self {
            case .emptyInput:
                return "There's no link to encode yet."
            case .generationFailed:
                return "Couldn't generate the QR code. Please try again."
            }
        }
    }

    #if canImport(UIKit)

    /// Generates a black-on-white QR `UIImage` for `string`.
    ///
    /// Guarantees:
    /// - Hard square modules (integer upscale, interpolation/AA disabled).
    /// - A white quiet zone of at least `quietZoneModules` on every side.
    /// - At least `minimumPixelSize` px on each edge.
    /// - Opaque black modules on a white background regardless of UI appearance.
    static func image(for string: String,
                      correctionLevel: CorrectionLevel = .medium,
                      minimumPixelSize: CGFloat = 1024,
                      quietZoneModules: Int = 4) throws -> UIImage {
        guard !string.isEmpty, let payload = string.data(using: .utf8) else {
            throw GenerationError.emptyInput
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = payload
        filter.correctionLevel = correctionLevel.rawValue
        guard let output = filter.outputImage else { throw GenerationError.generationFailed }

        // Render at 1px-per-module to capture the exact, pure black/white matrix.
        let context = CIContext()
        guard let modules = context.createCGImage(output, from: output.extent) else {
            throw GenerationError.generationFailed
        }

        return try compose(modules: modules,
                           quietZoneModules: max(0, quietZoneModules),
                           minimumPixelSize: minimumPixelSize)
    }

    /// PNG bytes for the QR image — convenience for sharing/saving.
    static func png(for string: String,
                    correctionLevel: CorrectionLevel = .medium,
                    minimumPixelSize: CGFloat = 1024,
                    quietZoneModules: Int = 4) throws -> Data {
        let image = try image(for: string,
                              correctionLevel: correctionLevel,
                              minimumPixelSize: minimumPixelSize,
                              quietZoneModules: quietZoneModules)
        guard let data = image.pngData() else { throw GenerationError.generationFailed }
        return data
    }

    /// Pads the raw module bitmap with a white quiet zone and upscales it by an
    /// integer factor with smoothing disabled, so every module stays a hard
    /// square and the export remains a valid, scannable QR symbol.
    private static func compose(modules: CGImage,
                                quietZoneModules: Int,
                                minimumPixelSize: CGFloat) throws -> UIImage {
        let moduleCount = modules.width                 // Core Image output is square.
        let totalModules = moduleCount + quietZoneModules * 2
        guard moduleCount > 0, totalModules > 0 else { throw GenerationError.generationFailed }

        // Integer scale so module edges always land on whole pixels.
        let scale = max(1, Int((minimumPixelSize / CGFloat(totalModules)).rounded(.up)))
        let pixelSize = totalModules * scale

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: pixelSize,
                                  height: pixelSize,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw GenerationError.generationFailed
        }

        // Opaque white background (this also paints the quiet zone).
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))

        // Nearest-neighbour, no antialiasing → crisp square modules.
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)

        let inset = quietZoneModules * scale
        let drawn = moduleCount * scale
        ctx.draw(modules, in: CGRect(x: inset, y: inset, width: drawn, height: drawn))

        guard let cgImage = ctx.makeImage() else { throw GenerationError.generationFailed }
        return UIImage(cgImage: cgImage)
    }

    #endif
}
