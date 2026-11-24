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
                let parent = observation.blockIndex.flatMap { blockIDs.indices.contains($0) ? blockIDs[$0] : nil }
                var kind = observation.kind
                if case .tableCell(let ref) = kind, let parent {
                    kind = .tableCell(
                        TableCellRef(
                            table: parent, row: ref.row, column: ref.column, rowSpan: ref.rowSpan, columnSpan: ref.columnSpan, isHeader: ref.isHeader)
                    )
                }
                let segment = TextSegment(
                    kind: kind, text: observation.text, box: box, quad: quad(for: observation, in: box),
                    confidence: observation.confidence, language: observation.language,
                    parent: parent, translatability: translatability(for: observation.text, kind: kind), style: observation.style
                )
                if let index = observation.blockIndex, children.indices.contains(index) {
                    children[index].append(.segment(segment.id))
                    segments.append(segment)
                } else {
                    loose.append(segment)
                }
            }
            let parents = raw.blocks.enumerated().map { index, block in
                block.parentIndex.flatMap { raw.blocks.indices.contains($0) && $0 < index ? $0 : nil }
            }
            for (index, parent) in parents.enumerated() {
                if let parent { children[parent].append(.block(blockIDs[index])) }
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
                    parent: parents[index].map { blockIDs[$0] }, children: children[index]
                ))
            }
            // Reading order must equal a depth-first walk of the tree; loose segments follow.
            let byID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
            let blocksByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
            func orderedSegments(in block: ContentBlock) -> [TextSegment] {
                block.children.flatMap { child -> [TextSegment] in
                    switch child {
                    case .segment(let id): byID[id].map { [$0] } ?? []
                    case .block(let id): blocksByID[id].map { orderedSegments(in: $0) } ?? []
                    }
                }
            }
            segments = blocks.filter { $0.parent == nil }.flatMap { orderedSegments(in: $0) } + loose
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
        // Data and code stay as they are: paths, hashes, timestamps, JSON keys and non-text JSON values, code lines.
        if CodeLines.isIdentifier(text) { return .keepOriginal(.identifier) }
        if CodeLines.isJSONKeyOnly(text) { return .keepOriginal(.code) }
        if let template = CodeLines.jsonValueTemplate(text) {
            return CodeLines.isNaturalLanguage(template.value) ? .translate : .keepOriginal(.code)
        }
        if CodeLines.looksLikeCode(text) { return .keepOriginal(.code) }
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
                return overlap > 0.6 * min(line.box.height, box.height) && box.minX >= line.box.maxX - 2
                    && box.minX - line.box.maxX < max(line.box.height, box.height) * 1.5
            }), lines[index].kind == .text, observation.kind == .text {
                lines[index].text = joinFragments(lines[index].text, observation.text)
                lines[index].box = lines[index].box.union(box)
                lines[index].quad = nil
                lines[index].confidence = zip2min(lines[index].confidence, observation.confidence)
            } else {
                let quad = quad(for: observation, in: box)
                lines.append(
                    Line(
                        text: observation.text, box: box, quad: quad, confidence: observation.confidence, language: observation.language,
                        kind: observation.kind, style: observation.style))
            }
        }
        return lines
    }

    private static func quad(for observation: RawObservation, in box: DocumentRect) -> Quad? {
        guard let points = observation.quad, points.count == 4 else { return nil }
        let offsetX = box.minX - observation.box.minX
        let offsetY = box.minY - observation.box.minY
        let pointsInDocument = points.map { DocumentPoint(x: $0.x + offsetX, y: $0.y + offsetY) }
        return Quad(topLeft: pointsInDocument[0], topRight: pointsInDocument[1], bottomRight: pointsInDocument[2], bottomLeft: pointsInDocument[3])
    }

    private static func zip2min(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case (let a?, let b?): min(a, b)
        default: a ?? b
        }
    }

    static func joinFragments(_ a: String, _ b: String) -> String {
        guard let last = a.last, let first = b.first else { return a + b }
        func cjk(_ c: Character) -> Bool {
            c.unicodeScalars.contains {
                (0x3000...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value)
            }
        }
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
            let observations = raw.observations.map { source -> RawObservation in
                var observation = source
                observation.box = observation.box.offsetBy(dx: tile.minX, dy: tile.minY)
                observation.quad = observation.quad?.map { CGPoint(x: $0.x + tile.minX, y: $0.y + tile.minY) }
                observation.lines = observation.lines?.map { $0.offsetBy(dx: tile.minX, dy: tile.minY) }
                return observation
            }
            var blocks: [Int: Int] = [:]
            var cellOffsets: [Int: (row: Int, column: Int)] = [:]
            for (index, source) in raw.blocks.enumerated() {
                var block = source
                block.box = block.box.offsetBy(dx: tile.minX, dy: tile.minY)
                block.parentIndex = source.parentIndex.flatMap { blocks[$0] }
                if case .table = block.kind,
                   let match = tableMatch(for: index, observations: observations, merged: merged) {
                    blocks[index] = match.index
                    cellOffsets[index] = (match.row, match.column)
                    merged.blocks[match.index].box = merged.blocks[match.index].box.union(block.box)
                } else {
                    blocks[index] = merged.blocks.count
                    merged.blocks.append(block)
                }
            }
            for var observation in observations {
                let source = observation.blockIndex
                observation.blockIndex = source.flatMap { blocks[$0] }
                if let offset = source.flatMap({ cellOffsets[$0] }), let ref = observation.kind.tableCell {
                    let shifted = TableCellRef(
                        table: ref.table, row: ref.row + offset.row, column: ref.column + offset.column,
                        rowSpan: ref.rowSpan, columnSpan: ref.columnSpan, isHeader: ref.isHeader
                    )
                    guard shifted.hasValidBounds else { continue }
                    observation.kind = .tableCell(shifted)
                }
                if !merged.observations.contains(where: { overlaps($0, observation) }) { merged.observations.append(observation) }
            }
            merged.languages += raw.languages.filter { !merged.languages.contains($0) }
        }
        for index in merged.blocks.indices {
            guard case .table = merged.blocks[index].kind else { continue }
            let cells = merged.observations.filter { $0.blockIndex == index }.compactMap(\.kind.tableCell).filter(\.hasValidBounds)
            merged.blocks[index].kind = .table(
                rows: cells.map { $0.row + $0.rowSpan }.max() ?? 0, columns: cells.map { $0.column + $0.columnSpan }.max() ?? 0
            )
        }
        return merged
    }

    private static func overlaps(_ a: RawObservation, _ b: RawObservation) -> Bool {
        a.text == b.text && (a.box.intersection(b.box)?.area ?? 0) > 0.3 * min(a.box.area, b.box.area)
    }

    private static func tableMatch(
        for index: Int, observations: [RawObservation], merged: RawRecognition
    ) -> (index: Int, row: Int, column: Int)? {
        let cells = observations.filter { $0.blockIndex == index }
        for cell in cells {
            guard let ref = cell.kind.tableCell, ref.hasValidBounds else { continue }
            if let previous = merged.observations.first(where: { $0.kind.tableCell?.hasValidBounds == true && overlaps($0, cell) }),
               let index = previous.blockIndex, let old = previous.kind.tableCell {
                let row = old.row - ref.row, column = old.column - ref.column
                guard cells.allSatisfy({ ($0.kind.tableCell?.row ?? 0) + row >= 0 && ($0.kind.tableCell?.column ?? 0) + column >= 0 })
                else { return nil }
                return (index, row, column)
            }
        }
        return nil
    }

}
