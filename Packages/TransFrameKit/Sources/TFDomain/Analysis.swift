import CoreGraphics
import Foundation

// MARK: - AnalysisRequest / AnalysisResult (SPEC §02 §7)

public enum AnalysisInputPolicy: String, Sendable, Codable, Hashable {
    /// Crop + all redactions burned in (default; the only policy allowed for outbound requests).
    case safe
    /// Crop of the base image without annotations (local engines only).
    case original
    /// What the user sees: base + decorations + redactions.
    case asDisplayed
}

public enum AnalysisDetail: String, Sendable, Codable, Hashable { case lines, structured }
public enum CachePolicy: String, Sendable, Codable, Hashable { case normal, forceRefresh }

public struct AnalysisRequest: Sendable {
    public let operation: OperationID
    public let session: SessionID
    public let inputRevision: Int
    /// nil means the current crop; must lie inside the crop.
    public let region: DocumentRect?
    public let input: AnalysisInputPolicy
    public let engine: EngineID
    public let languageHints: [LanguageCode]
    public let detail: AnalysisDetail
    public let cache: CachePolicy

    public init(
        operation: OperationID = OperationID(), session: SessionID, inputRevision: Int, region: DocumentRect? = nil,
        input: AnalysisInputPolicy = .safe, engine: EngineID, languageHints: [LanguageCode] = [],
        detail: AnalysisDetail = .lines, cache: CachePolicy = .normal
    ) {
        self.operation = operation
        self.session = session
        self.inputRevision = inputRevision
        self.region = region
        self.input = input
        self.engine = engine
        self.languageHints = languageHints
        self.detail = detail
        self.cache = cache
    }
}

public enum SentPayload: String, Sendable, Codable, Equatable { case nothing, image, text }

public struct Provenance: Sendable, Codable, Equatable {
    public let engine: EngineID
    public let configDigest: String
    public let locality: EngineLocality
    public var fromCache: Bool
    public let fallbackFrom: EngineID?
    public let duration: Duration
    public let sent: SentPayload
    public let privacy: PrivacyReport?

    public init(
        engine: EngineID, configDigest: String, locality: EngineLocality, fromCache: Bool = false,
        fallbackFrom: EngineID? = nil, duration: Duration, sent: SentPayload, privacy: PrivacyReport? = nil
    ) {
        self.engine = engine
        self.configDigest = configDigest
        self.locality = locality
        self.fromCache = fromCache
        self.fallbackFrom = fallbackFrom
        self.duration = duration
        self.sent = sent
        self.privacy = privacy
    }
}

public struct AnalysisResult: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: AnalysisResultID
    public let session: SessionID
    public let inputRevision: Int
    public let inputFingerprint: ContentHash
    public let region: DocumentRect
    /// Array order is reading order.
    public var segments: [TextSegment]
    public let blocks: [ContentBlock]
    public var excluded: [ExcludedSegment]
    public let languages: [LanguageCode]
    public var provenance: Provenance

    public init(
        schemaVersion: Int = AnalysisResult.currentSchemaVersion, id: AnalysisResultID = AnalysisResultID(),
        session: SessionID, inputRevision: Int, inputFingerprint: ContentHash, region: DocumentRect,
        segments: [TextSegment], blocks: [ContentBlock] = [], excluded: [ExcludedSegment] = [],
        languages: [LanguageCode] = [], provenance: Provenance
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.session = session
        self.inputRevision = inputRevision
        self.inputFingerprint = inputFingerprint
        self.region = region
        self.segments = segments
        self.blocks = blocks
        self.excluded = excluded
        self.languages = languages
        self.provenance = provenance
    }

    public var isEmpty: Bool { segments.isEmpty }
    public func segment(_ id: SegmentID) -> TextSegment? { segments.first { $0.id == id } }
    public func block(_ id: BlockID) -> ContentBlock? { blocks.first { $0.id == id } }

    /// Plain text in reading order using revised text where present.
    public var plainText: String { segments.map(\.effectiveText).joined(separator: "\n") }
}

// MARK: - TextSegment (SPEC §02 §7.1)

public struct LineFragment: Sendable, Codable, Equatable, Hashable {
    public let box: DocumentRect
    /// UTF-16 range inside the segment text.
    public let range: Range<Int>

    public init(box: DocumentRect, range: Range<Int>) {
        self.box = box
        self.range = range
    }
}

