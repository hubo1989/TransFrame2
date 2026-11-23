import CoreGraphics
import Foundation
import TFDomain

/// Deterministic text metrics: each character is half the font size wide, lines are 1.2 × font size tall.
public struct FakeTextMeasurer: TextMeasuring {
    public init() {}
    public func measure(_ text: String, fontSize: Double, maxWidth: Double) -> TextMetrics {
        let charWidth = fontSize * 0.5
        let natural = Double(text.count) * charWidth
        guard maxWidth.isFinite, maxWidth > 0, natural > maxWidth else {
            return TextMetrics(width: natural, height: fontSize * 1.2, lineCount: 1)
        }
        let perLine = max(Int(maxWidth / charWidth), 1)
        let lines = Int((Double(text.count) / Double(perLine)).rounded(.up))
        return TextMetrics(width: min(Double(perLine) * charWidth, maxWidth), height: Double(lines) * fontSize * 1.2, lineCount: lines)
    }
}

/// Composer returning a pattern image of the requested size.
public final class FakeFrameComposer: FrameComposing, @unchecked Sendable {
    public let calls = CallLog<ResolvedSelection>()
    public init() {}
    public func compose(_ selection: ResolvedSelection, from frames: FrozenFrameSet) async throws(AppError) -> PixelImage {
        calls.append(selection)
        return TestImages.pattern(width: selection.outputSize.width, height: selection.outputSize.height, scale: selection.outputScale)
    }
}

/// Records plans and returns a canvas-sized solid image.
public final class FakeRenderExecutor: RenderPlanExecuting, @unchecked Sendable {
    public let plans = CallLog<RenderPlan>()
    public init() {}
    public func image(for plan: RenderPlan, base: PixelImage) async throws(AppError) -> PixelImage {
        plans.append(plan)
        return TestImages.solid(width: plan.canvas.width, height: plan.canvas.height, scale: plan.scale)
    }
    public func draw(_ plan: RenderPlan, base: PixelImage, in context: CGContext) { plans.append(plan) }
}

public final class FakeImageCodec: ImageEncoding, Thumbnailing, @unchecked Sendable {
    public let encoded = CallLog<(ExportFormat, Double)>()
    public init() {}
    public func encode(_ image: PixelImage, format: ExportFormat, quality: Double) throws(AppError) -> Data {
        encoded.append((format, quality))
        return Data("\(format.rawValue):\(image.pixelSize.width)x\(image.pixelSize.height)".utf8)
    }
    public func decode(_ data: Data) throws(AppError) -> PixelImage { TestImages.solid(width: 10, height: 10) }
    public func thumbnail(of image: PixelImage, maxEdge: Int, maxBytes: Int) -> Data? { Data(count: min(maxBytes, 64)) }
}

public final class FakeFileExporter: FileExporting, @unchecked Sendable {
    public let written = CallLog<(String, String, URL)>()
    public let failure = Locked<AppError?>(nil)
    public init() {}
    public func write(_ data: Data, baseName: String, fileExtension: String, to directory: URL) async throws(AppError) -> URL {
        if let failure = failure.current { throw failure }
        written.append((baseName, fileExtension, directory))
        return directory.appending(path: "\(baseName).\(fileExtension)")
    }
    public func write(_ data: Data, to url: URL) async throws(AppError) {
        if let failure = failure.current { throw failure }
        written.append((url.deletingPathExtension().lastPathComponent, url.pathExtension, url.deletingLastPathComponent()))
    }
}

public final class FakeSnapshotter: SnapshotCapturing, @unchecked Sendable {
    public let requests = CallLog<CaptureRequest>()
    public let result: Locked<Result<FrozenFrameSet, AppError>?>
    public init(frames: FrozenFrameSet? = nil) { result = Locked(frames.map { .success($0) }) }
    public func freeze(_ request: CaptureRequest) async throws(AppError) -> FrozenFrameSet {
        requests.append(request)
        switch result.current {
        case .success(let frames): return frames
        case .failure(let error): throw error
        case nil: throw .capture(.noDisplays)
        }
    }
}

public final class FakeColorSampler: ColorSampling, @unchecked Sendable {
    public let next = Locked<RGBA?>(nil)
    public init(_ color: RGBA? = nil) { next.current = color }
    public func pickColor() async -> RGBA? { next.current }
}

public final class FakeHistoryWorkflow: HistoryWorkflow, @unchecked Sendable {
    public let recorded = CallLog<HistoryEntry>()
    public init() {}
    public func page(_ query: HistoryQuery) async throws(AppError) -> HistoryPage {
        let entries = recorded.calls.filter { query.matches($0) }
        return HistoryPage(entries: entries, totalCount: entries.count, hasMore: false)
    }
    public func search(semantic text: String, query: HistoryQuery, limit: Int) async throws(AppError) -> HistoryPage { try await page(query) }
    public func setFavorite(_ id: HistoryEntryID, _ on: Bool) async throws(AppError) {}
    public func remove(_ ids: [HistoryEntryID]) async throws(AppError) {}
    public func clear(_ scope: HistoryScope) async throws(AppError) {}
    public func export(_ query: HistoryQuery, as format: HistoryExportFormat, to url: URL) async throws(AppError) {}
    public func record(_ entry: HistoryEntry, settings: SettingsSnapshot) async { recorded.append(entry) }
    public func notice() async -> HistoryStoreNotice? { nil }
}

public struct FakeImageUploader: ImageUploading {
    public let objectNames = CallLog<String>()

    public init() {}

    public func upload(_ data: Data, fileName: String, contentType: String, settings: ImageHostSettings) async throws(AppError) -> UploadReceipt {
        guard let provider = settings.provider, let url = URL(string: "https://example.invalid/") else {
            throw .upload(.notConfigured)
        }
        objectNames.append(fileName)
        return UploadReceipt(url: url.appending(path: fileName), provider: provider)
    }
}
