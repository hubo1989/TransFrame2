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
    private let doubleClickInterval: Duration
    private let onFinish: () -> Void
    private var overlays: [OverlayView] = []
    private var windows: [OverlayWindow] = []
    private var toolbarPanel: NSPanel?
    private var drawerPanel: NSPanel?
    private(set) var sessionID: SessionID?
    /// The primary canvas first, then mirrors on the other displays the selection touches.
    private var canvases: [DocumentCanvasView] = []
    private var canvas: DocumentCanvasView? { canvases.first }
    private(set) var editor: AnnotationEditor?
    private var observer: DocumentObserver?
    private(set) var results: ResultsModel?
    private var busy = false
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private let owner: SessionOwner
    let toolbarModel = ToolbarModel()
    private var creating: Task<SessionID?, Never>?
    private var pendingSelectionAction: Task<Void, Never>?
    private var finished = false
    /// Last toolbar placement; the panel is only moved when the selection or the toolbar size changes.
    private var toolbarPlacement: ToolbarPlacement?
    private var toolbarSize: NSSize?

    private struct ToolbarPlacement: Equatable {
        let rect: QuartzRect
        let size: NSSize
        let hasDrawer: Bool
    }

    init(
        frames: FrozenFrameSet, deps: CaptureDependencies,
        doubleClickInterval: Duration = .seconds(NSEvent.doubleClickInterval), onFinish: @escaping () -> Void
    ) {
        self.frames = frames
        self.deps = deps
        self.doubleClickInterval = doubleClickInterval
        self.onFinish = onFinish
        selection = SelectionModel(frames: frames, snapsToWindows: deps.workspace.settings.general.detectsWindows)
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
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, let window = event.window ?? NSApp.keyWindow,
                  self.windows.contains(where: { $0 === window }) || self.toolbarPanel === window || self.drawerPanel === window
            else { return event }
            self.cancel()
            return nil
        }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.cancel() }
        }
        // Content blocks (local Vision text regions) are only snap candidates with window detection on.
        if selection.snapsToWindows {
            Task { [weak self] in
                guard let self, let frames = self.frames else { return }
                let blocks = await self.deps.capture.contentBlocks(in: frames)
                self.selection.setBlocks(blocks)
                self.refresh()
            }
        }
    }

    private func recordFrozenVisible(_ frames: FrozenFrameSet) {
        let elapsed = ContinuousClock.now - frames.request.triggerInstant
        let budget = frames.frames.count > 1 ? Budget.triggerToFrozenDual : Budget.triggerToFrozenSingle
        services.performance.record(
            PerformanceSample(budget: budget, operation: frames.request.id.shortDescription, duration: elapsed, displays: frames.frames.count))
    }

    private func refresh() {
        guard !overlays.isEmpty else { return }
        let showHandles = selection.phase == .selected && !selection.isLocked
        let showMagnifier = selection.phase != .selected
        let hex = showMagnifier ? overlays.lazy.compactMap { $0.hex(at: self.selection.pointer) }.first : nil
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
        guard !busy, !finished else { return }
        if clickCount >= 2, let target = selection.doubleClickTarget(at: point) {
            selection.select(target.0, source: target.1)
            refresh()
            perform(.copy)
            return
        }
        selection.mouseDown(at: point)
        refresh()
    }

    func overlayMouseDragged(_ point: QuartzPoint) {
        guard !busy, !finished else { return }
        let start = ContinuousClock.now
        let previousGeometry = selection.geometry()
        selection.mouseDragged(to: point)
        if sessionID != nil, selection.geometry() != previousGeometry { discardSession() }
        refresh()
        services.performance.record(PerformanceSample(budget: Budget.overlayEventHandling, duration: .now - start))
    }

    func overlayMouseUp(_ point: QuartzPoint) {
        guard !busy, !finished else { return }
        let outsideClick = selection.isOutsideClick(at: point)
        let wasDragging = selection.phase == .dragging
        let created = selection.mouseUp(at: point)
        if outsideClick { cancel(); return }
        refresh()
        if created { performSelectionAction(waitForDoubleClick: !wasDragging) }
    }

    private func performSelectionAction(waitForDoubleClick: Bool) {
        let action: Action
        switch frames?.request.intent {
        case .regionThenTranslate: action = .translate
        case .scroll: action = .scroll
        default: return
        }
        guard waitForDoubleClick else { perform(action); return }
        pendingSelectionAction?.cancel()
        let geometry = selection.geometry()
        pendingSelectionAction = Task { [weak self, doubleClickInterval] in
            do { try await Task.sleep(for: doubleClickInterval) } catch { return }
            guard let self, !Task.isCancelled, self.selection.phase == .selected, self.selection.geometry() == geometry else { return }
            self.perform(action)
        }
    }

    func overlayRightMouseDown() { cancel() }

    private func handleCommandKey(_ key: String, shifted: Bool) -> Bool {
        switch key {
        case "s": perform(.save)
        case "c": perform(.copy)
        case "z":
            if shifted { observer?.redo() } else { observer?.undo() }
        default: return false
        }
        return true
    }

    func overlayKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 53: // Esc
            cancel(); return true
        case 36, 76: // Enter
            if selection.rect != nil { perform(.copy) }
            return true
        case 48: selection.cycleCandidates(); refresh(); return true // Tab
        case 49: selection.toggleSnapping(); refresh(); return true // Space
        case 123, 124, 125, 126:
            // A selected annotation moves first; otherwise the selection does (INP-01).
            if let editor, editor.selectedID != nil {
                return editor.handleKey(key, keyCode: event.keyCode, modifiers: flags)
            }
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
        if flags.contains(.command) { return handleCommandKey(key, shifted: flags.contains(.shift)) }
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
}

