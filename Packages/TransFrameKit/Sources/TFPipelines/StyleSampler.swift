import CoreGraphics
import Foundation
import TFDomain

/// Samples each segment's background and text colour from the analysis input, and marks fixed-width sources, so in-place
/// translations look like the original line instead of a pasted label. Runs locally before results are cached.
public enum StyleSampler {
    /// Apps whose text is set in fixed-width faces (terminals and code editors).
    static let monospacedApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "org.alacritty", "com.github.wez.wezterm", "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        "com.sublimetext.4", "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.jetbrains.goland", "dev.zed.Zed", "com.panic.Nova",
    ]

    /// `origin` is the document position of the image's top-left pixel.
    public static func annotate(_ result: AnalysisResult, image: CGImage, origin: DocumentPoint, appBundleID: String?) -> AnalysisResult {
        guard let pixels = Pixels(image) else { return result }
        let appIsMonospaced = appBundleID.map(monospacedApps.contains) ?? false
        let segments = result.segments.map { segment -> TextSegment in
            let rect = segment.box.raw.offsetBy(dx: -origin.x, dy: -origin.y)
            let colors = pixels.colors(in: rect)
            let monospaced = appIsMonospaced || segment.kind.isCode || CodeLines.looksLikeCode(segment.text)
            let base = segment.style ?? SegmentStyleHint()
            return segment.with(style: base.with(foreground: colors?.foreground, background: colors?.background, monospaced: monospaced))
        }
        return AnalysisResult(
            id: result.id, session: result.session, inputRevision: result.inputRevision, inputFingerprint: result.inputFingerprint,
            region: result.region, segments: segments, blocks: result.blocks, excluded: result.excluded, languages: result.languages,
            provenance: result.provenance
        )
    }

    /// RGBA8 copy of an image in sRGB, top-left origin.
    struct Pixels {
        let width: Int
        let height: Int
        let data: [UInt8]

        init?(_ image: CGImage) {
            width = image.width
            height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard drawn else { return nil }
            data = buffer
        }

        func pixel(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let i = (y * width + x) * 4
            return (Double(data[i]) / 255, Double(data[i + 1]) / 255, Double(data[i + 2]) / 255)
        }

        /// Background = median of a 2 px ring just outside the box; text = median of the 15 % of inner pixels farthest from it.
        func colors(in rect: CGRect) -> (background: RGBA, foreground: RGBA)? {
            let box = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !box.isNull, box.width >= 2, box.height >= 2 else { return nil }
            var ring: [(Double, Double, Double)] = []
            let outer = box.insetBy(dx: -2, dy: -2).intersection(CGRect(x: 0, y: 0, width: width, height: height))
            let stepX = max(Int(outer.width) / 80, 1), stepY = max(Int(outer.height) / 20, 1)
            for x in stride(from: Int(outer.minX), to: Int(outer.maxX), by: stepX) {
                for y in [Int(outer.minY), Int(outer.maxY) - 1] { ring.append(pixel(x, y)) }
            }
            for y in stride(from: Int(outer.minY), to: Int(outer.maxY), by: stepY) {
                for x in [Int(outer.minX), Int(outer.maxX) - 1] { ring.append(pixel(x, y)) }
            }
            guard let background = Self.median(ring) else { return nil }
            var inner: [((Double, Double, Double), Double)] = []
            let innerStepX = max(Int(box.width) / 120, 1), innerStepY = max(Int(box.height) / 24, 1)
            for y in stride(from: Int(box.minY), to: Int(box.maxY), by: innerStepY) {
                for x in stride(from: Int(box.minX), to: Int(box.maxX), by: innerStepX) {
                    let p = pixel(x, y)
                    inner.append((p, Self.distance(p, background)))
                }
            }
            let farthest = inner.sorted { $0.1 > $1.1 }.prefix(max(inner.count * 15 / 100, 1)).map(\.0)
            let backgroundColor = RGBA(red: background.0, green: background.1, blue: background.2)
            guard let text = Self.median(Array(farthest)) else { return nil }
            var foreground = RGBA(red: text.0, green: text.1, blue: text.2)
            // Too little contrast (blurred or tiny text): fall back to black or white on the sampled background.
            if RGBA.contrastRatio(foreground, backgroundColor) < 3 {
                foreground = RGBA.contrastRatio(.black, backgroundColor) >= RGBA.contrastRatio(.white, backgroundColor) ? .black : .white
            }
            return (backgroundColor, foreground)
        }

        static func median(_ values: [(Double, Double, Double)]) -> (Double, Double, Double)? {
            guard !values.isEmpty else { return nil }
            func mid(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
            return (mid(values.map(\.0)), mid(values.map(\.1)), mid(values.map(\.2)))
        }

        static func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
            let dr = a.0 - b.0, dg = a.1 - b.1, db = a.2 - b.2
            return dr * dr + dg * dg + db * db
        }
    }
}

