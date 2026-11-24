import CoreGraphics
import Foundation

// MARK: - Workflow protocols implemented by TFPipelines, called by Features (SPEC §02 §10.2)
// Configuration enters through parameters (a SettingsSnapshot frozen when the request starts).

public protocol CaptureWorkflow: Sendable {
    /// One-shot freeze of every display (CAP-01). Records P-01/P-02/P-03 samples.
    func freeze(_ request: CaptureRequest) async throws(AppError) -> FrozenFrameSet
    /// Local content-block candidates for smart selection (AI-03); empty on failure.
    func contentBlocks(in frames: FrozenFrameSet) async -> [SelectionCandidate]
}

public protocol SessionManaging: Sendable {
    func create(from frames: FrozenFrameSet, selection: SelectionGeometry) async throws(AppError) -> SessionID
    func create(importing image: PixelImage, name: String) async -> SessionID
    func snapshot(of id: SessionID) async throws(AppError) -> DocumentSession
    func snapshots(of id: SessionID) async -> AsyncStream<DocumentSession>
    func apply(_ transaction: EditTransaction, to id: SessionID) async throws(AppError)
    func undo(_ id: SessionID) async -> Bool
    func redo(_ id: SessionID) async -> Bool
    func canUndo(_ id: SessionID) async -> Bool
    func canRedo(_ id: SessionID) async -> Bool
    func markSaved(_ id: SessionID, revision: Int) async
    func retain(_ id: SessionID, by owner: SessionOwner) async
    func release(_ id: SessionID, by owner: SessionOwner) async
}

public protocol RecognitionWorkflow: Sendable {
    func recognize(_ request: AnalysisRequest, settings: SettingsSnapshot) async throws(AppError) -> AnalysisResult
}

public protocol TranslationWorkflow: Sendable {
    func translate(_ job: TranslationJob, settings: SettingsSnapshot) -> AsyncThrowingStream<TranslationEvent, any Error>
}

public protocol RenderWorkflow: Sendable {
    func plan(for id: SessionID, purpose: RenderPurpose) async throws(AppError) -> RenderPlan
    func image(for id: SessionID, purpose: RenderPurpose) async throws(AppError) -> PixelImage
    /// Screen plan without the annotations being dragged (they are drawn as a live draft).
    func plan(for id: SessionID, purpose: RenderPurpose, excluding: Set<AnnotationID>) async throws(AppError) -> RenderPlan
    /// Plan of a snapshot the caller already holds, so a canvas draws exactly the revision it shows.
    func plan(of session: DocumentSession, purpose: RenderPurpose, excluding: Set<AnnotationID>) throws(AppError) -> RenderPlan
    /// Draws a plan into a context; the same executor as export (ADR-0006).
    func draw(_ plan: RenderPlan, base: PixelImage, in context: CGContext)
}

public struct SaveReceipt: Sendable, Equatable {
    public let url: URL
    /// Name source, shown in the save toast (AI-07).
    public let usedSuggestedName: Bool
    public init(url: URL, usedSuggestedName: Bool) {
        self.url = url
        self.usedSuggestedName = usedSuggestedName
    }
}

public protocol ExportWorkflow: Sendable {
    func copyImage(of id: SessionID, settings: SettingsSnapshot) async throws(AppError)
    func save(_ id: SessionID, as format: ExportFormat?, settings: SettingsSnapshot) async throws(AppError) -> SaveReceipt
    func upload(_ id: SessionID, settings: SettingsSnapshot) async throws(AppError) -> UploadReceipt
}

// MARK: Document pipeline (recognize / translate actions on a session)

public enum DocumentPipelineStage: String, Sendable, Equatable { case preparing, scanningPrivacy, recognizing, translating }

public enum DocumentPipelineEvent: Sendable {
    case stage(DocumentPipelineStage)
    case recognized(AnalysisResult)
    case privacy(PrivacyReport)
    case translation(TranslationEvent)
    case finished
}

