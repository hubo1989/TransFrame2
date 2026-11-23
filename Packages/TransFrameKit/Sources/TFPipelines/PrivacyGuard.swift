import CoreGraphics
import Foundation
import TFDomain

/// The single outbound exit (SPEC §01 §9, ADR-0010). Image channel: local detection + solid boxes.
/// Text channel: withhold fully sensitive units, placeholder partial spans and restore them afterwards.
public struct PrivacyGuard: Sendable {
    private let detector: (any SensitiveContentDetecting)?

    public init(detector: (any SensitiveContentDetecting)?) {
        self.detector = detector
    }

    /// Whether a destination triggers the guard (cloud always; local network only when enabled).
    public static func applies(to locality: EngineLocality, settings: PrivacySettings, overridden: Bool) -> Bool {
        guard settings.guardEnabled, !overridden else { return false }
        switch locality {
        case .onDevice: return false
        case .localNetwork: return settings.guardLocalNetwork
        case .cloud: return true
        }
    }

    public func protect(_ image: PixelImage, settings: PrivacySettings) async throws(AppError) -> (PixelImage, PrivacyReport) {
        guard let detector else { return (image, .notApplied) }
        let findings = try await detector.detect(in: image)
        let redact = findings.filter { settings.redactedCategories.contains($0.category) && $0.confidence >= settings.confidenceThreshold }
        let hinted = findings.count - redact.count
        guard !redact.isEmpty else {
            return (image, PrivacyReport(applied: false, redactedCount: 0, categories: [], hintedCount: hinted))
        }
        let width = image.cgImage.width, height = image.cgImage.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw .render(.contextUnavailable) }
        context.draw(image.cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for finding in redact {
            let r = finding.box.raw
            context.fill(CGRect(x: r.minX, y: Double(height) - r.maxY, width: r.width, height: r.height))
        }
        guard let masked = context.makeImage() else { throw .render(.contextUnavailable) }
        let categories = Array(Set(redact.map(\.category))).sorted { $0.rawValue < $1.rawValue }
        return (PixelImage(cgImage: masked, scale: image.scale), PrivacyReport(applied: true, redactedCount: redact.count, categories: categories, hintedCount: hinted))
    }

    /// Text channel (ADR-0010 §7).
    public struct TextPlan: Sendable {
        public var units: [TranslationUnit]
        public var withheld: Set<SegmentID>
        public var placeholders: [SegmentID: [String: String]]
        public var report: PrivacyReport
    }

    public static func protect(_ units: [TranslationUnit], settings: PrivacySettings) -> TextPlan {
        var output: [TranslationUnit] = []
        var withheld = Set<SegmentID>()
        var placeholders: [SegmentID: [String: String]] = [:]
        var categories = Set<SensitiveCategory>()
        var count = 0
        for unit in units {
            let matches = SensitiveTextClassifier.matches(in: unit.text)
                .filter { settings.redactedCategories.contains($0.category) && $0.confidence >= settings.confidenceThreshold }
            guard !matches.isEmpty else { output.append(unit); continue }
            count += matches.count
            matches.forEach { categories.insert($0.category) }
            let covered = matches.reduce(0) { $0 + unit.text.distance(from: $1.range.lowerBound, to: $1.range.upperBound) }
            if Double(covered) >= Double(unit.text.filter { !$0.isWhitespace }.count) * 0.8 {
                withheld.insert(unit.id)
                continue
            }
            var text = unit.text
            var map: [String: String] = [:]
            for (index, match) in matches.enumerated().reversed() {
                let token = "⟦P\(index + 1)⟧"
                map[token] = String(unit.text[match.range])
                let lower = text.index(text.startIndex, offsetBy: unit.text.distance(from: unit.text.startIndex, to: match.range.lowerBound))
                let upper = text.index(lower, offsetBy: unit.text.distance(from: match.range.lowerBound, to: match.range.upperBound))
                text.replaceSubrange(lower..<upper, with: token)
            }
            placeholders[unit.id] = map
            output.append(TranslationUnit(id: unit.id, text: text, kind: unit.kind))
        }
        let report = PrivacyReport(applied: count > 0, redactedCount: count, categories: categories.sorted { $0.rawValue < $1.rawValue })
        return TextPlan(units: output, withheld: withheld, placeholders: placeholders, report: report)
    }

    public static func restore(_ text: String, _ map: [String: String]) -> String {
        map.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }
}

/// Glossary matching and deterministic replacement for engines without glossary support (AI-04).
public enum GlossaryMatcher {
    public static func matches(_ entries: [GlossaryEntry], in texts: [String], from: LanguageCode?, to: LanguageCode, app: String?) -> [GlossaryEntry] {
        entries.filter { entry in
            guard entry.to.isSameLanguage(as: to), entry.from.map({ f in from.map { f.isSameLanguage(as: $0) } ?? true }) ?? true else { return false }
            if case .app(let bundle) = entry.scope, bundle != app { return false }
            return texts.contains { contains($0, entry) }
        }
    }

    public static func contains(_ text: String, _ entry: GlossaryEntry) -> Bool {
        text.range(of: entry.source, options: entry.caseSensitive ? [] : [.caseInsensitive]) != nil
    }

    /// Replaces source terms with ⟦Gn⟧ tokens before sending; returns the token map to restore targets.
    public static func protect(_ text: String, _ entries: [GlossaryEntry]) -> (String, [String: String], [GlossaryEntryID]) {
        var result = text
        var map: [String: String] = [:]
        var hits: [GlossaryEntryID] = []
        for (index, entry) in entries.sorted(by: { $0.source.count > $1.source.count }).enumerated() where contains(result, entry) {
            let token = "⟦G\(index + 1)⟧"
            result = result.replacingOccurrences(of: entry.source, with: token, options: entry.caseSensitive ? [] : [.caseInsensitive])
            map[token] = entry.target
            hits.append(entry.id)
        }
        return (result, map, hits)
    }
}
