import CoreGraphics
import Foundation

// MARK: - Capability protocols implemented by Infrastructure (SPEC §02 §10.1, §01 §3.2)
// Every protocol has a programmable fake in TFDomainTestSupport.

// MARK: Capture

public protocol SnapshotCapturing: Sendable {
    func freeze(_ request: CaptureRequest) async throws(AppError) -> FrozenFrameSet
}

public protocol DisplayTopologyProviding: Sendable {
    func topology() async throws(AppError) -> DisplayTopology
    /// Current pointer location; called at the hotkey entry before any actor hop.
    @MainActor func pointerLocation() -> QuartzPoint
}

public protocol WindowEnumerating: Sendable {
    func windows(excluding: Set<WindowID>) async -> [WindowCandidate]
    func frontmostContext() async -> CaptureContext?
}

public protocol ScrollCapturing: Sendable {
    /// Captures the current pixels of a rect (points, one display) without freezing other screens.
    func captureStrip(_ rect: QuartzRect, excluding: Set<WindowID>) async throws(AppError) -> PixelImage
}

// MARK: Recognition

public protocol RecognitionEngine: Sendable {
    var descriptor: EngineDescriptor { get }
    func recognize(_ image: PixelImage, hints: [LanguageCode], detail: AnalysisDetail) async throws(AppError) -> RawRecognition
}

public protocol RecognitionEngineProviding: Sendable {
    func descriptors(for settings: SettingsSnapshot) -> [EngineDescriptor]
    func engine(_ id: EngineID, settings: SettingsSnapshot) -> (any RecognitionEngine)?
    /// Engine for the screenshot-translation analysis provider.
    func analysisEngine(_ provider: AnalysisProvider, settings: SettingsSnapshot) -> (any RecognitionEngine)?
}

public protocol SensitiveContentDetecting: Sendable {
    func detect(in image: PixelImage) async throws(AppError) -> [SensitiveFinding]
}

public protocol ContentBlockDetecting: Sendable {
    func blocks(in frame: CapturedFrame) async throws(AppError) -> [SelectionCandidate]
}

public struct DetectedCode: Sendable, Equatable {
    public let payload: String
    public let box: FrameRect
    public init(payload: String, box: FrameRect) {
        self.payload = payload
        self.box = box
    }
}

public protocol CodeDetecting: Sendable {
    func codes(in image: PixelImage) async -> [DetectedCode]
}

public struct PaddleInstallation: Sendable, Equatable {
    public let isInstalled: Bool
    public let version: String?
    public let executablePath: String?
    public let installCommand: String
    public init(isInstalled: Bool, version: String?, executablePath: String?, installCommand: String) {
        self.isInstalled = isInstalled
        self.version = version
        self.executablePath = executablePath
        self.installCommand = installCommand
    }
}

public protocol PaddleInstallationChecking: Sendable {
    func check(executablePath: String?) async -> PaddleInstallation
}

// MARK: Translation

public protocol TranslationEngine: Sendable {
    var descriptor: EngineDescriptor { get }
    func translate(_ batch: TranslationBatch) async throws(AppError) -> [TranslatedUnit]
}

public protocol TranslationEngineProviding: Sendable {
    /// Every translation engine, configured or not, built-ins first then compatible instances.
    func descriptors(for settings: SettingsSnapshot) -> [EngineDescriptor]
    func engine(_ id: EngineID, settings: SettingsSnapshot) -> (any TranslationEngine)?
    /// Why an engine cannot run right now, or nil when it can.
    func skipReason(_ id: EngineID, settings: SettingsSnapshot) async -> SkipReason?
}

public protocol EngineHealthProbing: Sendable {
    func health(of id: EngineID, settings: SettingsSnapshot, forceRefresh: Bool) async -> EngineHealth
    func cachedHealth(of id: EngineID) async -> EngineHealth?
}

public protocol ModelDiscovering: Sendable {
    func models(endpoint: String, credential: CredentialRef?, engine: EngineID) async throws(AppError) -> [String]
}

public enum LanguagePairStatus: String, Sendable, Equatable { case installed, supported, unsupported }

