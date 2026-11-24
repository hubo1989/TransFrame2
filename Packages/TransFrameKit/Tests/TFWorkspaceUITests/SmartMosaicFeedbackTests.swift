import AppKit
import Testing
import TFDomain
import TFDomainTestSupport
import TFLocalization
import TFPipelines
@testable import TFDesignSystem
@testable import TFWorkspaceUI

/// Inserts privacy mosaics over fixed rectangles after an optional delay (or fails).
private final class FakeMosaicPipeline: DocumentPipelineWorkflow, @unchecked Sendable {
    let store: DocumentSessionStore
    let rects: [DocumentRect]
    let fails: Bool
    init(store: DocumentSessionStore, rects: [DocumentRect], fails: Bool = false) {
        self.store = store
        self.rects = rects
        self.fails = fails
    }
    func recognize(_ id: SessionID, options: DocumentPipelineOptions) -> AsyncThrowingStream<DocumentPipelineEvent, any Error> { .init { $0.finish() } }
    func translate(_ id: SessionID, options: DocumentPipelineOptions) -> AsyncThrowingStream<DocumentPipelineEvent, any Error> { .init { $0.finish() } }
    func cancel(_ id: SessionID) async {}
    func selectEffectiveEngine(_ engine: EngineID, in id: SessionID) async throws(AppError) {}
    func smartActions(for id: SessionID) async -> [SmartAction] { [] }
    func restoreExcluded(_ segment: SegmentID, in id: SessionID) async throws(AppError) {}
    func smartMosaic(_ id: SessionID, settings: SettingsSnapshot) async throws(AppError) -> Int {
        try? await Task.sleep(for: .milliseconds(50))
        if fails { throw .recognition(.imageUnreadable) }
        let session = try await store.snapshot(of: id)
        let mosaics = rects.map { Annotation.mosaic(MosaicAnnotation(rect: $0, blockSize: 24, isPrivacy: true)) }
        guard let transaction = EditTransaction.insertAll(mosaics, into: session, label: "undo.smartMosaic") else { return 0 }
        try await store.apply(transaction, to: id)
        return mosaics.count
    }
}

private struct UnusedExport: ExportWorkflow {
    func copyImage(of id: SessionID, settings: SettingsSnapshot) async throws(AppError) {}
    func save(_ id: SessionID, as format: ExportFormat?, settings: SettingsSnapshot) async throws(AppError) -> SaveReceipt {
        throw .cancelled
    }
    func upload(_ id: SessionID, settings: SettingsSnapshot) async throws(AppError) -> UploadReceipt { throw .cancelled }
}

private struct UnusedColorPick: ColorPickWorkflow {
    func pickAndCopy(settings: SettingsSnapshot) async throws(AppError) -> RGBA? { nil }
    func pickForAnnotation(settings: SettingsSnapshot) async -> RGBA? { nil }
    func copy(_ color: RGBA, format: ColorCopyFormat) async throws(AppError) {}
}

@MainActor
private final class RecordingErrors: ErrorPresenting {
    var toasts: [ToastModel] = []
    var errors: [AppError] = []
    func present(_ error: AppError, near anchor: CGPoint?, retry: (() -> Void)?) { errors.append(error) }
    func toast(_ model: ToastModel, near anchor: CGPoint?, action: (() -> Void)?) { toasts.append(model) }
}

@Suite("Smart mosaic feedback", .serialized)
@MainActor
struct SmartMosaicFeedbackTests {
    private func services(_ h: CanvasHarness, pipeline: FakeMosaicPipeline, errors: RecordingErrors) -> WorkspaceServices {
        WorkspaceServices(
            sessions: h.store, render: h.render, export: UnusedExport(), pipeline: pipeline, glossary: nil, colorPick: UnusedColorPick(),
            pasteboard: FakePasteboard(), settings: FakeSettings(), localizer: Localizer(preference: "zh-Hans"), errors: errors,
            router: FakeRouter(), performance: FakePerformanceRecorder())
    }

    @Test func scansThenLightsUpWhatItFoundAndSaysHowMany() async throws {
        let h = await CanvasHarness()
        defer { h.tearDown() }
        let errors = RecordingErrors()
        let found = [DocumentRect(x: 100, y: 100, width: 200, height: 40), DocumentRect(x: 400, y: 500, width: 300, height: 60)]
        let s = services(h, pipeline: FakeMosaicPipeline(store: h.store, rects: found), errors: errors)
        let start = ContinuousClock.now
        let run = Task { try await s.smartMosaic(h.id, on: h.canvas) }
        for _ in 0..<20 where !h.canvas.isScanning { await Task.yield() }
        #expect(h.canvas.isScanning)
        #expect(errors.toasts.isEmpty)
        let count = try await run.value
        #expect(count == 2)
        #expect(ContinuousClock.now - start >= WorkspaceServices.minimumScan)
        #expect(!h.canvas.isScanning)
        #expect(h.canvas.scanView.highlights.count == 2)
        #expect(errors.toasts.map(\.message) == ["已完成打码，共 2 处"])
        #expect(errors.toasts.first?.kind == .success)
    }

    @Test func nothingFoundSaysSo() async throws {
        let h = await CanvasHarness()
        defer { h.tearDown() }
        let errors = RecordingErrors()
        let s = services(h, pipeline: FakeMosaicPipeline(store: h.store, rects: []), errors: errors)
        #expect(try await s.smartMosaic(h.id, on: h.canvas) == 0)
        #expect(!h.canvas.isScanning)
        #expect(h.canvas.scanView.highlights.isEmpty)
        #expect(errors.toasts.map(\.message) == ["未检测到隐私信息"])
        #expect(errors.toasts.first?.kind == .info)
    }

    @Test func failureStopsTheScanWithoutAToast() async throws {
        let h = await CanvasHarness()
        defer { h.tearDown() }
        let errors = RecordingErrors()
        let s = services(h, pipeline: FakeMosaicPipeline(store: h.store, rects: [], fails: true), errors: errors)
        await #expect(throws: AppError.self) { try await s.smartMosaic(h.id, on: h.canvas) }
        #expect(!h.canvas.isScanning)
        #expect(errors.toasts.isEmpty)
    }
}
