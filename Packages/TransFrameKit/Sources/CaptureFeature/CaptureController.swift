import AppKit
import Observation
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization
import TFWorkspaceUI

/// One frozen capture: overlays on every display, the selection, the in-place toolbar and drawer.
/// The frozen frames are dropped as soon as the session ends (SPEC §02 §3).
@MainActor
final class CaptureController: OverlayViewDelegate {
    let selection: SelectionModel
    private var frames: FrozenFrameSet?
    private let deps: CaptureDependencies
    private let onFinish: () -> Void
    private var overlays: [OverlayView] = []
    private var windows: [OverlayWindow] = []
    private var toolbarPanel: NSPanel?
    private var drawerPanel: NSPanel?
    private(set) var sessionID: SessionID?
    private var canvas: DocumentCanvasView?
    private(set) var editor: AnnotationEditor?
    private var observer: DocumentObserver?
    private(set) var results: ResultsModel?
    private var busy = false
    private var escapeMonitor: Any?
    private let owner: SessionOwner
    let toolbarModel = ToolbarModel()
    private var creating: Task<SessionID?, Never>?
    private var finished = false

    init(frames: FrozenFrameSet, deps: CaptureDependencies, onFinish: @escaping () -> Void) {
        self.frames = frames
        self.deps = deps
        self.onFinish = onFinish
        selection = SelectionModel(frames: frames)
        owner = .capture(frames.request.id)
    }

    private var services: WorkspaceServices { deps.workspace }
    private var l10n: Localizer { services.localizer }

    // MARK: Presentation