public protocol LanguageAvailabilityChecking: Sendable {
    func status(from: LanguageCode?, to: LanguageCode) async -> LanguagePairStatus
}

// MARK: AI

public protocol TextGenerating: Sendable {
    var descriptor: EngineDescriptor { get }
    func generate(_ request: GenerationRequest) async throws(AppError) -> String
}

public protocol TextGeneratorProviding: Sendable {
    /// Candidates in priority order for `.automatic` (SPEC ADR-0011 §3).
    func generator(for choice: AIEngineChoice, settings: SettingsSnapshot) async -> (any TextGenerating)?
    func availableGenerators(settings: SettingsSnapshot) async -> [EngineDescriptor]
}

public protocol TextEmbedding: Sendable {
    var descriptor: EngineDescriptor { get }
    var dimension: Int { get }
    func embed(_ texts: [String], language: LanguageCode?) async throws(AppError) -> [[Float]]
}

// MARK: Network

public enum HTTPMethod: String, Sendable { case get = "GET", post = "POST", put = "PUT", delete = "DELETE", head = "HEAD" }

public struct HTTPRequest: Sendable, Equatable {
    public var url: URL
    public var method: HTTPMethod
    public var headers: [String: String]
    public var body: Data?
    public var timeout: Duration

    public init(url: URL, method: HTTPMethod = .get, headers: [String: String] = [:], body: Data? = nil, timeout: Duration = .seconds(60)) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
    public var isSuccess: Bool { (200..<300).contains(status) }
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol HTTPTransport: Sendable {
    /// Network failures map to `.engine(.unreachable)` / `.engine(.timedOut)` for `engine`; cancellation to `.cancelled`.
    func send(_ request: HTTPRequest, engine: EngineID) async throws(AppError) -> HTTPResponse
}

// MARK: Render

public protocol RenderPlanExecuting: Sendable {
    func image(for plan: RenderPlan, base: PixelImage) async throws(AppError) -> PixelImage
    /// Shared by screen and export. The context's origin is the canvas top-left, y down.
    func draw(_ plan: RenderPlan, base: PixelImage, in context: CGContext)
}

public protocol TextMeasuring: Sendable {
    func measure(_ text: String, fontSize: Double, maxWidth: Double) -> TextMetrics
}

public protocol FrameComposing: Sendable {
    /// Builds the selection image from frozen frames; gaps between displays stay transparent.
    func compose(_ selection: ResolvedSelection, from frames: FrozenFrameSet) async throws(AppError) -> PixelImage
}

public protocol ImageEncoding: Sendable {
    func encode(_ image: PixelImage, format: ExportFormat, quality: Double) throws(AppError) -> Data
    func decode(_ data: Data) throws(AppError) -> PixelImage
}

public protocol Thumbnailing: Sendable {
    /// JPEG, longest edge ≤ `maxEdge`, at most `maxBytes`.
    func thumbnail(of image: PixelImage, maxEdge: Int, maxBytes: Int) -> Data?
}

public protocol ColorSampling: Sendable {
    /// System screen color picker; nil when the user cancels.
    func pickColor() async -> RGBA?
}

// MARK: Persistence

public protocol HistoryStoring: Sendable {
    func add(_ entry: HistoryEntry, limit: Int) async throws(AppError) -> HistoryEntry
    func page(_ query: HistoryQuery) async throws(AppError) -> HistoryPage
    func entries(ids: [HistoryEntryID]) async throws(AppError) -> [HistoryEntry]
    func all(matching query: HistoryQuery) async throws(AppError) -> [HistoryEntry]
    func setFavorite(_ id: HistoryEntryID, _ on: Bool) async throws(AppError)
    func remove(_ ids: [HistoryEntryID]) async throws(AppError)
    func clear(_ scope: HistoryScope) async throws(AppError)
    /// Set when the store had to be moved aside and recreated.
    func notice() async -> HistoryStoreNotice?
}

public protocol CredentialStoring: Sendable {
    func secret(for ref: CredentialRef) async throws(AppError) -> String?
    func store(_ secret: String, for ref: CredentialRef) async throws(AppError)
    func remove(_ ref: CredentialRef) async throws(AppError)
    func hasSecret(for ref: CredentialRef) async -> Bool
}

public protocol GlossaryStoring: Sendable {
    func entries() async throws(AppError) -> [GlossaryEntry]
    func version() async -> Int
    func upsert(_ entry: GlossaryEntry) async throws(AppError)
    func remove(_ id: GlossaryEntryID) async throws(AppError)
}

public protocol EmbeddingIndexStoring: Sendable {
    func upsert(_ id: HistoryEntryID, vector: [Float]) async throws(AppError)
    func remove(_ ids: [HistoryEntryID]) async throws(AppError)
    func removeAll() async throws(AppError)
    func nearest(to vector: [Float], limit: Int) async throws(AppError) -> [(HistoryEntryID, Double)]
}

public protocol FileExporting: Sendable {
    /// Writes data to `directory` with a unique `Screenshot <date> at <time>` style name (EXP-01, EXP-02).
    func write(_ data: Data, baseName: String, fileExtension: String, to directory: URL) async throws(AppError) -> URL
    func write(_ data: Data, to url: URL) async throws(AppError)
}

// MARK: System

public protocol HotkeyRegistering: Sendable {
    /// Replaces every registration. Returns actions whose registration failed.
    func register(_ bindings: [HotkeyAction: GlobalShortcut], handler: @escaping @Sendable (HotkeyAction, ContinuousClock.Instant) -> Void) async -> [HotkeyAction]
    func unregisterAll() async
}

public enum PasteboardContent: Sendable, Equatable {
    case string(String)
    case image(Data)
}

public protocol PasteboardAccessing: Sendable {
    func write(_ content: PasteboardContent) async throws(AppError)
    func writeImage(_ image: PixelImage) async throws(AppError)
    func readString() async -> String?
    func changeCount() async -> Int
    /// Opaque snapshot of all items, for restoring after synthetic copy/paste (TXT-16).
    func snapshot() async -> PasteboardSnapshot
    func restore(_ snapshot: PasteboardSnapshot) async
}

public struct PasteboardSnapshot: Sendable, Equatable {
    public let items: [[String: Data]]
    public init(items: [[String: Data]]) { self.items = items }
}

/// Opaque handle to the input field bound at capture time (TXT-06/07).
public struct TextInsertionTarget: Sendable, Equatable {
    public let processID: Int32
    public let bundleID: String?
    public let elementToken: Int
    public let selectedRange: Range<Int>?
    public let canVerify: Bool
    public init(processID: Int32, bundleID: String?, elementToken: Int, selectedRange: Range<Int>?, canVerify: Bool) {
        self.processID = processID
        self.bundleID = bundleID
        self.elementToken = elementToken
        self.selectedRange = selectedRange
        self.canVerify = canVerify
    }
}

public struct CapturedSelection: Sendable, Equatable {
    public let text: String
    public let target: TextInsertionTarget?
    /// Caret/selection rect for positioning the progress HUD.
    public let anchor: QuartzRect?
    public let appName: String?
    public init(text: String, target: TextInsertionTarget?, anchor: QuartzRect?, appName: String?) {
        self.text = text
        self.target = target
        self.anchor = anchor
        self.appName = appName
    }
}

public protocol SelectedTextCapturing: Sendable {
    /// Reads the selection through accessibility first, then synthetic ⌘C (restoring the pasteboard).
    func captureSelection(bindTarget: Bool) async throws(AppError) -> CapturedSelection
}

public enum InsertionMethod: String, Sendable, Equatable { case accessibility, paste }

public protocol TextInserting: Sendable {
    /// Re-verifies focus and selection before writing; throws `.textInput(.targetChanged)` otherwise.
    func insert(_ text: String, into target: TextInsertionTarget) async throws(AppError) -> InsertionMethod
    /// Fallback: paste anchored to the frontmost process when no target could be bound (TXT-08).
    func pasteAnchored(_ text: String, processID: Int32?) async throws(AppError)
}

public enum PermissionKind: String, Sendable, CaseIterable, Equatable { case screenRecording, accessibility }

public protocol PermissionChecking: Sendable {
    func isGranted(_ kind: PermissionKind) async -> Bool
}

public protocol PermissionGuiding: Sendable {
    /// Shows the drag-to-authorize guide and returns when granted, or false after the timeout.
    @MainActor func guide(_ kind: PermissionKind, from sourceFrame: CGRect?) async -> Bool
    @MainActor func openSystemSettings(_ pane: SystemSettingsPane)
}

public protocol AppUpdating: Sendable {
    @MainActor func start()
    @MainActor func checkForUpdates()
    @MainActor var canCheckForUpdates: Bool { get }
}

public protocol CredentialUnlocking: Sendable {
    @MainActor var isUnlocked: Bool { get }
    @MainActor func unlock(reason: String) async -> Bool
}

public struct RunningAppInfo: Sendable, Equatable {
    public let bundleID: String
    public let name: String
    public let processID: Int32
    public init(bundleID: String, name: String, processID: Int32) {
        self.bundleID = bundleID
        self.name = name
        self.processID = processID
    }
}

public protocol RunningAppDetecting: Sendable {
    func running(bundleIDs: [String]) async -> [RunningAppInfo]
    func terminate(processID: Int32) async -> Bool
}

public enum SoundEffect: String, Sendable { case capture }

public protocol SoundPlaying: Sendable {
    func play(_ effect: SoundEffect) async
}

// MARK: Upload

public struct UploadReceipt: Sendable, Equatable {
    public let url: URL
    public let provider: EngineID
    public init(url: URL, provider: EngineID) {
        self.url = url
        self.provider = provider
    }
    public var markdown: String { "![](\(url.absoluteString))" }
}

public protocol ImageUploading: Sendable {
    func upload(_ data: Data, fileName: String, contentType: String, settings: ImageHostSettings) async throws(AppError) -> UploadReceipt
}

// MARK: Performance (SPEC §04 §5.1)

public enum WarmState: String, Sendable, Codable { case warm, cold }

public struct PerformanceSample: Sendable, Codable, Equatable {
    public let budget: String
    public let operation: String?
    public let state: WarmState
    public let durationNanoseconds: Int64
    public let displays: Int?
    public let scale: Int?
    public let engine: String?
    public let fromCache: Bool