/// Line-level code and data detection (translatability and font choice).
public enum CodeLines {
    private static let identifierPatterns: [String] = [
        #"^(https?|file|ftp)://\S+$"#,                                   // URL
        #"^[~.]?/?([\w.@-]+/)+[\w.@-]*$"#,                              // path
        #"^[0-9a-fA-F]{8,}$"#,                                          // hash
        #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, // UUID
        #"^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2})?([.,]\d+)?(Z|[+-]\d{2}:?\d{2})?)?$"#, // ISO date/time
    ]
    private static let codeKeywords = #"^\s*(let|var|const|func|function|def|class|struct|enum|import|return|if|else|for|while|switch|case|"#
        + #"public|private|static|#include|package|fn|impl|use)\b"#
    private static let codeLine = codeKeywords + #"|[{};]\s*$|=>|::|->|==|!=|\)\s*\{"#
    private static let jsonKeyOnly = #"^\s*"[^"]+"\s*:\s*[\[\{]?\s*,?\s*$"#
    private static let jsonValue = #"^(\s*"[^"]+"\s*:\s*")(.*)("\s*,?\s*)$"#

    /// OCR turns straight quotes in code fonts into curly quotes, primes or even `¿`/`‚`; fold them back to `"` before matching.
    public static func normalizedQuotes(_ text: String) -> String {
        var folded = String(text.map { "“”„‟″'‘’‚‛`´¿".contains($0) ? "\"" : $0 })
        while folded.contains("\"\"") { folded = folded.replacingOccurrences(of: "\"\"", with: "\"") }
        return folded
    }

    /// Text that must stay as is: identifiers, paths, URLs, hashes, timestamps, JSON keys or non-text JSON values.
    public static func isIdentifier(_ text: String) -> Bool {
        let trimmed = normalizedQuotes(text).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\",'"))
        if identifierPatterns.contains(where: { trimmed.range(of: $0, options: .regularExpression) != nil }) { return true }
        // A single token with camelCase or snake_case parts (e.g. a JSON key the OCR glued to its value).
        return !trimmed.contains(where: \.isWhitespace) && trimmed.range(of: #"[a-z][A-Z]|[A-Za-z]_[A-Za-z]"#, options: .regularExpression) != nil
    }

    public static func looksLikeCode(_ raw: String) -> Bool {
        let text = normalizedQuotes(raw)
        if text.range(of: codeLine, options: .regularExpression) != nil || text.range(of: jsonKeyOnly, options: .regularExpression) != nil { return true }
        if jsonValueTemplate(text) != nil { return true }
        let symbols = text.filter { "{}[]()<>=;:\"'`\\/|&*#$".contains($0) }.count
        let letters = text.filter(\.isLetter).count
        return text.count >= 6 && Double(symbols) > Double(max(letters, 1)) * 0.5
    }

    /// A JSON line with a quoted string value: `"key": "value",` → (`"key": "`, `value`, `",`). Only the value is translated.
    public static func jsonValueTemplate(_ raw: String) -> (prefix: String, value: String, suffix: String)? {
        let text = normalizedQuotes(raw)
        guard let regex = try? NSRegularExpression(pattern: jsonValue),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let p = Range(match.range(at: 1), in: text), let v = Range(match.range(at: 2), in: text), let s = Range(match.range(at: 3), in: text)
        else { return nil }
        return (String(text[p]), String(text[v]), String(text[s]))
    }

    /// Whether a JSON string value is natural language worth translating (has letters and a space, and is not an identifier).
    public static func isNaturalLanguage(_ value: String) -> Bool {
        let unescaped = value.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\/", with: "/")
        let letters = unescaped.filter(\.isLetter).count
        let cjk = unescaped.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
        return !isIdentifier(unescaped) && letters >= 3 && (unescaped.contains(" ") || cjk)
    }

    public static func isJSONKeyOnly(_ text: String) -> Bool { normalizedQuotes(text).range(of: jsonKeyOnly, options: .regularExpression) != nil }
}
