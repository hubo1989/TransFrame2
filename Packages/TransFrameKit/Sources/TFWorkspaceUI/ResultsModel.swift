import AppKit
import Observation
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization

/// Dependencies shared by the capture overlay, editor and pins.
@MainActor
public struct WorkspaceServices {
    public let sessions: any SessionManaging
    public let render: any RenderWorkflow
    public let export: any ExportWorkflow
    public let pipeline: (any DocumentPipelineWorkflow)?
    public let glossary: (any GlossaryWorkflow)?
    public let colorPick: any ColorPickWorkflow
    public let pasteboard: any PasteboardAccessing
    public let settings: any SettingsProviding
    public let localizer: Localizer
    public let errors: any ErrorPresenting
    public let router: any AppRouting
    public let performance: any PerformanceRecording

    public init(
        sessions: any SessionManaging, render: any RenderWorkflow, export: any ExportWorkflow, pipeline: (any DocumentPipelineWorkflow)?,
        glossary: (any GlossaryWorkflow)?, colorPick: any ColorPickWorkflow, pasteboard: any PasteboardAccessing, settings: any SettingsProviding,
        localizer: Localizer, errors: any ErrorPresenting, router: any AppRouting, performance: any PerformanceRecording
    ) {
        self.sessions = sessions
        self.render = render
        self.export = export
        self.pipeline = pipeline
        self.glossary = glossary
        self.colorPick = colorPick
        self.pasteboard = pasteboard
        self.settings = settings
        self.localizer = localizer
        self.errors = errors
        self.router = router
        self.performance = performance
    }

    /// The scan stays up at least this long, so a fast detection still reads as a scan instead of a flash.
    static let minimumScan: Duration = .milliseconds(800)

    /// Smart mosaic with feedback (INP-08): the canvas scans while detection runs, the areas it found light up, and a
    /// toast says how many were pixelated or that nothing private was found. Returns the number of areas.
    @discardableResult
    public func smartMosaic(_ id: SessionID, on canvas: DocumentCanvasView?, near anchor: CGPoint? = nil) async throws(AppError) -> Int {
        guard let pipeline else { return 0 }
        // The sweep starts on the click; the baseline snapshot is read afterwards.
        let started = ContinuousClock.now
        canvas?.beginScanning()
        if let canvas {
            NSAccessibility.post(
                element: canvas, notification: .announcementRequested, userInfo: [.announcement: localizer[.feedbackSmartMosaicScanning]])
        }
        let before = Set(((try? await sessions.snapshot(of: id))?.annotations ?? []).map(\.id))
        let count: Int
        do {
            count = try await pipeline.smartMosaic(id, settings: settings.snapshot)
        } catch {
            canvas?.finishScanning(found: [])
            throw error
        }
        let remaining = Self.minimumScan - (ContinuousClock.now - started)
        if remaining > .zero { try? await Task.sleep(for: remaining) }
        let found = ((try? await sessions.snapshot(of: id))?.annotations ?? []).filter { !before.contains($0.id) }.map(\.bounds)
        canvas?.finishScanning(found: found)
        errors.toast(
            count > 0
                ? ToastModel(.success, message: localizer.string(.feedbackSmartMosaic, count))
                : ToastModel(.info, message: localizer[.feedbackSmartMosaicNone]),
            near: anchor)
        return count
    }

    /// Annotation editor wired to defaults memory (ANN-15) and the annotation color picker (COL-11).
    public func makeEditor(for id: SessionID) -> AnnotationEditor {
        let editor = AnnotationEditor(sessions: sessions, sessionID: id, defaults: settings.annotationDefaults) { [localizer] key in
            localizer.string(rawKey: key)
        }
        let settings = settings, colorPick = colorPick
        editor.onStyleChange = { style in settings.annotationDefaults = style.asDefaults }
        editor.onPickColor = { await colorPick.pickForAnnotation(settings: settings.snapshot) }
        return editor
    }
}

public enum ResultsTab: String, CaseIterable, Sendable { case recognition, translation }

