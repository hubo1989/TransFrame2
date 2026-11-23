import CoreGraphics
import Foundation
import os
import TFDomain

// MARK: - Performance recorder (SPEC §04 §5.1): signposts + in-process samples.

public final class PerformanceRecorder: PerformanceRecording {
    private let state = OSAllocatedUnfairLock<[PerformanceSample]>(initialState: [])
    private let signposter: OSSignposter
    private let limit: Int

    public init(subsystem: String = "com.transframe.v2", limit: Int = 5_000) {
        signposter = OSSignposter(subsystem: subsystem, category: "perf")
        self.limit = limit
    }

    public func record(_ sample: PerformanceSample) {
        signposter.emitEvent("sample", "\(sample.budget, privacy: .public) \(sample.milliseconds, format: .fixed(precision: 2))ms")
        state.withLock { samples in
            samples.append(sample)
            if samples.count > limit { samples.removeFirst(samples.count - limit) }
        }
    }

    public func samples() async -> [PerformanceSample] { state.withLock { $0 } }

    /// JSON export for `Scripts/perf.sh` reports.
    public func exportJSON() -> Data {
        (try? JSONEncoder().encode(state.withLock { $0 })) ?? Data("[]".utf8)
    }
}

// MARK: - File names (EXP-01, AI-07)

public enum ScreenshotNaming {
    /// `Screenshot 2026-11-23 at 14.05.09` in a fixed POSIX format (1.x compatible).
    public static func baseName(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "Screenshot %04d-%02d-%02d at %02d.%02d.%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Removes characters that are illegal or awkward in file names and trims length (AI-07).
    public static func sanitize(_ raw: String, maxLength: Int = 80) -> String? {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}").union(.controlCharacters).union(.newlines)
        var text = raw.components(separatedBy: forbidden).joined(separator: " ")
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-_").union(.whitespaces))
        while text.hasPrefix(".") { text.removeFirst() }
        guard !text.isEmpty else { return nil }
        if text.count > maxLength {
            text = String(text.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }
}

// MARK: - Render workflow

public struct RenderService: RenderWorkflow {
    private let sessions: DocumentSessionStore
    private let planner: RenderPlanner
    private let executor: any RenderPlanExecuting
    private let performance: any PerformanceRecording

    public init(sessions: DocumentSessionStore, planner: RenderPlanner, executor: any RenderPlanExecuting, performance: any PerformanceRecording) {
        self.sessions = sessions
        self.planner = planner
        self.executor = executor
        self.performance = performance
    }

    public func plan(for id: SessionID, purpose: RenderPurpose) async throws(AppError) -> RenderPlan {
        try await plan(for: id, purpose: purpose, excluding: [])
    }

    public func plan(for id: SessionID, purpose: RenderPurpose, excluding: Set<AnnotationID>) async throws(AppError) -> RenderPlan {
        let session = try await sessions.snapshot(of: id)
        let start = ContinuousClock.now
        let plan = try planner.plan(for: session, purpose: purpose, excluding: excluding)
        performance.record(PerformanceSample(budget: Budget.renderPlan, duration: .now - start))
        return plan
    }

    public func image(for id: SessionID, purpose: RenderPurpose) async throws(AppError) -> PixelImage {
        try await image(of: try await sessions.snapshot(of: id), purpose: purpose)
    }

    /// Renders one immutable snapshot so pixels, names and saved revisions agree (review-1 P2-12).
    public func image(of session: DocumentSession, purpose: RenderPurpose) async throws(AppError) -> PixelImage {
        let plan = try planner.plan(for: session, purpose: purpose)
        let start = ContinuousClock.now
        let image = try await executor.image(for: plan, base: session.baseImage)
        performance.record(PerformanceSample(budget: Budget.renderExecute, duration: .now - start, scale: Int(plan.scale)))
        return image
    }

    public func draw(_ plan: RenderPlan, base: PixelImage, in context: CGContext) {
        executor.draw(plan, base: base, in: context)
    }
}

// MARK: - Capture workflow

public struct CaptureService: CaptureWorkflow {
    private let snapshotter: any SnapshotCapturing
    private let blocks: (any ContentBlockDetecting)?
    private let performance: any PerformanceRecording
    private let freezeCount = OSAllocatedUnfairLock(initialState: 0)

    public init(snapshotter: any SnapshotCapturing, blocks: (any ContentBlockDetecting)?, performance: any PerformanceRecording) {
        self.snapshotter = snapshotter
        self.blocks = blocks
        self.performance = performance
    }

    public func freeze(_ request: CaptureRequest) async throws(AppError) -> FrozenFrameSet {
        let frames = try await snapshotter.freeze(request)
        let isCold = freezeCount.withLock { count -> Bool in
            count += 1
            return count == 1
        }
        let elapsed = ContinuousClock.now - request.triggerInstant
        performance.record(PerformanceSample(
            budget: "freeze", operation: request.id.shortDescription, state: isCold ? .cold : .warm, duration: elapsed,
            displays: frames.frames.count
        ))
        return frames
    }

    /// Local detection on every frame, merged and ordered by score (AI-03). Failures yield no candidates.
    public func contentBlocks(in frames: FrozenFrameSet) async -> [SelectionCandidate] {
        guard let blocks else { return [] }
        let start = ContinuousClock.now
        let found = await withTaskGroup(of: [SelectionCandidate].self) { group in
            for frame in frames.frames {
                group.addTask { (try? await blocks.blocks(in: frame)) ?? [] }
            }
            return await group.reduce(into: [SelectionCandidate]()) { $0 += $1 }
        }
        performance.record(PerformanceSample(budget: Budget.blockDetection, duration: .now - start, displays: frames.frames.count))
        return SelectionCandidates.deduplicated(found)
    }
}

public enum SelectionCandidates {
    /// Removes near-duplicates (IoU > 0.85), keeps the higher score, sorts by score then area.
    public static func deduplicated(_ candidates: [SelectionCandidate]) -> [SelectionCandidate] {
        var kept: [SelectionCandidate] = []
        for candidate in candidates.sorted(by: { ($0.score, -$0.rect.area) > ($1.score, -$1.rect.area) }) {
            let duplicate = kept.contains { other in
                guard let i = other.rect.intersection(candidate.rect) else { return false }
                let union = other.rect.area + candidate.rect.area - i.area
                return union > 0 && i.area / union > 0.85
            }
            if !duplicate { kept.append(candidate) }
        }
        return kept
    }
}

// MARK: - Color picking (COL-01, COL-11)

public struct ColorPickService: ColorPickWorkflow {
    private let sampler: any ColorSampling
    private let pasteboard: any PasteboardAccessing
    private let history: any HistoryWorkflow

    public init(sampler: any ColorSampling, pasteboard: any PasteboardAccessing, history: any HistoryWorkflow) {
        self.sampler = sampler
        self.pasteboard = pasteboard
        self.history = history
    }

    public func pickAndCopy(settings: SettingsSnapshot) async throws(AppError) -> RGBA? {
        guard let color = await sampler.pickColor() else { return nil }
        try await pasteboard.write(.string(color.hexString))
        await history.record(HistoryEntry(kind: .color, source: "", result: color.hexString), settings: settings)
        return color
    }

    public func pickForAnnotation(settings: SettingsSnapshot) async -> RGBA? {
        guard let color = await sampler.pickColor() else { return nil }
        await history.record(HistoryEntry(kind: .color, source: "", result: color.hexString), settings: settings)
        return color
    }

    public func copy(_ color: RGBA, format: ColorCopyFormat) async throws(AppError) {
        try await pasteboard.write(.string(format.string(for: color)))
    }
}
