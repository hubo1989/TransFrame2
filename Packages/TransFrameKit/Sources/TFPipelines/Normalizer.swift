import CoreGraphics
import Foundation
import TFDomain

/// Turns engine output into an `AnalysisResult` (SPEC §02 §10.1): ids, document coordinates, reading order,
/// paragraph blocks for line-only engines, and filtering into `excluded` with reasons (OCR-13).
public enum RecognitionNormalizer {
    public static let preprocessingVersion = 1

    public static func normalize(
        _ raw: RawRecognition, region: DocumentRect, session: SessionID, inputRevision: Int, fingerprint: ContentHash, provenance: Provenance
    ) -> AnalysisResult {
        let dx = region.minX, dy = region.minY
        var kept: [(RawObservation, DocumentRect)] = []
        var excluded: [ExcludedSegment] = []
        var seen: [(String, DocumentRect)] = []
        for observation in raw.observations {
            let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let box = DocumentRect(observation.box.raw.offsetBy(dx: dx, dy: dy))
            let segment = TextSegment(text: text, box: box, confidence: observation.confidence)
            if let reason = exclusionReason(text, confidence: observation.confidence, fromModel: raw.sent == .image) {
                if !text.isEmpty { excluded.append(ExcludedSegment(segment: segment, reason: reason)) }
                continue
            }
            if seen.contains(where: { $0.0 == text && iou($0.1, box) > 0.5 }) {
                excluded.append(ExcludedSegment(segment: segment, reason: .duplicate))
                continue
            }
            seen.append((text, box))
            kept.append((RawObservation(
                text: text, box: observation.box, quad: observation.quad, confidence: observation.confidence, language: observation.language,
                kind: observation.kind, blockIndex: observation.blockIndex, lines: observation.lines, style: observation.style
            ), box))
        }

        var blocks: [ContentBlock] = []
        var segments: [TextSegment] = []
        if raw.blocks.isEmpty {
            // Line-only engines: paragraphs from geometry; segments stay visual lines (RES-01).
            let lines = mergeVisualLines(kept)
            for group in paragraphs(lines) {
                let blockID = BlockID()
                let groupSegments = group.map { line in
                    TextSegment(
                        kind: line.kind, text: line.text, box: line.box, quad: line.quad, confidence: line.confidence, language: line.language,
                        parent: blockID, translatability: translatability(for: line.text, kind: line.kind), style: line.style
                    )
                }
                let union = groupSegments.dropFirst().reduce(groupSegments[0].box) { $0.union($1.box) }
                blocks.append(ContentBlock(id: blockID, kind: .paragraph, box: union, children: groupSegments.map { .segment($0.id) }))
                segments += groupSegments
            }
        } else {
            let blockIDs = raw.blocks.map { _ in BlockID() }
            var children: [[BlockChild]] = raw.blocks.map { _ in [] }
            var loose: [TextSegment] = []
            for (observation, box) in kept.sorted(by: { readingOrder($0.1, $1.1) }) {
                let parent = observation.blockIndex.flatMap { $0 < blockIDs.count ? blockIDs[$0] : nil }
                var kind = observation.kind
                if case .tableCell(let ref) = kind, let parent {
                    kind = .tableCell(TableCellRef(table: parent, row: ref.row, column: ref.column, rowSpan: ref.rowSpan, columnSpan: ref.columnSpan, isHeader: ref.isHeader))
                }
                let segment = TextSegment(
                    kind: kind, text: observation.text, box: box, confidence: observation.confidence, language: observation.language,
                    parent: parent, translatability: translatability(for: observation.text, kind: kind), style: observation.style
                )
                if let index = observation.blockIndex, index < children.count {
                    children[index].append(.segment(segment.id))
                    segments.append(segment)
                } else {
                    loose.append(segment)
                }
            }
            for (index, rawBlock) in raw.blocks.enumerated() {
                let kind: BlockKind = switch rawBlock.kind {
                case .paragraph: .paragraph
                case .table(let r, let c): .table(rows: r, columns: c)
                case .list(let ordered): .list(ordered: ordered)
                case .codeBlock: .codeBlock
                case .formulaBlock: .formulaBlock
                case .figure: .figure
                case .handwriting: .handwriting
                }
                blocks.append(ContentBlock(
                    id: blockIDs[index], kind: kind, box: DocumentRect(rawBlock.box.raw.offsetBy(dx: dx, dy: dy)),
                    parent: rawBlock.parentIndex.map { blockIDs[$0] }, children: children[index]
                ))
            }
            // Reading order must equal a depth-first walk of the tree; loose segments follow.
            let byID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
            segments = blocks.filter { $0.parent == nil }.flatMap { block in block.children.compactMap { child in
                if case .segment(let id) = child { byID[id] } else { nil }
            } } + loose
        }
        return AnalysisResult(
            session: session, inputRevision: inputRevision, inputFingerprint: fingerprint, region: region, segments: segments,
            blocks: blocks, excluded: excluded, languages: raw.languages, provenance: provenance
        )
    }