public enum RenderTextAlignment: String, Sendable, Codable, Equatable, Hashable { case leading, center, trailing }

public struct SegmentStyleHint: Sendable, Codable, Equatable, Hashable {
    /// Estimated font size in document pixels.
    public let fontSize: Double?
    public let foreground: RGBA?
    public let background: RGBA?
    public let alignment: RenderTextAlignment?

    public init(fontSize: Double? = nil, foreground: RGBA? = nil, background: RGBA? = nil, alignment: RenderTextAlignment? = nil) {
        self.fontSize = fontSize
        self.foreground = foreground
        self.background = background
        self.alignment = alignment
    }
}

public enum KeepReason: String, Sendable, Codable, Equatable, Hashable {
    case formula, code, numeric, identifier, userLocked
}

public enum Translatability: Sendable, Codable, Equatable, Hashable {
    case translate
    case keepOriginal(KeepReason)

    public var isTranslatable: Bool { self == .translate }
}

public struct TableCellRef: Sendable, Codable, Equatable, Hashable {
    public let table: BlockID
    public let row: Int
    public let column: Int
    public let rowSpan: Int
    public let columnSpan: Int
    public let isHeader: Bool

    public var hasValidBounds: Bool {
        (0..<512).contains(row) && (0..<128).contains(column) &&
            (1...(512 - row)).contains(rowSpan) && (1...(128 - column)).contains(columnSpan)
    }

    public init(table: BlockID, row: Int, column: Int, rowSpan: Int = 1, columnSpan: Int = 1, isHeader: Bool = false) {
        self.table = table
        self.row = row
        self.column = column
        self.rowSpan = max(rowSpan, 1)
        self.columnSpan = max(columnSpan, 1)
        self.isHeader = isHeader
    }
}

public enum SegmentKind: Sendable, Codable, Equatable, Hashable {
    case text
    case heading(level: Int)
    case listItem(level: Int, marker: String?)
    case tableCell(TableCellRef)
    case formula(latex: String?)
    case code(language: String?)
    case handwriting
    case caption

    public var isFormula: Bool { if case .formula = self { true } else { false } }
    public var isCode: Bool { if case .code = self { true } else { false } }
    public var tableCell: TableCellRef? { if case .tableCell(let ref) = self { ref } else { nil } }
}

public struct TextSegment: Sendable, Codable, Identifiable, Equatable, Hashable {
    public let id: SegmentID
    public let kind: SegmentKind
    public let text: String
    public var revisedText: String?
    public let box: DocumentRect
    public let quad: Quad?
    public let lines: [LineFragment]?
    public let confidence: Double?
    public let language: LanguageCode?
    public let parent: BlockID?
    public let translatability: Translatability
    public let style: SegmentStyleHint?

    public init(
        id: SegmentID = SegmentID(), kind: SegmentKind = .text, text: String, revisedText: String? = nil,
        box: DocumentRect, quad: Quad? = nil, lines: [LineFragment]? = nil, confidence: Double? = nil,
        language: LanguageCode? = nil, parent: BlockID? = nil, translatability: Translatability = .translate,
        style: SegmentStyleHint? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.revisedText = revisedText
        self.box = box
        self.quad = quad
        self.lines = lines
        self.confidence = confidence
        self.language = language
        self.parent = parent
        self.translatability = translatability
        self.style = style
    }

    public var effectiveText: String { revisedText ?? text }

    public func with(revisedText: String?) -> TextSegment {
        var copy = self
        copy.revisedText = revisedText
        return copy
    }
}

public enum BlockKind: Sendable, Codable, Equatable, Hashable {
    case paragraph
    case table(rows: Int, columns: Int)
    case list(ordered: Bool)
    case codeBlock
    case formulaBlock
    case figure
    case handwriting
}

public enum BlockChild: Sendable, Codable, Equatable, Hashable {
    case block(BlockID)
    case segment(SegmentID)
}

public struct ContentBlock: Sendable, Codable, Identifiable, Equatable, Hashable {
    public let id: BlockID
    public let kind: BlockKind
    public let box: DocumentRect
    public let parent: BlockID?
    public let children: [BlockChild]

    public init(id: BlockID = BlockID(), kind: BlockKind, box: DocumentRect, parent: BlockID? = nil, children: [BlockChild] = []) {
        self.id = id
        self.kind = kind
        self.box = box
        self.parent = parent
        self.children = children
    }
}

