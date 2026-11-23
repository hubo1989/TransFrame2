import Foundation

// MARK: - TranslationJob (SPEC §02 §8)

public enum TextPurpose: String, Sendable, Codable, Hashable { case popup, insert }

public enum TranslationSource: Sendable, Equatable {
    case analysis(SessionID, AnalysisResultID)
    case plainText(purpose: TextPurpose)

    public var historyKind: HistoryKind {
        switch self {
        case .analysis: .screenshotTranslation
        case .plainText(.popup): .textTranslation
        case .plainText(.insert): .insertTranslation
        }
    }
}

public enum EngineRouting: Sendable, Equatable, Hashable {
    /// 1...5 engines tried in order.
    case ordered([EngineID])
    /// 2...4 engines in parallel.
    case compare([EngineID])

    public var engines: [EngineID] {
        switch self {
        case .ordered(let ids), .compare(let ids): ids
        }
    }
    public var isCompare: Bool { if case .compare = self { true } else { false } }

    public static let maxOrdered = 5
    public static let compareRange = 2...4

    public var isValid: Bool {
        switch self {
        case .ordered(let ids): (1...Self.maxOrdered).contains(ids.count) && Set(ids).count == ids.count
        case .compare(let ids): Self.compareRange.contains(ids.count) && Set(ids).count == ids.count
        }
    }
}

public enum TranslationScene: String, Sendable, Codable, Hashable, CaseIterable {
    case screenshot, textSelection, translateAndInsert
}

public struct PromptSnapshot: Sendable, Equatable, Hashable {
    public let template: String
    public let digest: String
    public init(template: String, digest: String) {
        self.template = template
        self.digest = digest
    }
}

public struct TranslationUnit: Sendable, Equatable, Hashable {
    public let id: SegmentID
    public let text: String
    public let kind: SegmentKind

    public init(id: SegmentID = SegmentID(), text: String, kind: SegmentKind = .text) {
        self.id = id
        self.text = text
        self.kind = kind
    }
}

public struct TranslationJob: Sendable {
    public let operation: OperationID
    public let source: TranslationSource
    public let units: [TranslationUnit]
    public let from: LanguageCode?
    public let to: LanguageCode
    public let routing: EngineRouting
    public let prompt: PromptSnapshot?
    public let glossary: GlossarySnapshot?
    public let context: TranslationContext?
    public let tone: ToneStyle?
    public let cache: CachePolicy

    public init(
        operation: OperationID = OperationID(), source: TranslationSource, units: [TranslationUnit],
        from: LanguageCode?, to: LanguageCode, routing: EngineRouting, prompt: PromptSnapshot? = nil,
        glossary: GlossarySnapshot? = nil, context: TranslationContext? = nil, tone: ToneStyle? = nil,
        cache: CachePolicy = .normal
    ) {
        self.operation = operation
        self.source = source
        self.units = units
        self.from = from
        self.to = to
        self.routing = routing
        self.prompt = prompt
        self.glossary = glossary
        self.context = context
        self.tone = tone
        self.cache = cache
    }
}

/// What an engine adapter receives. Already passed through the privacy guard.
public struct TranslationBatch: Sendable, Equatable {
    public let units: [TranslationUnit]
    public let from: LanguageCode?
    public let to: LanguageCode
    public let prompt: PromptSnapshot?
    public let glossary: [GlossaryEntry]
    public let context: TranslationContext?
    public let tone: ToneStyle?

    public init(
        units: [TranslationUnit], from: LanguageCode?, to: LanguageCode, prompt: PromptSnapshot? = nil,
        glossary: [GlossaryEntry] = [], context: TranslationContext? = nil, tone: ToneStyle? = nil
    ) {
        self.units = units
        self.from = from
        self.to = to
        self.prompt = prompt
        self.glossary = glossary
        self.context = context
        self.tone = tone
    }
}

public struct TranslatedUnit: Sendable, Equatable {
    public let id: SegmentID
    public let text: String?
    public let detectedSource: LanguageCode?

