import AppKit
import CoreGraphics
import ScreenCaptureKit

struct PokerWindow: Identifiable {
    let window: SCWindow
    var id: CGWindowID { window.windowID }
    var appName: String { window.owningApplication?.applicationName ?? "App" }
    var label: String {
        let title = window.title ?? ""
        return title.isEmpty ? appName : "\(appName) — \(title)"
    }
}

enum Capture {
    static func listWindows() async throws -> [PokerWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows
            .filter { $0.frame.width > 300 && $0.frame.height > 200 && $0.owningApplication != nil }
            .map { PokerWindow(window: $0) }
            .sorted { $0.label < $1.label }
    }

    static func capture(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = min(1.0, 1024.0 / window.frame.width)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func jpeg(_ image: CGImage, quality: Double = 0.78) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    static func nsImage(_ image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Tiny grayscale fingerprint. Board changes move many pixels; clocks and
    /// animations move few, so this cheap gate runs before any Jev call.
    static func fingerprint(_ image: CGImage) -> [UInt8] {
        let w = 48, h = 27
        var px = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }

    static func diffRatio(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var changed = 0
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > 18 { changed += 1 }
        return Double(changed) / Double(a.count)
    }

    static func cropCG(_ image: CGImage, box: [String: Double]) -> CGImage? {
        guard let l = box["left"], let r = box["right"], let t = box["top"], let b = box["bottom"] else { return nil }
        let rect = CGRect(x: l * Double(image.width), y: t * Double(image.height),
                          width: max(1, (r - l) * Double(image.width)), height: max(1, (b - t) * Double(image.height)))
        return image.cropping(to: rect)
    }

    static func crop(_ image: CGImage, box: [String: Double]) -> NSImage? {
        cropCG(image, box: box).map { nsImage($0) }
    }
}
