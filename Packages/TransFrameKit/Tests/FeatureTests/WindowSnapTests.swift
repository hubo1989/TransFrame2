import AppKit
import Testing
import TFDomain
import TFDomainTestSupport
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
    private func frames(pointer: QuartzPoint) -> FrozenFrameSet {
        FrozenFrameSet(
            request: CaptureRequest(intent: .region, trigger: .programmatic, pointer: pointer),
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

    @Test func aSelectedWindowSavesInsideAndClosesOnAnOutsideClick() {
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

    @Test func cyclingKeepsTheHighlightedWindowAsTheSaveTarget() {
        let pointer = QuartzPoint(x: 350, y: 250)
        let model = SelectionModel(frames: frames(pointer: pointer))
        model.cycleCandidates()
        #expect(model.hovered?.source == .window(WindowID(20)))
        #expect(model.doubleClickTarget(at: pointer)?.1 == .window(WindowID(20)))
    }

    @Test func hoverRevealsTheWindowThroughTheScrim() throws {
        let pointer = QuartzPoint(x: 350, y: 250)
        let frozen = frames(pointer: pointer)
        let view = try OverlayView(frame: #require(frozen.frames.first))
        let model = SelectionModel(frames: frozen)
        view.render(selection: nil, candidate: model.hovered?.rect, showHandles: false, pointer: pointer, showMagnifier: false, hex: nil)
        let scrim = try #require(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        let path = try #require(scrim.path)
        #expect(!path.contains(pointer.raw, using: .evenOdd))
        #expect(path.contains(CGPoint(x: 25, y: 25), using: .evenOdd))
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
