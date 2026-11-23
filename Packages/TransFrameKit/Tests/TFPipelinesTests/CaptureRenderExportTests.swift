import CoreGraphics
import Foundation
import Testing
import TFDomain
import TFDomainTestSupport
@testable import TFPipelines

private struct FixtureContentBlocks: ContentBlockDetecting {
    let candidates: [SelectionCandidate]

    func blocks(in frame: CapturedFrame) async throws(AppError) -> [SelectionCandidate] {
        guard frame.display.id == DisplayID(1) else { throw .recognition(.imageUnreadable) }
        return candidates
    }
}

@Suite("Capture, color and render workflows")
struct CaptureRenderWorkflowTests {
    @Test func freezesRequestsAndReturnsRankedCandidatesFromSuccessfulDisplays() async throws {
        let frames = TestImages.frozen([
            TestImages.display(1, x: 0, y: 0, width: 100, height: 80), TestImages.display(2, x: -100, y: 0, width: 100, height: 80),
        ])
        let snapshotter = FakeSnapshotter(frames: frames)
        let performance = FakePerformanceRecorder()
        let main = SelectionCandidate(kind: .paragraph, rect: QuartzRect(x: 10, y: 10, width: 20, height: 20), score: 0.9)
        let duplicate = SelectionCandidate(kind: .paragraph, rect: main.rect.offsetBy(dx: 1, dy: 0), score: 0.8)
        let smaller = SelectionCandidate(kind: .figure, rect: QuartzRect(x: 60, y: 20, width: 10, height: 10), score: 0.9)
        let detector = FixtureContentBlocks(candidates: [duplicate, main, smaller])
        let service = CaptureService(snapshotter: snapshotter, blocks: detector, performance: performance)
        let request = CaptureRequest(intent: .fullDisplay, trigger: .hotkey, pointer: QuartzPoint(x: -70, y: 20), excludedWindows: [WindowID(9)])
        let first = try await service.freeze(request)
        _ = try await service.freeze(request)
        #expect(first.frames.count == 2)
        #expect(snapshotter.requests.calls.map(\.id) == [request.id, request.id])
        #expect(snapshotter.requests.calls.first?.excludedWindows == [WindowID(9)])
        #expect(performance.samples("freeze").map(\.state) == [.cold, .warm])
        #expect(performance.samples("freeze").first?.displays == 2)
        #expect(await service.contentBlocks(in: first) == [smaller, main])
        #expect(performance.samples(Budget.blockDetection).first?.displays == 2)

        let withoutDetector = CaptureService(snapshotter: snapshotter, blocks: nil, performance: performance)
        #expect(await withoutDetector.contentBlocks(in: first).isEmpty)
        snapshotter.result.current = .failure(.capture(.timedOut))
        await #expect(throws: AppError.capture(.timedOut)) { _ = try await service.freeze(request) }
        #expect(performance.samples("freeze").count == 2)
    }

    @Test func colorPickerRoutesClipboardAndHistoryByPurpose() async throws {
        let color = try #require(RGBA(hex: "#203040"))
        let sampler = FakeColorSampler()
        let history = FakeHistoryWorkflow()
        let pasteboard = FakePasteboard()
        let service = ColorPickService(sampler: sampler, pasteboard: pasteboard, history: history)
        let settings = SettingsSnapshot()
        #expect(try await service.pickAndCopy(settings: settings) == nil)
        #expect(await service.pickForAnnotation(settings: settings) == nil)
        #expect(history.recorded.calls.isEmpty && pasteboard.contents.current.isEmpty)
        sampler.next.current = color
        #expect(try await service.pickAndCopy(settings: settings) == color)
        #expect(pasteboard.lastString == "#203040")
        #expect(await service.pickForAnnotation(settings: settings) == color)
        #expect(pasteboard.contents.current.count == 1)
        #expect(history.recorded.calls.map(\.kind) == [.color, .color])
        #expect(history.recorded.calls.map(\.result) == ["#203040", "#203040"])
        try await service.copy(color, format: .rgb)
        #expect(pasteboard.lastString == "rgb(32, 48, 64)")
        #expect(history.recorded.count == 2)
    }

    @Test func renderUsesSameSnapshotAndExecutorForPlanImageAndDraw() async throws {
        let fixture = DocumentWorkflowFixture()
        var session = fixture.session()
        let note = Annotation.text(TextAnnotation(anchor: DocumentPoint(x: 3, y: 4), text: "draft", color: .black, fontSize: 12))
        session.annotations = [note]
        let id = await fixture.sessions.insert(session)
        let render = fixture.render
        let full = try await render.plan(for: id, purpose: .screen)
        let without = try await render.plan(for: id, purpose: .screen, excluding: [note.id])
        #expect(full.layers.count == 2 && without.layers.count == 1)
        #expect(without.canvas == full.canvas)
        let context = try #require(TestImages.context(width: 100, height: 80))
        render.draw(full, base: session.baseImage, in: context)
        let image = try await render.image(for: id, purpose: .screen)
        #expect(image.pixelSize == full.canvas)
        #expect(fixture.executor.plans.calls == [full, full])
        #expect(fixture.performance.samples(Budget.renderPlan).count == 2)
        #expect(fixture.performance.samples(Budget.renderExecute).first?.scale == 1)
    }