/// State of the results drawer (INP-05/06/11, EDT-10…13, N-03, N-15, AI-02).
@MainActor
@Observable
public final class ResultsModel {
    public var tab: ResultsTab = .recognition
    public private(set) var stage: DocumentPipelineStage?
    public private(set) var error: AppError?
    public private(set) var actions: [SmartAction] = []
    public private(set) var session: DocumentSession?
    public var correcting: SegmentID?

    @ObservationIgnored public let services: WorkspaceServices
    @ObservationIgnored public let sessionID: SessionID
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init(services: WorkspaceServices, sessionID: SessionID) {
        self.services = services
        self.sessionID = sessionID
    }

    public var isRunning: Bool { stage != nil }
    public var l10n: Localizer { services.localizer }

    public func update(_ session: DocumentSession) {
        let analysisChanged = self.session?.analysis?.id != session.analysis?.id
        self.session = session
        if analysisChanged { refreshActions() }
    }

    // MARK: Running

    public func recognize(force: Bool = false) {
        tab = .recognition
        run({ pipeline, options in pipeline.recognize(self.sessionID, options: options) }, force: force)
    }

    public func translate(force: Bool = false, target: LanguageCode? = nil, overridePrivacy: Bool = false) {
        tab = .translation
        run({ pipeline, options in pipeline.translate(self.sessionID, options: options) }, force: force, target: target, overridePrivacy: overridePrivacy)
    }

    private func run(
        _ start: @escaping (any DocumentPipelineWorkflow, DocumentPipelineOptions) -> AsyncThrowingStream<DocumentPipelineEvent, any Error>,
        force: Bool, target: LanguageCode? = nil, overridePrivacy: Bool = false
    ) {
        guard let pipeline = services.pipeline else { return }
        task?.cancel()
        error = nil
        stage = .preparing
        let options = DocumentPipelineOptions(
            settings: services.settings.snapshot, target: target, cache: force ? .forceRefresh : .normal, overridePrivacyGuard: overridePrivacy
        )
        let stream = start(pipeline, options)
        generation += 1
        let current = generation
        task = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self, self.generation == current else { return }
                    switch event {
                    case .stage(let stage): self.stage = stage
                    case .privacy(let report) where report.applied:
                        self.services.errors.toast(ToastModel(.info, message: self.l10n.string(.privacyGuardApplied, report.redactedCount)), near: nil)
                    default: break
                    }
                }
                if self?.generation == current { self?.stage = nil }
            } catch {
                guard let self, self.generation == current else { return }
                self.stage = nil
                let appError = AppError.from(error)
                if appError != .cancelled { self.error = appError }
            }
        }
    }

    public func cancel() {
        generation += 1
        task?.cancel()
        stage = nil
        let pipeline = services.pipeline, id = sessionID
        Task { await pipeline?.cancel(id) }
    }

    public func selectEngine(_ engine: EngineID) {
        let pipeline = services.pipeline, id = sessionID
        Task { try? await pipeline?.selectEffectiveEngine(engine, in: id) }
    }

    public func restoreExcluded(_ segment: SegmentID) {
        let pipeline = services.pipeline, id = sessionID
        Task { try? await pipeline?.restoreExcluded(segment, in: id) }
    }

    private func refreshActions() {
        guard let pipeline = services.pipeline else { actions = []; return }
        let id = sessionID
        Task { [weak self] in
            let derived = await pipeline.smartActions(for: id)
            self?.actions = derived
        }
    }

    // MARK: Display mode (N-03)

    public var showsOverlay: Bool { session?.presentation.showsTranslationOverlay ?? false }

    public func setShowsOverlay(_ on: Bool) {
        guard var presentation = session?.presentation else { return }
        presentation.showsTranslationOverlay = on
        apply(presentation)
    }

    public func setOverlayMode(_ mode: OverlayMode) {
        guard var presentation = session?.presentation else { return }
        presentation.overlayMode = mode
        apply(presentation)
    }

    private func apply(_ presentation: PresentationOptions) {
        guard let session, let transaction = EditTransaction.setPresentation(presentation, in: session, label: "undo.presentation") else { return }
        let sessions = services.sessions, id = sessionID
        Task { try? await sessions.apply(transaction, to: id) }
    }

    // MARK: Copy (EDT-12)

    public enum CopyScope { case all, source, translation }

    public func copy(_ scope: CopyScope) {
        let lines = VisualLines.group(session)
        let text: String = switch scope {
        case .source: lines.map(\.source).joined(separator: "\n")
        case .translation: lines.compactMap { $0.status == .sameLanguageSkipped ? $0.source : $0.translation }.joined(separator: "\n")
        case .all: lines.map { [$0.source, $0.translation].compactMap { $0 }.joined(separator: "\n") }.joined(separator: "\n\n")
        }
        copyText(text)
    }

    public func copyText(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = services.pasteboard, errors = services.errors, message = l10n[.feedbackCopied]
        Task {
            do {
                try await pasteboard.write(.string(text))
                errors.toast(ToastModel(message: message), near: nil)
            } catch {
                errors.present(.export(.clipboardWriteFailed), near: nil)
            }
        }
    }

    // MARK: Smart actions (AI-02)

    public func perform(_ action: SmartAction) {
        switch action.kind {
        case .copyTableAsMarkdown, .copyTableAsCSV, .copyFormulaAsLaTeX, .copyCode:
            copyText(action.payload ?? "")
        case .openLink(let url), .openQRCode(let url):
            NSWorkspace.shared.open(url)
        case .composeEmail(let address):
            if let url = URL(string: "mailto:\(address)") { NSWorkspace.shared.open(url) }
        case .addEvent(let interval):
            CalendarFile.open(interval: interval, title: action.payload ?? "")
        }
    }

    // MARK: Correct and remember (AI-04)

    public func correct(_ segment: SegmentID, translation: String, remember: Bool) {
        guard let glossary = services.glossary, let operation = session?.translation?.operation else { return }
        let id = sessionID, errors = services.errors
        Task {
            do {
                try await glossary.correct(segment, in: id, expectedOperation: operation, translation: translation, remember: remember)
            } catch {
                errors.present(error, near: nil)
            }
        }
        correcting = nil
    }
}