    func present() {
        guard let frames else { return }
        let primaryHeight = frames.topology.display(frames.topology.primary)?.frame.height ?? frames.topology.displays[0].frame.height
        for frame in frames.frames {
            let window = OverlayWindow(display: frame.display, primaryHeight: primaryHeight)
            let view = OverlayView(frame: frame)
            view.delegate = self
            window.contentView = view
            windows.append(window)
            overlays.append(view)
        }
        NSApp.activate()
        for window in windows { window.orderFrontRegardless() }
        let pointerWindow = zip(overlays, windows).first { $0.0.display.frame.contains(frames.request.pointer) }?.1 ?? windows.first
        pointerWindow?.makeKey()
        if let pointerWindow { pointerWindow.makeFirstResponder(pointerWindow.contentView) }
        refresh()
        CATransaction.flush()
        recordFrozenVisible(frames)
        // Global Esc fallback while the app is not active (CAP-14).
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.cancel() }
        }
        Task { [weak self] in
            guard let self, let frames = self.frames else { return }
            let blocks = await self.deps.capture.contentBlocks(in: frames)
            self.selection.setBlocks(blocks)
            self.refresh()
        }
        if frames.request.intent == .scroll { toolbarModel.scrollMode = true }
    }

    private func recordFrozenVisible(_ frames: FrozenFrameSet) {
        let elapsed = ContinuousClock.now - frames.request.triggerInstant
        let budget = frames.frames.count > 1 ? Budget.triggerToFrozenDual : Budget.triggerToFrozenSingle
        services.performance.record(PerformanceSample(budget: budget, operation: frames.request.id.shortDescription, duration: elapsed, displays: frames.frames.count))
    }

    private func refresh() {
        let showHandles = selection.phase == .selected && !selection.isLocked
        let showMagnifier = selection.phase != .selected
        let hex = overlays.lazy.compactMap { $0.hex(at: self.selection.pointer) }.first
        for overlay in overlays {
            overlay.labelTexts = (selection.hovered?.title, selection.pixelSizeLabel)
            overlay.render(
                selection: selection.rect, candidate: selection.phase == .choosing ? selection.hovered?.rect : nil,
                showHandles: showHandles, pointer: selection.pointer, showMagnifier: showMagnifier, hex: hex
            )
        }
        layoutToolbar()
    }

    // MARK: Overlay events

    func overlayMouseMoved(_ point: QuartzPoint) {
        let start = ContinuousClock.now
        selection.pointerMoved(to: point)
        refresh()
        services.performance.record(PerformanceSample(budget: Budget.overlayEventHandling, duration: .now - start))
    }

    func overlayMouseDown(_ point: QuartzPoint, clickCount: Int) {
        guard !busy else { return }
        if clickCount >= 2, selection.isLocked, !(selection.rect?.contains(point) ?? false) { return }
        if clickCount >= 2, let target = selection.doubleClickTarget(at: point) {
            if sessionID != nil, target.0 != selection.rect { discardSession() }
            selection.select(target.0, source: target.1)
            refresh()
            perform(.copy)
            return
        }
        if selection.phase == .selected, sessionID != nil, selection.isLocked { return }
        selection.mouseDown(at: point)
        refresh()
    }

    func overlayMouseDragged(_ point: QuartzPoint) {
        let start = ContinuousClock.now
        selection.mouseDragged(to: point)
        if sessionID != nil, !selection.isLocked { discardSession() }
        refresh()
        services.performance.record(PerformanceSample(budget: Budget.overlayEventHandling, duration: .now - start))
    }

    func overlayMouseUp(_ point: QuartzPoint) {
        let created = selection.mouseUp(at: point)
        refresh()
        if created, frames?.request.intent == .regionThenTranslate { perform(.translate) }
        if created, toolbarModel.scrollMode { perform(.scroll) }
    }

    func overlayRightMouseDown() { cancel() }

    func overlayKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 53: // Esc: text → selection → tool → drawer → capture (EDT-08, INP-12)
            if editor?.cancelStep() == true { return true }
            if drawerPanel != nil { closeDrawer(); return true }
            cancel(); return true
        case 36, 76: // Enter
            if selection.rect != nil { perform(.copy) }
            return true
        case 48: selection.cycleCandidates(); refresh(); return true // Tab
        case 49: selection.toggleSnapping(); refresh(); return true // Space
        case 123, 124, 125, 126:
            let step = flags.contains(.shift) ? 10.0 : 1.0
            let (dx, dy): (Double, Double) = switch event.keyCode {
            case 123: (-step, 0)
            case 124: (step, 0)
            case 125: (0, step)
            default: (0, -step)
            }
            selection.nudge(dx: dx, dy: dy, resize: flags.contains(.option))
            if sessionID != nil, !selection.isLocked { discardSession() }
            refresh()
            return true
        default: break
        }
        if flags.contains(.command) {
            switch key {
            case "s": perform(.save); return true
            case "c": perform(.copy); return true
            case "z": flags.contains(.shift) ? observer?.redo() : observer?.undo(); return true
            default: return false
            }
        }
        guard flags.isDisjoint(with: [.control, .option]) else { return false }
        if key == "c", selection.phase != .selected || editor?.tool == nil {
            copyPixelColor()
            return true
        }
        if selection.phase == .selected {
            if key == "p" { perform(.pin); return true }
            if key == "t" { perform(.translate); return true }
            if key.count == 1, let character = key.first, let tool = AnnotationTool.forKey(character) {
                selectTool(tool)
                return true
            }
        }
        return false
    }

    /// `C` copies the HEX color of the frozen pixel under the pointer (CAP-12).
    private func copyPixelColor() {
        guard let hex = overlays.lazy.compactMap({ $0.hex(at: self.selection.pointer) }).first else { return }
        let pasteboard = services.pasteboard, errors = services.errors, message = l10n.string(.feedbackColorCopied, hex)
        Task {
            try? await pasteboard.write(.string(hex))
            errors.toast(ToastModel(message: message), near: nil)
        }
    }

    // MARK: Session

    /// One creation task per controller; results arriving after the capture ended are released (review-1 P1-1).
    private func ensureSession() async -> SessionID? {
        if let sessionID { return sessionID }
        if let creating { return await creating.value }
        guard let frames, let geometry = selection.geometry() else { return nil }
        let services = services, owner = owner
        let task = Task<SessionID?, Never> { [weak self] in
            do {
                let id = try await services.sessions.create(from: frames, selection: geometry)
                await services.sessions.retain(id, by: owner)
                guard let self, !self.finished, self.selection.geometry() == geometry else {
                    await services.sessions.release(id, by: owner)
                    return nil
                }
                self.sessionID = id
                self.attachCanvas(id)
                return id
            } catch {
                services.errors.present(error, near: nil)
                return nil
            }
        }
        creating = task
        let id = await task.value
        creating = nil
        return finished ? nil : id
    }

    private func attachCanvas(_ id: SessionID) {
        guard let rect = selection.rect, let overlay = overlays.first(where: { $0.display.frame.intersects(rect) }) else { return }
        let editor = services.makeEditor(for: id)
        let canvas = DocumentCanvasView(render: services.render, sessionID: id, editor: editor)
        canvas.frame = overlay.local(rect)
        canvas.onEscapeUnhandled = { [weak self] in self?.cancel() }
        canvas.keyHandler = { [weak self] event in self?.overlayKeyDown(event) ?? false }
        let selectionFrame = canvas.frame
        canvas.onRender = { [weak canvas] plan in
            // Padding (beautify) extends outside the selection so the content stays aligned with the frozen pixels.
            let scale = plan.scale
            canvas?.frame = CGRect(
                x: selectionFrame.minX - plan.contentFrame.minX / scale, y: selectionFrame.minY - plan.contentFrame.minY / scale,
                width: Double(plan.canvas.width) / scale, height: Double(plan.canvas.height) / scale
            )
        }
        overlay.addSubview(canvas)
        let observer = DocumentObserver(sessions: services.sessions, sessionID: id)
        observer.onChange = { [weak self, weak canvas] session in
            canvas?.update(session)
            self?.results?.update(session)
            self?.selection.isLocked = !session.annotations.isEmpty || session.analysis != nil
            self?.toolbarModel.beautify = session.presentation.beautify
            self?.refresh()
        }
        observer.start()
        self.editor = editor
        self.canvas = canvas
        self.observer = observer
        toolbarModel.editor = editor
        toolbarModel.observer = observer
    }

    private func discardSession() {
        guard let id = sessionID else { return }
        canvas?.removeFromSuperview()
        observer?.stop()
        canvas = nil
        editor = nil
        observer = nil
        results = nil
        toolbarModel.editor = nil
        toolbarModel.observer = nil
        closeDrawer()
        sessionID = nil
        let sessions = services.sessions, owner = owner
        Task { await sessions.release(id, by: owner) }
    }

    private func selectTool(_ tool: AnnotationTool) {
        Task {
            guard await ensureSession() != nil, let editor else { return }
            editor.tool = editor.tool == tool ? nil : tool
            if let canvas { canvas.window?.makeFirstResponder(canvas) }
        }
    }

    // MARK: Actions (INP-01…INP-14)

    enum Action { case copy, save, pin, upload, recognize, translate, smartMosaic, beautify, cancel, scroll, tool(AnnotationTool) }

    func perform(_ action: Action) {
        guard !busy else { return }
        let settings = services.settings.snapshot
        switch action {
        case .cancel: cancel()
        case .tool(let tool): selectTool(tool)
        case .copy:
            run { id in
                try await self.services.export.copyImage(of: id, settings: settings)
                self.services.errors.toast(ToastModel(message: self.l10n[.feedbackCopied]), near: nil)
                self.finish()
            }
        case .save:
            run { id in
                let receipt = try await self.services.export.save(id, as: nil, settings: settings)
                self.services.errors.toast(ToastModel(message: self.l10n.string(.feedbackSaved, receipt.url.lastPathComponent)), near: nil)
                self.finish()
            }
        case .pin:
            run { id in
                if settings.general.playsSound { await self.deps.sound.play(.capture) }
                self.services.router.route(.pin(id))
                self.finish()
            }
        case .upload:
            run { id in
                let receipt = try await self.services.export.upload(id, settings: settings)
                self.services.errors.toast(ToastModel(message: self.l10n.string(.feedbackUploaded, receipt.url.absoluteString)), near: nil)
                self.finish()
            }
        case .recognize: openDrawer { $0.recognize() }
        case .translate: openDrawer { $0.translate() }
        case .smartMosaic:
            run(finishes: false) { id in
                guard let pipeline = self.services.pipeline else { return }
                let count = try await pipeline.smartMosaic(id, settings: settings)
                self.services.errors.toast(ToastModel(.info, message: self.l10n.string(.feedbackSmartMosaic, count)), near: nil)
            }
        case .beautify:
            run(finishes: false) { id in
                let session = try await self.services.sessions.snapshot(of: id)
                var presentation = session.presentation
                presentation.beautify.toggle()
                if let transaction = EditTransaction.setPresentation(presentation, in: session, label: "undo.presentation") {
                    try await self.services.sessions.apply(transaction, to: id)
                }
            }
        case .scroll:
            startScrollCapture()
        }
    }

    private func run(finishes: Bool = true, _ body: @escaping (SessionID) async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            guard let id = await ensureSession() else { return }
            do { try await body(id) } catch { services.errors.present(error, near: nil) }
        }
    }

    // MARK: Drawer (INP-05, INP-06, INP-11, INP-12)

    private func openDrawer(_ start: @escaping (ResultsModel) -> Void) {
        Task {
            guard let id = await ensureSession(), services.pipeline != nil else { return }
            let model = results ?? ResultsModel(services: services, sessionID: id)
            if let session = observer?.session { model.update(session) }
            results = model
            showDrawerPanel(model)
            start(model)
        }
    }

    private func showDrawerPanel(_ model: ResultsModel) {
        let panel = drawerPanel ?? Self.makePanel(level: windows.first?.level ?? .floating)
        panel.contentView = NSHostingView(rootView: ResultsDrawerView(model: model) { [weak self] in self?.closeDrawer() }.localized(l10n))
        drawerPanel = panel
        layoutToolbar()
        panel.orderFrontRegardless()
    }

    private func closeDrawer() {
        drawerPanel?.orderOut(nil)
        drawerPanel = nil
        windows.first?.makeKey()
    }

    // MARK: Toolbar placement (INP-01)

    private func layoutToolbar() {
        guard selection.phase == .selected, let rect = selection.rect, let frames else {
            toolbarPanel?.orderOut(nil)
            drawerPanel?.orderOut(nil)
            return
        }
        let primaryHeight = frames.topology.display(frames.topology.primary)?.frame.height ?? 0
        let panel = toolbarPanel ?? makeToolbarPanel()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 600, height: 44)
        let display = frames.topology.display(containing: QuartzPoint(x: rect.midX, y: rect.maxY)) ?? frames.topology.displays[0]
        var top = rect.maxY + DS.Space.s2
        if top + size.height > display.frame.maxY - DS.Space.s1 { top = rect.minY - size.height - DS.Space.s2 }
        if top < display.frame.minY { top = rect.maxY - size.height - DS.Space.s2 }
        let left = min(max(rect.maxX - size.width, display.frame.minX + DS.Space.s1), display.frame.maxX - size.width - DS.Space.s1)
        let quartz = QuartzRect(x: left, y: top, width: size.width, height: size.height)
        panel.setFrame(QuartzConversion.cocoaRect(fromQuartz: quartz, primaryHeight: primaryHeight), display: true)
        panel.orderFrontRegardless()
        if let drawer = drawerPanel {
            let drawerSize = NSSize(width: 380, height: min(max(rect.height, 280), 520))
            var x = rect.maxX + DS.Space.s2
            if x + drawerSize.width > display.frame.maxX { x = rect.minX - drawerSize.width - DS.Space.s2 }
            if x < display.frame.minX { x = display.frame.maxX - drawerSize.width - DS.Space.s1 }
            let y = min(max(rect.minY, display.frame.minY), display.frame.maxY - drawerSize.height)
            drawer.setFrame(QuartzConversion.cocoaRect(fromQuartz: QuartzRect(x: x, y: y, width: drawerSize.width, height: drawerSize.height), primaryHeight: primaryHeight), display: true)
        }
    }

    private func makeToolbarPanel() -> NSPanel {
        let panel = Self.makePanel(level: windows.first?.level ?? .floating)
        toolbarModel.uploadEnabled = services.settings.imageHost.provider != nil
        toolbarModel.pipelineEnabled = services.pipeline != nil
        toolbarModel.scrollEnabled = deps.scroll != nil
        let view = InPlaceToolbarView(model: toolbarModel) { [weak self] action in self?.perform(action) }.localized(l10n)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        toolbarPanel = panel
        return panel
    }

    static func makePanel(level: NSWindow.Level) -> NSPanel {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }

    // MARK: Scroll capture (N-09)

    private func startScrollCapture() {
        guard let scroll = deps.scroll, let rect = selection.rect else { return }
        let excluded = Set(windows.map { WindowID(UInt32($0.windowNumber)) })
        for window in windows { window.ignoresMouseEvents = true }
        for overlay in overlays { overlay.alphaValue = 0.15 }
        toolbarModel.scrollRunning = true
        Task {
            do {
                let events = try await scroll.begin(rect, excluding: excluded)
                for await event in events {
                    if case .progress(let height) = event { toolbarModel.scrollHeight = height }
                    if case .reachedLimit = event { finishScrollCapture() }
                }
            } catch {
                services.errors.present(error, near: nil)
                cancel()
            }
        }
        toolbarModel.onFinishScroll = { [weak self] in self?.finishScrollCapture() }
    }

    private func finishScrollCapture() {
        guard let scroll = deps.scroll, toolbarModel.scrollRunning else { return }
        toolbarModel.scrollRunning = false
        Task {
            do {
                let id = try await scroll.finish()
                services.router.route(.openEditor(id, focus: nil))
            } catch {
                services.errors.present(error, near: nil)
            }
            finish()
        }
    }

    // MARK: Ending

    func cancel() {
        if toolbarModel.scrollRunning { Task { await deps.scroll?.cancel() } }
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        creating?.cancel()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        results?.cancel()
        observer?.stop()
        for window in windows { window.orderOut(nil) }
        toolbarPanel?.orderOut(nil)
        drawerPanel?.orderOut(nil)
        windows.removeAll()
        overlays.removeAll()
        frames = nil
        if let id = sessionID {
            // Grace period so an editor or pin opened from this capture retains the session first (review-1 P1-2).
            let sessions = services.sessions, owner = owner
            Task {
                try? await Task.sleep(for: .seconds(2))
                await sessions.release(id, by: owner)
            }
        }
        sessionID = nil
        onFinish()
    }
}

/// Panels that can take keyboard focus (drawer text, toolbar menus).
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