    // MARK: Filtering (OCR-13): numbers, amounts and dates are never dropped by keyword

    static let leakageMarkers = ["\"bbox\"", "```", "as an ai", "i'm sorry", "i cannot", "json", "bounding box", "extract the text"]

    static func exclusionReason(_ text: String, confidence: Double?, fromModel: Bool) -> ExclusionReason? {
        if text.isEmpty { return .noise }
        if text.count == 1, !(text.first?.isLetter ?? false), !(text.first?.isNumber ?? false) { return .noise }
        if fromModel {
            let lower = text.lowercased()
            if leakageMarkers.contains(where: { lower.contains($0) }) && !lower.contains(where: \.isNumber) { return .promptLeakage }
        }
        if let confidence, confidence < 0.3 { return .lowConfidence }
        return nil
    }

    static func translatability(for text: String, kind: SegmentKind) -> Translatability {
        if kind.isFormula { return .keepOriginal(.formula) }
        if kind.isCode { return .keepOriginal(.code) }
        let letters = text.filter(\.isLetter).count
        if letters == 0 { return .keepOriginal(.numeric) }
        if text.range(of: #"^(https?://|www\.)\S+$|^[\w.+-]+@[\w-]+\.[\w.]+$|^[A-Z0-9_\-]{2,}\d[A-Z0-9_\-]*$"#, options: .regularExpression) != nil {
            return .keepOriginal(.identifier)
        }
        return .translate
    }

    // MARK: Geometry

    struct Line {
        var text: String
        var box: DocumentRect
        var quad: Quad?
        var confidence: Double?
        var language: LanguageCode?
        var kind: SegmentKind
        var style: SegmentStyleHint?
    }

    /// Fragments on the same visual line (vertical overlap > 60 %, small horizontal gap) are joined (RES-01).
    static func mergeVisualLines(_ items: [(RawObservation, DocumentRect)]) -> [Line] {
        var lines: [Line] = []
        for (observation, box) in items.sorted(by: { readingOrder($0.1, $1.1) }) {
            if let index = lines.lastIndex(where: { line in
                let overlap = min(line.box.maxY, box.maxY) - max(line.box.minY, box.minY)
                return overlap > 0.6 * min(line.box.height, box.height) && box.minX >= line.box.maxX - 2 && box.minX - line.box.maxX < max(line.box.height, box.height) * 1.5
            }), lines[index].kind == .text, observation.kind == .text {
                lines[index].text = joinFragments(lines[index].text, observation.text)
                lines[index].box = lines[index].box.union(box)
                lines[index].quad = nil
                lines[index].confidence = zip2min(lines[index].confidence, observation.confidence)
            } else {
                let quad = observation.quad.flatMap { points -> Quad? in
                    guard points.count == 4 else { return nil }
                    let p = points.map { DocumentPoint(x: $0.x + box.minX - observation.box.minX, y: $0.y + box.minY - observation.box.minY) }
                    return Quad(topLeft: p[0], topRight: p[1], bottomRight: p[2], bottomLeft: p[3])
                }
                lines.append(Line(text: observation.text, box: box, quad: quad, confidence: observation.confidence, language: observation.language, kind: observation.kind, style: observation.style))
            }
        }
        return lines
    }

