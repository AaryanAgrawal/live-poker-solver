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

extension Capture {
    /// Cheap local guess that a window holds a poker table: lots of green/brown felt.
    static func feltScore(_ image: CGImage) -> Double {
        let w = 96, h = 54
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var felt = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            let green = g > r + 8 && g >= b && g > 45
            let brown = r > 70 && r > g && g > b && r < 190
            if green || brown { felt += 1 }
        }
        return Double(felt) / Double(w * h)
    }
}

extension Capture {
    /// Bounding box (0-1 fractions) of the felt region, found locally.
    /// Scanning this crop instead of the whole window makes cards far bigger for Jev.
    static func tableBox(_ image: CGImage) -> [String: Double]? {
        let w = 192, h = 108
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func felt(_ i: Int) -> Bool {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            return (g > r + 8 && g >= b && g > 45) || (r > 70 && r > g && g > b && r < 190)
        }
        var rows = [Int](repeating: 0, count: h), cols = [Int](repeating: 0, count: w)
        for y in 0..<h { for x in 0..<w where felt((y * w + x) * 4) { rows[y] += 1; cols[x] += 1 } }
        guard let top = rows.firstIndex(where: { $0 > w / 10 }), let bottom = rows.lastIndex(where: { $0 > w / 10 }),
              let left = cols.firstIndex(where: { $0 > h / 10 }), let right = cols.lastIndex(where: { $0 > h / 10 }),
              right > left, bottom > top else { return nil }
        let pad = 0.06
        let box = ["left": max(0, Double(left) / Double(w) - pad), "right": min(1, Double(right + 1) / Double(w) + pad),
                   "top": max(0, Double(top) / Double(h) - pad), "bottom": min(1, Double(bottom + 1) / Double(h) + pad)]
        let area = (box["right"]! - box["left"]!) * (box["bottom"]! - box["top"]!)
        return area > 0.08 && area < 0.95 ? box : nil
    }
}
