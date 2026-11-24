import AppKit
import Testing
import TFDesignSystem
import TFDomain
import TFDomainTestSupport
import TFLocalization
import TFPipelines
import TFWorkspaceUI
@testable import CaptureFeature

/// Window detection on the frozen screen (CAP-05, CAP-06, CAP-13) and its setting.
@Suite("Window snapping")
@MainActor
struct WindowSnapTests {
    private let display = DisplayDescriptor(
        id: DisplayID(1), localizedName: "Main", frame: QuartzRect(x: 0, y: 0, width: 1000, height: 800),
        pixelSize: PixelSize(width: 2000, height: 1600), scale: 2)

    private func window(_ id: UInt32, _ rect: QuartzRect, title: String) -> WindowCandidate {
        WindowCandidate(id: WindowID(id), ownerPID: 1, ownerBundleID: nil, ownerName: "App", title: title, frame: rect, layer: 0, kind: .window, isStable: true)
    }

    /// Front-to-back like the window server: the editor covers part of the browser.
    private func frames(pointer: QuartzPoint, intent: CaptureIntent = .region) -> FrozenFrameSet {
        FrozenFrameSet(
            request: CaptureRequest(intent: intent, trigger: .programmatic, pointer: pointer),
            topology: DisplayTopology(version: 1, displays: [display], primary: display.id),
            frames: [CapturedFrame(display: display, image: TestImages.solid(width: 2000, height: 1600, scale: 2), requestedAt: .now, completedAt: .now)],
            windows: [
                window(10, QuartzRect(x: 300, y: 200, width: 400, height: 300), title: "Editor"),
                window(20, QuartzRect(x: 100, y: 100, width: 500, height: 400), title: "Browser"),
            ])
    }

    @Test func hoverHighlightsTheTopWindowAndAClickSelectsIt() {
        let model = SelectionModel(frames: frames(pointer: QuartzPoint(x: 350, y: 250)))
        #expect(model.hovered?.title == "Editor")
        model.pointerMoved(to: QuartzPoint(x: 150, y: 150))
        #expect(model.hovered?.title == "Browser")
        model.mouseDown(at: QuartzPoint(x: 150, y: 150))
        #expect(model.mouseUp(at: QuartzPoint(x: 150, y: 150)))
        #expect(model.phase == .selected)
        #expect(model.rect == QuartzRect(x: 100, y: 100, width: 500, height: 400))
        #expect(model.source == .window(WindowID(20)))
    }

    @Test func doubleClickCapturesTheWindowUnderThePointer() {
        let model = SelectionModel(frames: frames(pointer: QuartzPoint(x: 350, y: 250)))
        let target = model.doubleClickTarget(at: QuartzPoint(x: 350, y: 250))
        #expect(target?.0 == QuartzRect(x: 300, y: 200, width: 400, height: 300))
        #expect(target?.1 == .window(WindowID(10)))
        // Outside every window: the whole display.
        #expect(model.doubleClickTarget(at: QuartzPoint(x: 900, y: 700))?.0 == display.frame)
    }

    @Test func aSelectedWindowTargetsCopyInsideAndClosesOnAnOutsideClick() {
        let inside = QuartzPoint(x: 350, y: 250), outside = QuartzPoint(x: 150, y: 150)
        let model = SelectionModel(frames: frames(pointer: inside))
        model.mouseDown(at: inside)
        #expect(model.mouseUp(at: inside))
        #expect(model.doubleClickTarget(at: inside)?.1 == .window(WindowID(10)))
        #expect(model.doubleClickTarget(at: outside) == nil)

        for locked in [false, true] {
            model.isLocked = locked
            model.mouseDown(at: outside)
            #expect(model.isOutsideClick(at: outside))
            #expect(!model.mouseUp(at: outside))
        }
        #expect(model.source == .window(WindowID(10)))
    }

