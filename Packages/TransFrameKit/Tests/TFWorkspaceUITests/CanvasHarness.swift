import AppKit
import TFDomain
import TFDomainTestSupport
import TFPipelines
import TFRenderInfra
@testable import TFWorkspaceUI

/// A real store, planner and renderer behind an annotation canvas hosted in an offscreen window.
@MainActor
final class CanvasHarness {
    let store: DocumentSessionStore
    let render: RenderService
    let editor: AnnotationEditor
    let canvas: DocumentCanvasView
    let window: NSWindow
    let observer: DocumentObserver
    let id: SessionID
    private(set) var renderedRevisions: [Int] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(width: Int = 1600, height: Int = 1000, scale: Double = 2, defaults: AnnotationDefaults = AnnotationDefaults()) async {
        store = DocumentSessionStore(composer: FakeFrameComposer())
        id = await store.create(importing: TestImages.pattern(width: width, height: height, scale: scale), name: "test")
        let renderer = CoreGraphicsRenderer()
        render = RenderService(
            sessions: store, planner: RenderPlanner(measurer: renderer), executor: renderer, performance: FakePerformanceRecorder())
        editor = AnnotationEditor(sessions: store, sessionID: id, defaults: defaults)
        canvas = DocumentCanvasView(render: render, sessionID: id, editor: editor)
        let size = NSSize(width: Double(width) / scale, height: Double(height) / scale)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content
        canvas.frame = content.bounds
        content.addSubview(canvas)
        observer = DocumentObserver(sessions: store, sessionID: id)
        observer.onChange = { [weak self] session in self?.canvas.update(session) }
        canvas.onRender = { [weak self] plan in self?.rendered(plan.editRevision) }
        observer.start()
        await waitForRender(revision: 0)
    }

    func tearDown() {
        observer.stop()
        window.close()
    }

    private func rendered(_ revision: Int) {
        renderedRevisions.append(revision)
        let ready = waiters.filter { revision >= $0.0 }
        waiters.removeAll { revision >= $0.0 }
        for waiter in ready { waiter.1.resume() }
    }

    /// Suspends until the canvas shows a render of at least `revision` (or a timeout passes).
    func waitForRender(revision: Int, timeout: Duration = .seconds(5)) async {
        if let last = renderedRevisions.last, last >= revision { return }
        let deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self else { return }
            let pending = self.waiters
            self.waiters.removeAll()
            for waiter in pending { waiter.1.resume() }
        }
        await withCheckedContinuation { waiters.append((revision, $0)) }
        deadline.cancel()
    }

    func session() async throws -> DocumentSession { try await store.snapshot(of: id) }

    /// Waits until the store has applied `count` more edits than `after`.
    func waitForRevision(_ revision: Int) async throws -> DocumentSession {
        for _ in 0..<500 {
            let s = try await session()
            if s.editRevision >= revision { return s }
            try await Task.sleep(for: .milliseconds(2))
        }
        return try await session()
    }

    // MARK: Events (points in canvas view coordinates)

    func event(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: canvas.convert(point, to: nil), modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func down(_ p: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) { canvas.mouseDown(with: event(.leftMouseDown, p, clicks: clicks, flags: flags)) }
    func drag(_ p: CGPoint, flags: NSEvent.ModifierFlags = []) { canvas.mouseDragged(with: event(.leftMouseDragged, p, flags: flags)) }
    func up(_ p: CGPoint) { canvas.mouseUp(with: event(.leftMouseUp, p)) }

    func key(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        canvas.keyDown(with: event)
    }

    /// Draws one gesture and waits for the store and the canvas to catch up.
    @discardableResult
    func drawGesture(from a: CGPoint, to b: CGPoint, steps: Int = 8, flags: NSEvent.ModifierFlags = []) async throws -> DocumentSession {
        let before = try await session().editRevision
        down(a, flags: flags)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            drag(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), flags: flags)
        }
        up(b)
        let after = try await waitForRevision(before + 1)
        await waitForRender(revision: after.editRevision)
        return after
    }
}