public struct DocumentPipelineOptions: Sendable {
    public let settings: SettingsSnapshot
    /// Overrides the configured target language (EDT-13 / INP-11 quick switch).
    public let target: LanguageCode?
    public let cache: CachePolicy
    /// The user undid the privacy guard and asked to resend the original (ADR-0010 §8).
    public let overridePrivacyGuard: Bool

    public init(settings: SettingsSnapshot, target: LanguageCode? = nil, cache: CachePolicy = .normal, overridePrivacyGuard: Bool = false) {
        self.settings = settings
        self.target = target
        self.cache = cache
        self.overridePrivacyGuard = overridePrivacyGuard
    }
}

public protocol DocumentPipelineWorkflow: Sendable {
    /// "Recognize": runs the OCR engine on the safe input and writes the result into the session.
    func recognize(_ id: SessionID, options: DocumentPipelineOptions) -> AsyncThrowingStream<DocumentPipelineEvent, any Error>
    /// "Translate": analysis engine → translation routing → session → history.
    func translate(_ id: SessionID, options: DocumentPipelineOptions) -> AsyncThrowingStream<DocumentPipelineEvent, any Error>
    func cancel(_ id: SessionID) async
    /// Compare mode: switch the viewed engine without re-translating (TRN-08 / EDT-11).
    func selectEffectiveEngine(_ engine: EngineID, in id: SessionID) async throws(AppError)
    func smartActions(for id: SessionID) async -> [SmartAction]
    /// Smart mosaic: local detection (optionally cloud-enhanced), adds privacy mosaics in one transaction.
    func smartMosaic(_ id: SessionID, settings: SettingsSnapshot) async throws(AppError) -> Int
    /// Restores an excluded segment (OCR-13).
    func restoreExcluded(_ segment: SegmentID, in id: SessionID) async throws(AppError)
}

// MARK: Text translation (SPEC §03 §9)

public struct TextTranslationResult: Sendable, Equatable {
    public let source: String
    public let outcome: TranslationOutcome
    public let from: LanguageCode?
    public let to: LanguageCode
    public let anchor: QuartzRect?
    public init(source: String, outcome: TranslationOutcome, from: LanguageCode?, to: LanguageCode, anchor: QuartzRect?) {
        self.source = source
        self.outcome = outcome
        self.from = from
        self.to = to
        self.anchor = anchor
    }
}

public enum InsertProgress: Sendable, Equatable {
    case capturing
    case captured(anchor: QuartzRect?)
    case translating
    case inserting
    case inserted(InsertionMethod)
    /// Insertion failed; the translation was put on the clipboard (TXT-09).
    case copiedToClipboard(AppError)
}

public protocol TextTranslationWorkflow: Sendable {
    func canPolish(settings: SettingsSnapshot) async -> Bool
    func translateSelection(settings: SettingsSnapshot) async throws(AppError) -> TextTranslationResult
    func translate(text: String, anchor: QuartzRect?, settings: SettingsSnapshot) async throws(AppError) -> TextTranslationResult
    func translateAndInsert(tone: ToneStyle?, polishOnly: Bool, settings: SettingsSnapshot) -> AsyncThrowingStream<InsertProgress, any Error>
}

public extension TextTranslationWorkflow {
    func canPolish(settings: SettingsSnapshot) async -> Bool { false }
}

// MARK: History (SPEC §02 §10.2)

public protocol HistoryWorkflow: Sendable {
    func page(_ query: HistoryQuery) async throws(AppError) -> HistoryPage
    func search(semantic text: String, query: HistoryQuery, limit: Int) async throws(AppError) -> HistoryPage
    func setFavorite(_ id: HistoryEntryID, _ on: Bool) async throws(AppError)
    func remove(_ ids: [HistoryEntryID]) async throws(AppError)
    func clear(_ scope: HistoryScope) async throws(AppError)
    func export(_ query: HistoryQuery, as format: HistoryExportFormat, to url: URL) async throws(AppError)
    func record(_ entry: HistoryEntry, settings: SettingsSnapshot) async
    func notice() async -> HistoryStoreNotice?
}