    @Test func draggingFromOutsideCanReplaceAnUnlockedSelection() {
        let inside = QuartzPoint(x: 350, y: 250), outside = QuartzPoint(x: 150, y: 150)
        let end = QuartzPoint(x: 50, y: 50)
        let model = SelectionModel(frames: frames(pointer: inside))
        model.mouseDown(at: inside)
        #expect(model.mouseUp(at: inside))
        model.mouseDown(at: outside)
        model.mouseDragged(to: end)
        #expect(!model.isOutsideClick(at: end))
        #expect(model.mouseUp(at: end))
        #expect(model.rect == QuartzRect(x: 50, y: 50, width: 100, height: 100))

        let handle = QuartzPoint(x: 49, y: 50)
        model.mouseDown(at: handle)
        #expect(!model.isOutsideClick(at: handle))
    }

    @Test func cyclingKeepsTheHighlightedWindowAsTheCopyTarget() {
        let pointer = QuartzPoint(x: 350, y: 250)
        let model = SelectionModel(frames: frames(pointer: pointer))
        model.cycleCandidates()
        #expect(model.hovered?.source == .window(WindowID(20)))
        #expect(model.doubleClickTarget(at: pointer)?.1 == .window(WindowID(20)))
    }

    @Test func aCycledWindowSurvivesLateBlocksAndSmallPointerMovement() {
        let pointer = QuartzPoint(x: 350, y: 250)
        let model = SelectionModel(frames: frames(pointer: pointer))
        model.cycleCandidates()
        let block = SelectionCandidate(kind: .paragraph, rect: QuartzRect(x: 330, y: 230, width: 40, height: 40), score: 0.9)
        model.setBlocks([block])

        let nearby = QuartzPoint(x: 351, y: 251)
        #expect(model.hovered?.source == .window(WindowID(20)))
        #expect(model.doubleClickTarget(at: nearby)?.1 == .window(WindowID(20)))
        model.pointerMoved(to: nearby)
        #expect(model.hovered?.source == .window(WindowID(20)))
        model.cycleCandidates()
        #expect(model.hovered?.source == .window(WindowID(10)))
    }