public enum ExclusionReason: String, Sendable, Codable, Equatable, Hashable {
    case noise, promptLeakage, lowConfidence, duplicate, userHidden
}

public struct ExcludedSegment: Sendable, Codable, Equatable, Hashable {
    public let segment: TextSegment
    public let reason: ExclusionReason

    public init(segment: TextSegment, reason: ExclusionReason) {
        self.segment = segment
        self.reason = reason
    }
}

// MARK: - Structure validation (SPEC §02 §7.1 "二者必须一致")

public enum StructureValidation {
    public enum Issue: Sendable, Equatable {
        case missingParent(SegmentID)
        case parentMismatch(SegmentID)
        case unknownChild(BlockID)
        case readingOrderMismatch
    }

    /// Checks parent/children consistency and that depth-first traversal matches `segments` order.
    public static func issues(segments: [TextSegment], blocks: [ContentBlock]) -> [Issue] {
        guard !blocks.isEmpty else { return segments.filter { $0.parent != nil }.map { .missingParent($0.id) } }
        var issues: [Issue] = []
        let blockByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        let segmentIDs = Set(segments.map(\.id))
        var childOwner: [SegmentID: BlockID] = [:]
        for block in blocks {
            for child in block.children {
                switch child {
                case .segment(let sid):
                    childOwner[sid] = block.id
                    if !segmentIDs.contains(sid) { issues.append(.unknownChild(block.id)) }
                case .block(let bid):
                    if blockByID[bid] == nil { issues.append(.unknownChild(block.id)) }
                }
            }
        }
        for segment in segments {
            guard let parent = segment.parent else {
                if childOwner[segment.id] != nil { issues.append(.parentMismatch(segment.id)) }
                continue
            }
            if blockByID[parent] == nil {
                issues.append(.missingParent(segment.id))
            } else if childOwner[segment.id] != parent {
                issues.append(.parentMismatch(segment.id))
            }
        }
        var order: [SegmentID] = []
        func visit(_ block: ContentBlock) {
            for child in block.children {
                switch child {
                case .segment(let sid): order.append(sid)
                case .block(let bid): if let b = blockByID[bid] { visit(b) }
                }
            }
        }
        for root in blocks where root.parent == nil { visit(root) }
        let structured = segments.filter { $0.parent != nil }.map(\.id)
        if order != structured { issues.append(.readingOrderMismatch) }
        return issues
    }
}

// MARK: - Raw engine output (SPEC §02 §10.1)

/// One observation from an engine adapter. Coordinates are pixels of the image handed to the engine.
public struct RawObservation: Sendable, Equatable {
    public var text: String
    public var box: FrameRect
    public var quad: [CGPoint]?
    public var confidence: Double?
    public var language: LanguageCode?
    public var kind: SegmentKind
    /// Index into `RawRecognition.blocks`.
    public var blockIndex: Int?
    public var lines: [FrameRect]?
    public var style: SegmentStyleHint?

    public init(
        text: String, box: FrameRect, quad: [CGPoint]? = nil, confidence: Double? = nil, language: LanguageCode? = nil,
        kind: SegmentKind = .text, blockIndex: Int? = nil, lines: [FrameRect]? = nil, style: SegmentStyleHint? = nil
    ) {
        self.text = text
        self.box = box
        self.quad = quad
        self.confidence = confidence
        self.language = language
        self.kind = kind
        self.blockIndex = blockIndex
        self.lines = lines
        self.style = style
    }
}

public enum RawBlockKind: Sendable, Equatable {
    case paragraph, table(rows: Int, columns: Int), list(ordered: Bool), codeBlock, formulaBlock, figure, handwriting
}

public struct RawBlock: Sendable, Equatable {
    public var kind: RawBlockKind
    public var box: FrameRect
    public var parentIndex: Int?

    public init(kind: RawBlockKind, box: FrameRect, parentIndex: Int? = nil) {
        self.kind = kind
        self.box = box
        self.parentIndex = parentIndex
    }
}

public struct RawRecognition: Sendable, Equatable {
    public var observations: [RawObservation]
    public var blocks: [RawBlock]
    public var languages: [LanguageCode]
    /// What the adapter actually sent off-device.
    public var sent: SentPayload

    public init(observations: [RawObservation], blocks: [RawBlock] = [], languages: [LanguageCode] = [], sent: SentPayload = .nothing) {
        self.observations = observations
        self.blocks = blocks
        self.languages = languages
        self.sent = sent
    }
}