public protocol ColorPickWorkflow: Sendable {
    /// System picker → copy HEX → color history (COL-01). nil when cancelled.
    func pickAndCopy(settings: SettingsSnapshot) async throws(AppError) -> RGBA?
    /// Colors picked inside the annotation toolbar: history only, clipboard untouched (COL-11).
    func pickForAnnotation(settings: SettingsSnapshot) async -> RGBA?
    func copy(_ color: RGBA, format: ColorCopyFormat) async throws(AppError)
}

public enum ColorCopyFormat: String, Sendable, Codable, CaseIterable { case hex, rgb

    public func string(for color: RGBA) -> String { self == .hex ? color.hexString : color.rgbString }
}

// MARK: Glossary (AI-04)

public protocol GlossaryWorkflow: Sendable {
    func entries() async throws(AppError) -> [GlossaryEntry]
    func save(_ entry: GlossaryEntry) async throws(AppError)
    func remove(_ id: GlossaryEntryID) async throws(AppError)
    /// "Correct and remember": stores the user's correction as a fixed translation and updates the session.
    func correct(
        _ segment: SegmentID, in id: SessionID, expectedOperation: OperationID, translation: String, remember: Bool
    ) async throws(AppError)
}

// MARK: Scroll capture (N-09)

public enum ScrollCaptureEvent: Sendable, Equatable {
    case progress(height: Int)
    case reachedLimit
}

public protocol ScrollCaptureWorkflow: Sendable {
    func begin(_ rect: QuartzRect, excluding: Set<WindowID>) async throws(AppError) -> AsyncStream<ScrollCaptureEvent>
    func finish() async throws(AppError) -> SessionID
    func cancel() async
}

// MARK: Engine catalog (settings pages)

/// One model's result in the settings speed test: the full response time of a small fixed translation.
public struct ModelSpeedResult: Sendable, Equatable, Identifiable {
    public enum Outcome: Sendable, Equatable {
        case success(duration: Duration, sample: String)
        case failure(AppError)
    }

    public let model: String
    public let outcome: Outcome
    public var id: String { model }

    public init(model: String, outcome: Outcome) {
        self.model = model
        self.outcome = outcome
    }

    public var duration: Duration? {
        if case .success(let duration, _) = outcome { return duration }
        return nil
    }

    /// Successes fastest first, then failures in their original order.
    public static func ranked(_ results: [ModelSpeedResult]) -> [ModelSpeedResult] {
        let ok = results.filter { $0.duration != nil }.sorted { ($0.duration ?? .zero) < ($1.duration ?? .zero) }
        return ok + results.filter { $0.duration == nil }
    }
}

public protocol EngineCatalogProviding: Sendable {
    func translationEngines(settings: SettingsSnapshot) -> [EngineDescriptor]
    func health(of id: EngineID, settings: SettingsSnapshot, forceRefresh: Bool) async -> EngineHealth
    func testTranslation(_ id: EngineID, settings: SettingsSnapshot) async throws(AppError) -> String
    func testAnalysis(_ provider: AnalysisProvider, settings: SettingsSnapshot) async throws(AppError) -> String
    func models(for id: EngineID, endpoint: String, credential: CredentialRef?) async throws(AppError) -> [String]
    /// Runs the same small translation on each model (a few at a time) and streams results as they finish.
    func benchmarkModels(_ id: EngineID, models: [String], settings: SettingsSnapshot) -> AsyncStream<ModelSpeedResult>
    func paddleStatus(settings: SettingsSnapshot) async -> PaddleInstallation
    func generators(settings: SettingsSnapshot) async -> [EngineDescriptor]
    func testUpload(settings: SettingsSnapshot) async throws(AppError) -> UploadReceipt
}
