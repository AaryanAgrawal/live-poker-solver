import CoreGraphics
import Foundation
import Vision

enum OCR {
    static func texts(_ image: CGImage) -> [String] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        req.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([req])) != nil else { return [] }
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    static func number(_ s: String) -> Double? {
        let clean = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
        let parts = clean.split { !($0.isNumber || $0 == ".") }
        return parts.compactMap { Double($0) }.first
    }

    static func amounts(_ image: CGImage) -> (pot: Double?, call: Double?, all: [Double]) {
        let lines = texts(image)
        var pot: Double?, call: Double?
        for line in lines {
            let low = line.lowercased()
            if pot == nil, low.contains("pot"), let n = number(line) { pot = n }
            if call == nil, low.hasPrefix("call") || low.contains("call "), let n = number(line), n > 0 { call = n }
        }
        return (pot, call, lines.compactMap { number($0) })
    }

    static func numbers(_ image: CGImage) -> [Double] {
        texts(image).compactMap { number($0) }
    }
}
