import CoreGraphics
import Foundation

// MARK: - Smart actions (SPEC §02 §11.1)

public enum SmartActionKind: Sendable, Equatable, Hashable {
    case copyTableAsMarkdown, copyTableAsCSV
    case copyFormulaAsLaTeX
    case copyCode
    case openLink(URL), composeEmail(String), openQRCode(URL)
    case addEvent(DateInterval)
}

public enum SmartActionTarget: Sendable, Equatable, Hashable {
    case block(BlockID)
    case segments([SegmentID])
    case session
}

public struct SmartAction: Sendable, Identifiable, Equatable, Hashable {
    public let id: String
    public let kind: SmartActionKind
    public let target: SmartActionTarget
    /// Empty means purely local.
    public let requires: Set<EngineRole>
    /// Text payload produced locally (Markdown, CSV, LaTeX or code) for copy actions.
    public let payload: String?

    public init(id: String, kind: SmartActionKind, target: SmartActionTarget, requires: Set<EngineRole> = [], payload: String? = nil) {
        self.id = id
        self.kind = kind
        self.target = target
        self.requires = requires
        self.payload = payload
    }
}

// MARK: - Smart selection (SPEC §02 §11.2)

public struct SelectionCandidate: Sendable, Identifiable, Equatable {
    public let id: BlockID
    public let kind: BlockKind
    public let rect: QuartzRect
    /// 0...1, used for ordering.
    public let score: Double

    public init(id: BlockID = BlockID(), kind: BlockKind, rect: QuartzRect, score: Double) {
        self.id = id
        self.kind = kind
        self.rect = rect
        self.score = score
    }
}

// MARK: - Glossary and context (SPEC §02 §11.3)

public enum GlossaryScope: Sendable, Codable, Equatable, Hashable {
    case global
    case app(bundleID: String)
}

public struct GlossaryEntry: Sendable, Codable, Identifiable, Equatable, Hashable {
    public let id: GlossaryEntryID
    public let source: String
    public let target: String
    public let from: LanguageCode?
    public let to: LanguageCode
    public let caseSensitive: Bool
    public let scope: GlossaryScope

    public init(
        id: GlossaryEntryID = GlossaryEntryID(), source: String, target: String, from: LanguageCode? = nil,
        to: LanguageCode, caseSensitive: Bool = false, scope: GlossaryScope = .global
    ) {
        self.id = id
        self.source = source
        self.target = target
        self.from = from
        self.to = to
        self.caseSensitive = caseSensitive
        self.scope = scope
    }
}

public struct GlossarySnapshot: Sendable, Equatable, Hashable {
    public let version: Int
    public let matched: [GlossaryEntry]
    public init(version: Int, matched: [GlossaryEntry]) {
        self.version = version
        self.matched = matched
    }
}

public struct TranslationContext: Sendable, Equatable, Hashable {
    public let appName: String?
    public let windowTitle: String?
    public init(appName: String?, windowTitle: String?) {
        self.appName = appName
        self.windowTitle = windowTitle
    }
}

// MARK: - Generation and embedding (SPEC §02 §11.4)

public enum ToneStyle: String, Sendable, Codable, CaseIterable, Hashable { case formal, casual, concise }

public enum GenerationTask: Sendable, Equatable {
    case rewrite(ToneStyle)
    case polish
    case suggestFileName
    case structureRepair
}

public struct GenerationRequest: Sendable {
    public let task: GenerationTask
    public let input: String
    public let image: PixelImage?
    public let maxOutputCharacters: Int
    public init(task: GenerationTask, input: String, image: PixelImage? = nil, maxOutputCharacters: Int = 2000) {
        self.task = task
        self.input = input
        self.image = image
        self.maxOutputCharacters = maxOutputCharacters
    }
}

// MARK: - Privacy guard (SPEC §02 §11.5)

public enum SensitiveCategory: String, Sendable, Codable, CaseIterable, Hashable {
    case apiKey, paymentCard, nationalID, privateKey, password, email, phone

    /// Auto-redacted by default (high confidence categories).
    public static let defaultRedacted: Set<SensitiveCategory> = [.apiKey, .paymentCard, .nationalID, .privateKey, .password]
    /// Hinted but not redacted by default.
    public static let defaultHintOnly: Set<SensitiveCategory> = [.email, .phone]
}

public struct SensitiveFinding: Sendable, Equatable {
    public let category: SensitiveCategory
    public let box: FrameRect
    public let confidence: Double
    public init(category: SensitiveCategory, box: FrameRect, confidence: Double) {
        self.category = category
        self.box = box
        self.confidence = confidence
    }
}

public struct PrivacyReport: Sendable, Codable, Equatable, Hashable {
    public let applied: Bool
    public let redactedCount: Int
    public let categories: [SensitiveCategory]
    public let overriddenByUser: Bool
    /// Hint-only findings (e.g. email, phone) that were sent unchanged.
    public let hintedCount: Int

    public init(applied: Bool, redactedCount: Int, categories: [SensitiveCategory], overriddenByUser: Bool = false, hintedCount: Int = 0) {
        self.applied = applied
        self.redactedCount = redactedCount
        self.categories = categories
        self.overriddenByUser = overriddenByUser
        self.hintedCount = hintedCount
    }

    public static let notApplied = PrivacyReport(applied: false, redactedCount: 0, categories: [])
}

/// Pure derivation of smart actions from a recognition result (SPEC §02 §11.1).
public protocol SmartActionDeriving: Sendable {
    func actions(for result: AnalysisResult) -> [SmartAction]
}