/// Bilingual rows grouped by visual line with CJK-aware joining (RES-01).
public enum VisualLines {
    public struct Row: Identifiable, Equatable {
        public let id: SegmentID
        public let source: String
        public let translation: String?
        public let status: SegmentStatus?
    }

    public static func group(_ session: DocumentSession?) -> [Row] {
        guard let analysis = session?.analysis else { return [] }
        let translations = Dictionary((session?.effectiveTranslation ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return analysis.segments.map { segment in
            let bilingual = translations[segment.id]
            return Row(id: segment.id, source: segment.effectiveText, translation: bilingual?.translated, status: bilingual?.status)
        }
    }

    /// Joins line fragments: no space between CJK characters or before closing punctuation; a space otherwise.
    public static func join(_ parts: [String]) -> String {
        var result = ""
        for part in parts.map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            guard let last = result.last, let first = part.first else { result += part; continue }
            if result.hasSuffix("-"), first.isLetter, last == "-" {
                result.removeLast()
                result += part
            } else if isCJK(last) || isCJK(first) || ",.;:!?)]}%".contains(first) {
                result += part
            } else {
                result += " " + part
            }
        }
        return result
    }

    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }
}

/// Writes a one-event .ics file and opens it with Calendar (no EventKit entitlement needed).
enum CalendarFile {
    static func open(interval: DateInterval, title: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let body = """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//TransFrame 2//EN
        BEGIN:VEVENT
        UID:\(UUID().uuidString)
        DTSTAMP:\(formatter.string(from: Date()))
        DTSTART:\(formatter.string(from: interval.start))
        DTEND:\(formatter.string(from: interval.end))
        SUMMARY:\(title.replacingOccurrences(of: "\n", with: " "))
        END:VEVENT
        END:VCALENDAR
        """
        let url = FileManager.default.temporaryDirectory.appending(path: "TransFrame-\(UUID().uuidString.prefix(8)).ics")
        guard (try? body.replacingOccurrences(of: "\n", with: "\r\n").write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        NSWorkspace.shared.open(url)
    }
}