    public init(
        budget: String, operation: String? = nil, state: WarmState = .warm, duration: Duration, displays: Int? = nil,
        scale: Int? = nil, engine: String? = nil, fromCache: Bool = false
    ) {
        self.budget = budget
        self.operation = operation
        self.state = state
        let parts = duration.components
        durationNanoseconds = parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000
        self.displays = displays
        self.scale = scale
        self.engine = engine
        self.fromCache = fromCache
    }

    public var milliseconds: Double { Double(durationNanoseconds) / 1_000_000 }
}

public protocol PerformanceRecording: Sendable {
    func record(_ sample: PerformanceSample)
    func samples() async -> [PerformanceSample]
}

/// Budget identifiers from SPEC §04 §3.
public enum Budget {
    public static let triggerToFrozenSingle = "P-01"
    public static let triggerToFrozenDual = "P-02"
    public static let triggerToFrozenCold = "P-03"
    public static let inputToVisible = "P-04"
    public static let mainThreadStall = "P-05"
    public static let confirmToEditor = "P-06"
    public static let cancelToStop = "P-08"
    public static let overlayEventHandling = "P-10"
    public static let blockDetection = "P-11"
    public static let visionRecognition = "R-01"
    public static let recognitionEngine = "R-02"
    public static let translationEngine = "R-03"
    public static let textPipelineOverhead = "R-04"
    public static let renderPlan = "R-05"
    public static let renderExecute = "R-06"
    public static let privacyGuard = "R-08"
    public static let cacheHit = "R-09"
    public static let historyFirstPage = "O-02"
    public static let historySearch = "O-03"
    public static let historySemantic = "O-04"
    public static let launchToMenu = "O-05"
    public static let languageSwitch = "O-07"
}

// MARK: Logging (no user content, SPEC §01 §7.6)

public enum LogLevel: String, Sendable { case debug, info, error }

public protocol EventLogging: Sendable {
    func log(_ level: LogLevel, category: String, _ message: String)
}