    @Test func performanceRecorderEvictsOldSamplesAndPreservesReportedUnits() async throws {
        let recorder = PerformanceRecorder(subsystem: "fixture.transframe", limit: 2)
        recorder.record(PerformanceSample(budget: "evicted", duration: .milliseconds(1)))
        recorder.record(PerformanceSample(budget: Budget.renderPlan, state: .cold, duration: .milliseconds(3)))
        recorder.record(PerformanceSample(budget: Budget.cacheHit, duration: .milliseconds(12) + .microseconds(34), fromCache: true))
        let samples = await recorder.samples()
        #expect(samples.map(\.budget) == [Budget.renderPlan, Budget.cacheHit])
        #expect(samples.last?.durationNanoseconds == 12_034_000)
        #expect(samples.last?.fromCache == true)
        #expect(try JSONDecoder().decode([PerformanceSample].self, from: recorder.exportJSON()) == samples)
    }
}

@Suite("Export side effects and saved revisions")
struct ExportWorkflowTests {
    private let fixture = DocumentWorkflowFixture()
    private let files = FakeFileExporter()
    private let pasteboard = FakePasteboard()
    private let codec = FakeImageCodec()
    private let sound = FakeSound()
    private let uploader = FakeImageUploader()

    private func service(namer: FileNamer = FileNamer()) -> ExportService {
        ExportService(
            sessions: fixture.sessions, render: fixture.render, pasteboard: pasteboard, encoder: codec, files: files, sound: sound,
            uploader: uploader, history: fixture.history, namer: namer, guardian: PrivacyGuard(detector: nil),
            defaultDirectory: { URL(fileURLWithPath: "/fixture/default") }, now: { Date(timeIntervalSince1970: 0) }
        )
    }

    @Test func copiesRenderedImageAndSavesConfiguredFormatAndSuggestedName() async throws {
        let suggestions = CallLog<SessionID>()
        let service = service(namer: FileNamer { session, _ in
            suggestions.append(session.id)
            return " ./Release: notes "
        })
        var session = fixture.session()
        session.editRevision = 3
        let id = await fixture.sessions.insert(session)
        var settings = SettingsSnapshot()
        settings.general.saveLocationPath = "/fixture/custom"
        settings.export.format = .jpeg
        settings.export.jpegQuality = 0.51
        settings.ai.autoNaming = true
        try await service.copyImage(of: id, settings: settings)
        #expect(pasteboard.contents.current.count == 1)
        #expect(try await fixture.sessions.snapshot(of: id).hasUnsavedEdits)
        let receipt = try await service.save(id, as: nil, settings: settings)
        #expect(receipt.usedSuggestedName)
        #expect(receipt.url.path == "/fixture/custom/Release notes.jpg")
        #expect(codec.encoded.calls.first?.0 == .jpeg && codec.encoded.calls.first?.1 == 0.51)
        #expect(fixture.executor.plans.calls.map(\.background) == [.transparent, .white])
        let saved = try await fixture.sessions.snapshot(of: id)
        #expect(saved.lastSavedRevision == 3 && !saved.hasUnsavedEdits)
        #expect(saved.suggestedName == "Release notes")
        #expect(sound.played.calls == [.capture, .capture])
        _ = try await service.save(id, as: .png, settings: settings)
        #expect(suggestions.calls == [id])
    }

    @Test func failedSaveDoesNotMarkRevisionSavedPlaySoundOrWriteClipboard() async throws {
        let id = await fixture.sessions.insert(fixture.session())
        let error = AppError.persistence(.writeFailed)
        files.failure.current = error
        let settings = SettingsSnapshot()
        await #expect(throws: error) { _ = try await service().save(id, as: .png, settings: settings) }
        #expect(try await fixture.sessions.snapshot(of: id).lastSavedRevision == nil)
        #expect(sound.played.calls.isEmpty && pasteboard.contents.current.isEmpty)
    }

    @Test func uploadWritesReceiptToHistoryAndKeepsExportNamePrivate() async throws {
        let service = service()
        var session = fixture.session()
        session.suggestedName = "private title"
        let id = await fixture.sessions.insert(session)
        let defaults = SettingsSnapshot()
        await #expect(throws: AppError.upload(.notConfigured)) { _ = try await service.upload(id, settings: defaults) }
        #expect(uploader.objectNames.calls.isEmpty)
        var settings = defaults
        settings.imageHost.provider = .hostPicGo
        settings.privacy.guardEnabled = false
        settings.general.playsSound = false
        let receipt = try await service.upload(id, settings: settings)
        let name = try #require(uploader.objectNames.calls.first)
        #expect(name.hasPrefix("screenshot-") && name.hasSuffix(".png") && !name.contains("private"))
        #expect(pasteboard.lastString == receipt.url.absoluteString)
        let history = try #require(fixture.history.recorded.calls.first)
        #expect(history.kind == .upload && history.result == receipt.url.absoluteString && history.source == receipt.markdown)
        #expect(history.engine == .hostPicGo && sound.played.calls.isEmpty)
    }
}