extension CaptureController {
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
        // One canvas per display the selection touches, all driving the same editor: annotations draw and can be edited on
        // every display. The display holding most of the selection hosts the primary canvas (text input, settling).
        guard let rect = selection.rect else { return }
        let touched = overlays.filter { ($0.display.frame.intersection(rect)?.area ?? 0) > 0 }
            .sorted { ($0.display.frame.intersection(rect)?.area ?? 0) > ($1.display.frame.intersection(rect)?.area ?? 0) }
        guard !touched.isEmpty else { return }
        let editor = services.makeEditor(for: id)
        let canvases = touched.enumerated().map { index, overlay -> DocumentCanvasView in
            let canvas = DocumentCanvasView(render: services.render, sessionID: id, editor: editor)
            canvas.isMirror = index > 0
            canvas.frame = overlay.local(rect)
            canvas.onEscapeUnhandled = { [weak self] in self?.cancel() }
            canvas.keyHandler = { [weak self] event in self?.overlayKeyDown(event) ?? false }
            canvas.mouseDownHandler = { [weak self, weak editor] event, point in
                guard let self, let editor, event.clickCount >= 2, editor.tool == nil, editor.textEditing == nil, editor.hitTest(point) == nil
                else { return false }
                self.perform(.copy)
                return true
            }
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
            return canvas
        }
        let observer = DocumentObserver(sessions: services.sessions, sessionID: id)
        observer.onChange = { [weak self] session in
            guard let self else { return }
            for canvas in self.canvases { canvas.update(session) }
            self.results?.update(session)
            let locked = !session.annotations.isEmpty || session.analysis != nil
            let lockChanged = self.selection.isLocked != locked
            if lockChanged { self.selection.isLocked = locked }
            if self.toolbarModel.beautify != session.presentation.beautify { self.toolbarModel.beautify = session.presentation.beautify }
            if lockChanged { self.refresh() }
        }
        observer.start()
        self.editor = editor
        self.canvases = canvases
        self.observer = observer
        toolbarModel.editor = editor
        toolbarModel.observer = observer
    }

    private func discardSession() {
        guard let id = sessionID else { return }
        for canvas in canvases { canvas.removeFromSuperview() }
        observer?.stop()
        canvases = []
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
        guard !busy, !finished else { return }
        pendingSelectionAction?.cancel()
        pendingSelectionAction = nil
        let settings = services.settings.snapshot
        switch action {
        case .cancel: cancel()
        case .tool(let tool): selectTool(tool)
        case .copy:
            run(retry: .copy) { id in
                try await self.services.export.copyImage(of: id, settings: settings)
                self.services.errors.toast(ToastModel(message: self.l10n[.feedbackCopied]), near: nil)
                self.finish()
            }
        case .save:
            run(retry: .save) { id in
                let receipt = try await self.services.export.save(id, as: nil, settings: settings)
                self.services.errors.toast(ToastModel(message: self.l10n.string(.feedbackSaved, receipt.url.lastPathComponent)), near: nil)
                self.finish()
            }
        case .pin:
            run(retry: .pin) { id in
                if settings.general.playsSound { await self.deps.sound.play(.capture) }
                self.services.router.route(.pin(id))
                self.finish()
            }
        case .upload:
            run(retry: .upload) { id in
                let receipt = try await self.services.export.upload(id, settings: settings)
                self.services.errors.toast(ToastModel(message: self.l10n.string(.feedbackUploaded, receipt.url.absoluteString)), near: nil)
                self.finish()
            }
        case .recognize: openDrawer { $0.recognize() }
        case .translate: openDrawer { $0.translate() }
        case .smartMosaic:
            run(finishes: false, retry: .smartMosaic) { id in
                self.toolbarModel.scanning = true
                defer { self.toolbarModel.scanning = false }
                try await self.services.smartMosaic(id, on: self.canvas, near: self.selectionAnchor)
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

    /// Center of the selection in Cocoa coordinates (toasts appear on its screen).
    private var selectionAnchor: CGPoint? {
        guard let rect = selection.rect, let frames else { return nil }
        let primaryHeight = frames.topology.display(frames.topology.primary)?.frame.height ?? 0
        let cocoa = QuartzConversion.cocoaRect(fromQuartz: rect, primaryHeight: primaryHeight)
        return CGPoint(x: cocoa.midX, y: cocoa.midY)
    }

    private func run(finishes: Bool = true, retry action: Action? = nil, _ body: @escaping (SessionID) async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            guard let id = await ensureSession() else { return }
            do {
                try await body(id)
            } catch {
                services.errors.present(error, near: nil, retry: action.map { action in { [weak self] in self?.perform(action) } })
            }
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
        let panel = drawerPanel ?? KeyPanel(above: windows.first?.level ?? .floating)
        panel.contentView = NSHostingView(rootView: ResultsDrawerView(model: model) { [weak self] in self?.closeDrawer() }.localized(l10n))
        drawerPanel = panel
        toolbarPlacement = nil
        layoutToolbar()
        panel.orderFrontRegardless()
    }

    private func closeDrawer() {
        drawerPanel?.orderOut(nil)
        drawerPanel = nil
        toolbarPlacement = nil
        windows.first?.makeKey()
    }

    // MARK: Toolbar placement (INP-01)

    private func layoutToolbar() {
        guard selection.phase == .selected, let rect = selection.rect, let frames else {
            if toolbarPlacement != nil {
                toolbarPanel?.orderOut(nil)
                drawerPanel?.orderOut(nil)
                toolbarPlacement = nil
            }
            return
        }
        let primaryHeight = frames.topology.display(frames.topology.primary)?.frame.height ?? 0
        let panel = toolbarPanel ?? makeToolbarPanel()
        let size = toolbarSize ?? panel.contentView?.fittingSize ?? NSSize(width: 600, height: 44)
        toolbarSize = size
        let placement = ToolbarPlacement(rect: rect, size: size, hasDrawer: drawerPanel != nil)
        guard placement != toolbarPlacement else { return }
        toolbarPlacement = placement
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
            drawer.setFrame(
                QuartzConversion.cocoaRect(
                    fromQuartz: QuartzRect(x: x, y: y, width: drawerSize.width, height: drawerSize.height), primaryHeight: primaryHeight),
                display: true)
        }
    }

    private func makeToolbarPanel() -> NSPanel {
        let panel = KeyPanel(above: windows.first?.level ?? .floating)
        toolbarModel.uploadEnabled = services.settings.imageHost.provider != nil
        toolbarModel.pipelineEnabled = services.pipeline != nil
        toolbarModel.scrollEnabled = deps.scroll != nil
        toolbarModel.onResize = { [weak self] size in
            guard let self, self.toolbarSize != size else { return }
            self.toolbarSize = size
            self.layoutToolbar()
        }
        let view = InPlaceToolbarView(model: toolbarModel) { [weak self] action in self?.perform(action) }.localized(l10n)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        toolbarPanel = panel
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
        pendingSelectionAction?.cancel()
        pendingSelectionAction = nil
        creating?.cancel()
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
        if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor) }
        localEscapeMonitor = nil
        globalEscapeMonitor = nil
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