    @Test func hoverRevealsTheWindowThroughTheScrim() throws {
        let pointer = QuartzPoint(x: 350, y: 250)
        let frozen = frames(pointer: pointer)
        let view = try OverlayView(frame: #require(frozen.frames.first))
        let model = SelectionModel(frames: frozen)
        view.render(selection: nil, candidate: model.hovered?.rect, showHandles: false, pointer: pointer, showMagnifier: false, hex: nil)
        let context = try #require(TestImages.context(width: 1000, height: 800))
        let layer = try #require(view.layer)
        layer.render(in: context)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let middleRow = 400 * context.bytesPerRow
        #expect(pixels[middleRow + 350 * 4] > pixels[middleRow + 25 * 4])
    }

    enum Gesture: CaseIterable { case windowClick, windowDoubleClick, regionDoubleClick }

    @Test(arguments: Gesture.allCases)
    func windowClickStartsScrollAndDoubleClickCopies(gesture: Gesture) async throws {
        let pointer = QuartzPoint(x: 350, y: 250)
        let frozen = frames(pointer: pointer, intent: gesture == .regionDoubleClick ? .region : .scroll)
        let sessions = DocumentSessionStore(composer: FakeFrameComposer())
        let files = FakeFileExporter(), pasteboard = FakePasteboard(), sound = FakeSound(), performance = FakePerformanceRecorder()
        let render = RenderService(
            sessions: sessions, planner: RenderPlanner(measurer: FakeTextMeasurer()), executor: FakeRenderExecutor(), performance: performance)
        let export = ExportService(
            sessions: sessions, render: render, pasteboard: pasteboard, encoder: FakeImageCodec(), files: files, sound: sound, uploader: nil,
            history: nil, namer: FileNamer(), guardian: PrivacyGuard(detector: FakeSensitiveDetector([])),
            defaultDirectory: { FileManager.default.temporaryDirectory })
        let workspace = WorkspaceServices(
            sessions: sessions, render: render, export: export, pipeline: nil, glossary: nil,
            colorPick: ColorPickService(sampler: FakeColorSampler(), pasteboard: pasteboard, history: FakeHistoryWorkflow()),
            pasteboard: pasteboard, settings: FakeSettings(), localizer: Localizer(preference: "en"), errors: CaptureTestErrors(),
            router: FakeRouter(), performance: performance)
        let scroll = RecordingScroll()
        let deps = CaptureDependencies(
            workspace: workspace, capture: CaptureService(snapshotter: FakeSnapshotter(), blocks: nil, performance: performance),
            topology: CaptureTestTopology(frames: frozen), permissions: FakePermissions(granted: [.screenRecording]), scroll: scroll, sound: sound)
        var finished = false
        let controller = CaptureController(frames: frozen, deps: deps, doubleClickInterval: .milliseconds(75)) { finished = true }
        defer { controller.cancel() }

        if gesture == .regionDoubleClick {
            let start = QuartzPoint(x: 300, y: 200), end = QuartzPoint(x: 700, y: 500)
            controller.overlayMouseDown(start, clickCount: 1)
            controller.overlayMouseDragged(end)
            controller.overlayMouseUp(end)
            #expect(controller.selection.source == .freeform)
        } else {
            controller.overlayMouseDown(pointer, clickCount: 1)
            controller.overlayMouseUp(pointer)
            #expect(controller.selection.source == .window(WindowID(10)))
        }
        #expect(!controller.toolbarModel.scrollRunning)
        if gesture != .windowClick { controller.overlayMouseDown(pointer, clickCount: 2) }

        let deadline = ContinuousClock.now + .seconds(2)
        while !finished, scroll.started.calls.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if gesture != .windowClick {
            #expect(finished)
            let contents = pasteboard.contents.current
            #expect(contents == [.image(Data(count: 800 * 600))])
            #expect(scroll.started.calls.isEmpty)
        } else {
            #expect(scroll.started.calls == [QuartzRect(x: 300, y: 200, width: 400, height: 300)])
            #expect(pasteboard.contents.current.isEmpty)
        }
        #expect(files.written.calls.isEmpty)
    }

    @Test func turnedOffNothingIsHighlightedAndDoubleClickTakesTheDisplay() {
        let model = SelectionModel(frames: frames(pointer: QuartzPoint(x: 350, y: 250)), snapsToWindows: false)
        #expect(model.hovered == nil)
        model.mouseDown(at: QuartzPoint(x: 350, y: 250))
        #expect(!model.mouseUp(at: QuartzPoint(x: 350, y: 250)))
        #expect(model.phase == .choosing)
        #expect(model.doubleClickTarget(at: QuartzPoint(x: 350, y: 250))?.0 == display.frame)
        // Space turns it on for this capture.
        model.toggleSnapping()
        #expect(model.hovered?.title == "Editor")
    }

    @Test func settingDefaultsOnAndOlderSettingsDecodeWithIt() throws {
        #expect(GeneralSettings().detectsWindows)
        let old = try JSONDecoder().decode(GeneralSettings.self, from: Data(#"{"schemaVersion":1,"playsSound":false}"#.utf8))
        #expect(old.detectsWindows)
        #expect(!old.playsSound)
    }
}

private struct CaptureTestTopology: DisplayTopologyProviding {
    let frames: FrozenFrameSet
    func topology() async throws(AppError) -> DisplayTopology { frames.topology }
    func pointerLocation() -> QuartzPoint { frames.request.pointer }
}

private struct RecordingScroll: ScrollCaptureWorkflow {
    let started = CallLog<QuartzRect>()
    func begin(_ rect: QuartzRect, excluding: Set<WindowID>) async throws(AppError) -> AsyncStream<ScrollCaptureEvent> {
        started.append(rect)
        return AsyncStream { $0.finish() }
    }
    func finish() async throws(AppError) -> SessionID { throw .cancelled }
    func cancel() async {}
}

private final class CaptureTestErrors: ErrorPresenting {
    func present(_ error: AppError, near anchor: CGPoint?, retry: (() -> Void)?) { Issue.record("Unexpected capture error: \(error)") }
    func toast(_ model: ToastModel, near anchor: CGPoint?, action: (() -> Void)?) {}
}