    private static func zip2min(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case (let a?, let b?): min(a, b)
        default: a ?? b
        }
    }

    static func joinFragments(_ a: String, _ b: String) -> String {
        guard let last = a.last, let first = b.first else { return a + b }
        func cjk(_ c: Character) -> Bool { c.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) } }
        if cjk(last) || cjk(first) || ",.;:!?)]}%".contains(first) { return a + b }
        return a + " " + b
    }

    /// Lines with similar left edge or overlap and a gap under ~1 line height form a paragraph.
    static func paragraphs(_ lines: [Line]) -> [[Line]] {
        var groups: [[Line]] = []
        for line in lines {
            if var last = groups.last, let previous = last.last {
                let gap = line.box.minY - previous.box.maxY
                let height = max(previous.box.height, line.box.height)
                let horizontalOverlap = min(previous.box.maxX, line.box.maxX) - max(previous.box.minX, line.box.minX)
                let similarSize = abs(previous.box.height - line.box.height) < height * 0.45
                if gap >= -height * 0.3, gap < height * 0.9, horizontalOverlap > -height, similarSize, line.kind == .text {
                    last.append(line)
                    groups[groups.count - 1] = last
                    continue
                }
            }
            groups.append([line])
        }
        return groups
    }

    /// Top-to-bottom, then left-to-right within the same row band.
    static func readingOrder(_ a: DocumentRect, _ b: DocumentRect) -> Bool {
        let tolerance = min(a.height, b.height) * 0.5
        if abs(a.minY - b.minY) > tolerance { return a.minY < b.minY }
        return a.minX < b.minX
    }

    static func iou(_ a: DocumentRect, _ b: DocumentRect) -> Double {
        guard let i = a.intersection(b) else { return 0 }
        let union = a.area + b.area - i.area
        return union > 0 ? i.area / union : 0
    }
}

/// Splits a large image into ≤ 2000 px tiles with 48 px overlap (OCR-10) and merges results.
public enum ImageTiling {
    public static let maxEdge = 2000
    public static let overlap = 48

    public static func tiles(width: Int, height: Int, maxEdge: Int = maxEdge, overlap: Int = overlap) -> [CGRect] {
        func ranges(_ length: Int) -> [(Int, Int)] {
            guard length > maxEdge else { return [(0, length)] }
            var result: [(Int, Int)] = []
            var start = 0
            while start < length {
                let end = min(start + maxEdge, length)
                result.append((start, end - start))
                if end == length { break }
                start = end - overlap
            }
            return result
        }
        return ranges(height).flatMap { y in ranges(width).map { x in CGRect(x: x.0, y: y.0, width: x.1, height: y.1) } }
    }

    /// Offsets tile observations into the full image and drops duplicates from overlapping strips.
    public static func merge(_ parts: [(CGRect, RawRecognition)]) -> RawRecognition {
        var merged = RawRecognition(observations: [], sent: parts.first?.1.sent ?? .nothing)
        for (tile, raw) in parts {
            for var observation in raw.observations {
                observation.box = observation.box.offsetBy(dx: tile.minX, dy: tile.minY)
                observation.quad = observation.quad?.map { CGPoint(x: $0.x + tile.minX, y: $0.y + tile.minY) }
                let isDuplicate = merged.observations.contains { other in
                    other.text == observation.text && (other.box.intersection(observation.box)?.area ?? 0) > 0.3 * min(other.box.area, observation.box.area)
                }
                if !isDuplicate { merged.observations.append(observation) }
            }
            merged.languages += raw.languages.filter { !merged.languages.contains($0) }
        }
        return merged
    }
}