    public init(id: SegmentID, text: String?, detectedSource: LanguageCode? = nil) {
        self.id = id
        self.text = text
        self.detectedSource = detectedSource
    }
}

// MARK: - Results

public enum SegmentFailure: String, Sendable, Codable, Equatable {
    case missingInResponse, emptyOutput, invalidOutput, withheldByPrivacyGuard
}

public enum SegmentStatus: Sendable, Codable, Equatable {
    case translated
    case sameLanguageSkipped
    case keptOriginal(KeepReason)
    case failed(SegmentFailure)
    case cancelled
}

public struct BilingualSegment: Sendable, Codable, Identifiable, Equatable {
    public let id: SegmentID
    public let source: String
    public let translated: String?
    public let status: SegmentStatus
    public let from: LanguageCode?
    public let to: LanguageCode
    public let glossaryHits: [GlossaryEntryID]

    public init(
        id: SegmentID, source: String, translated: String?, status: SegmentStatus, from: LanguageCode?,
        to: LanguageCode, glossaryHits: [GlossaryEntryID] = []
    ) {
        self.id = id
        self.source = source
        self.translated = status == .translated ? translated : nil
        self.status = status
        self.from = from
        self.to = to
        self.glossaryHits = glossaryHits
    }

    /// What to display: the translation when present, otherwise the source.
    public var displayText: String { translated ?? source }
}

public enum SkipReason: String, Sendable, Codable, Equatable {
    case unconfigured, unavailableOnThisOS, instanceDeleted
}

public struct EngineResult: Sendable, Identifiable, Equatable {
    public let id: EngineID
    public let segments: [BilingualSegment]
    public let error: AppError?
    public let skipped: SkipReason?
    public let duration: Duration
    public let fromCache: Bool

    public init(
        id: EngineID, segments: [BilingualSegment] = [], error: AppError? = nil, skipped: SkipReason? = nil,
        duration: Duration = .zero, fromCache: Bool = false
    ) {
        self.id = id
        self.segments = segments
        self.error = error
        self.skipped = skipped
        self.duration = duration
        self.fromCache = fromCache
    }

    public var succeeded: Bool { error == nil && skipped == nil && !segments.isEmpty }
}

public struct TranslationOutcome: Sendable, Equatable {
    public let operation: OperationID
    public let routing: EngineRouting
    public let results: [EngineResult]
    public var effective: EngineID?
    public var target: LanguageCode?
    public var privacy: PrivacyReport?

    public init(
        operation: OperationID, routing: EngineRouting, results: [EngineResult], effective: EngineID?,
        target: LanguageCode? = nil, privacy: PrivacyReport? = nil
    ) {
        self.operation = operation
        self.routing = routing
        self.results = results
        self.effective = effective
        self.target = target
        self.privacy = privacy
    }

    public var effectiveResult: EngineResult? { results.first { $0.id == effective } }
}

public enum TranslationEvent: Sendable {
    case engineStarted(EngineID)
    case engineFinished(EngineResult)
    case finished(TranslationOutcome)
}

// MARK: - Languages (SPEC §03 TRN-14: 29 languages plus automatic)

public enum TranslationLanguages {
    public static let all: [LanguageCode] = [
        "en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es", "it", "pt", "ru", "ar", "hi", "th", "vi",
        "nl", "pl", "tr", "uk", "cs", "sv", "da", "fi", "no", "el", "he", "id", "ms", "ro",
    ].map(LanguageCode.init)
}

public enum TargetLanguage: Sendable, Codable, Equatable, Hashable {
    case followSystem
    case specific(LanguageCode)

    /// Resolves against the system's preferred languages; falls back to English.
    public func resolved(preferred: [String]) -> LanguageCode {
        switch self {
        case .specific(let code): return code
        case .followSystem:
            for identifier in preferred {
                let candidate = LanguageCode(identifier)
                if let match = TranslationLanguages.all.first(where: { $0.isSameLanguage(as: candidate) }) { return match }
            }
            return .english
        }
    }
}
