import AppKit
import Observation
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization
import TFWorkspaceUI
import UniformTypeIdentifiers

@MainActor
public protocol EditorCoordinating: AnyObject {
    func open(_ id: SessionID, focus: EditorFocus?)
    func openImage(_ url: URL?)
}

/// Editor windows, one per session (EDT-01…EDT-15, APP-08).
@MainActor
public final class EditorCoordinator: EditorCoordinating {
    private let services: WorkspaceServices
    private let importImage: (URL) async throws(AppError) -> SessionID
    private var windows: [SessionID: EditorWindowController] = [:]

    public init(services: WorkspaceServices, importImage: @escaping (URL) async throws(AppError) -> SessionID) {
        self.services = services
        self.importImage = importImage
    }

    public func open(_ id: SessionID, focus: EditorFocus?) {
        if let existing = windows[id] {
            existing.present(focus: focus)
            return
        }
        let controller = EditorWindowController(services: services, sessionID: id) { [weak self] in self?.windows[id] = nil }
        windows[id] = controller
        controller.present(focus: focus)
    }

    public func openImage(_ url: URL?) {
        guard let url = url ?? chooseImage() else { return }
        Task {
            do { open(try await importImage(url), focus: nil) } catch { services.errors.present(error, near: nil) }
        }
    }

    private func chooseImage() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .webP, .bmp]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }
}

@MainActor
@Observable
final class EditorModel {
    let services: WorkspaceServices
    let sessionID: SessionID
    let observer: DocumentObserver
    let editor: AnnotationEditor
    let results: ResultsModel
    var showsResults = false
    var isCropping = false
    var cropRect: DocumentRect?
    var busy = false
    var scanning = false
    @ObservationIgnored weak var canvas: DocumentCanvasView?

    init(services: WorkspaceServices, sessionID: SessionID) {
        self.services = services
        self.sessionID = sessionID
        observer = DocumentObserver(sessions: services.sessions, sessionID: sessionID)
        editor = services.makeEditor(for: sessionID)
        results = ResultsModel(services: services, sessionID: sessionID)
    }

    var l10n: Localizer { services.localizer }

    func copyAndClose(_ close: @escaping () -> Void) {
        act {
            try await self.services.export.copyImage(of: self.sessionID, settings: self.services.settings.snapshot)
            self.toast(self.l10n[.feedbackCopied]); close()
        }
    }

    /// Save failures keep the editing state and report the reason (EDT-14).
    func save() {
        act {
            let receipt = try await self.services.export.save(self.sessionID, as: nil, settings: self.services.settings.snapshot)
            self.toast(self.l10n.string(.feedbackSaved, receipt.url.lastPathComponent))
        }
    }

    func pin() { services.router.route(.pin(sessionID)) }

    /// Scan animation on the canvas, found areas light up, then a toast with the result (INP-08).
    func smartMosaic() {
        guard services.pipeline != nil else { return }
        act {
            self.scanning = true
            defer { self.scanning = false }
            let anchor = self.canvas?.window.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
            try await self.services.smartMosaic(self.sessionID, on: self.canvas, near: anchor)
        }
    }

    func recognize() { showsResults = true; results.recognize() }
    func translate() { showsResults = true; results.translate() }

    func toggleBeautify() {
        guard let session = observer.session else { return }
        var presentation = session.presentation
        presentation.beautify.toggle()
        apply(EditTransaction.setPresentation(presentation, in: session, label: "undo.presentation"))
    }

    // Crop (EDT-04): non-destructive and undoable.
    func beginCrop() {
        guard let session = observer.session else { return }
        editor.tool = nil
        cropRect = session.crop ?? session.imageBounds
        isCropping = true
    }

    func applyCrop() {
        guard let session = observer.session, let rect = cropRect else { return }
        isCropping = false
        apply(EditTransaction.setCrop(rect.integralOutward.intersection(session.imageBounds), in: session, label: "undo.crop"))
    }

    func cancelCrop() { isCropping = false; cropRect = nil }

    private func apply(_ transaction: EditTransaction?) {
        guard let transaction else { return }
        let sessions = services.sessions, id = sessionID, errors = services.errors
        Task { do { try await sessions.apply(transaction, to: id) } catch { errors.present(error, near: nil) } }
    }

    /// Runs one editor action; a retryable failure offers Retry, which runs the same action again.
    private func act(_ body: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await body()
            } catch {
                services.errors.present(error, near: nil) { [weak self] in self?.act(body) }
            }
        }
    }

    private func toast(_ message: String) { services.errors.toast(ToastModel(message: message), near: nil) }
}

@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    private let model: EditorModel
    private let window: EditorWindow
    private let canvas: DocumentCanvasView
    private let onClose: () -> Void
    private let owner = SessionOwner.editor(UUID())
    private var sized = false

    init(services: WorkspaceServices, sessionID: SessionID, onClose: @escaping () -> Void) {
        model = EditorModel(services: services, sessionID: sessionID)
        canvas = DocumentCanvasView(render: services.render, sessionID: sessionID, editor: model.editor)
        self.onClose = onClose
        window = EditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = services.localizer[.editorTitle]
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.contentMinSize = NSSize(width: 300, height: 200)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        let root = EditorRootView(model: model, canvas: canvas, close: { [weak self] in self?.window.close() }).localized(services.localizer)
        window.contentView = NSHostingView(rootView: root)
        model.canvas = canvas
        canvas.onEscapeUnhandled = { [weak self] in self?.escape() }
        canvas.onRender = { [weak self] plan in self?.sizeToFit(plan) }
        model.observer.onChange = { [weak self] session in
            self?.canvas.update(session)
            self?.model.results.update(session)
        }
        model.observer.start()
        Task { await services.sessions.retain(sessionID, by: owner) }
    }

    func present(focus: EditorFocus?) {
        WindowFactory.present(window)
        window.makeFirstResponder(canvas)
        switch focus {
        case .ocr?: model.recognize()
        case .translation?: model.translate()
        case nil: break
        }
    }

    /// Window follows the image size, capped to the visible screen (EDT-01, EDT-15).
    private func sizeToFit(_ plan: RenderPlan) {
        let pointSize = NSSize(width: Double(plan.canvas.width) / plan.scale, height: Double(plan.canvas.height) / plan.scale)
        canvas.frame.size = pointSize
        guard !sized else { return }
        sized = true
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let chrome = NSSize(width: 32, height: 120)
        let size = NSSize(
            width: min(max(pointSize.width + chrome.width, 520), visible.width * 0.9),
            height: min(max(pointSize.height + chrome.height, 260), visible.height * 0.9))
        window.setContentSize(size)
        window.center()
    }

    private func escape() {
        if model.isCropping { model.cancelCrop(); return }
        if model.showsResults { model.showsResults = false; return }
        window.close()
    }

    /// Editor shortcuts (EDT-02…EDT-08). Tool letters and digits go to the canvas first.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if model.editor.textEditing != nil { return false }
        if flags.contains(.command) {
            switch key {
            case "c": model.copyAndClose { [weak self] in self?.window.close() }; return true
            case "s": model.save(); return true
            case "z":
                if flags.contains(.shift) { model.observer.redo() } else { model.observer.undo() }
                return true
            default: return false
            }
        }
        switch event.keyCode {
        case 36, 76:
            if model.isCropping { model.applyCrop() } else { model.copyAndClose { [weak self] in self?.window.close() } }
            return true
        case 53: if !model.editor.cancelStep() { escape() }; return true
        default: break
        }
        guard flags.isDisjoint(with: [.control, .option]) else { return false }
        if key == "c" { model.beginCrop(); return true }
        if key == "p" { model.pin(); return true }
        return model.editor.handleKey(key, keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    func windowWillClose(_ notification: Notification) {
        model.observer.stop()
        model.results.cancel()
        let sessions = model.services.sessions, id = model.sessionID, owner = owner
        Task { await sessions.release(id, by: owner) }
        onClose()
    }
}

final class EditorWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

struct EditorRootView: View {
    @Bindable var model: EditorModel
    let canvas: DocumentCanvasView
    let close: () -> Void
    @Environment(Localizer.self) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s1) {
                AnnotationToolbar(editor: model.editor)
                ToolbarDivider()
                IconButton(l10n[.actionUndo], systemImage: "arrow.uturn.backward", shortcutHint: "⌘Z", detail: l10n[.actionUndoHint]) {
                    model.observer.undo()
                }
                .disabled(!model.observer.canUndo)
                IconButton(l10n[.actionRedo], systemImage: "arrow.uturn.forward", shortcutHint: "⇧⌘Z", detail: l10n[.actionRedoHint]) {
                    model.observer.redo()
                }
                .disabled(!model.observer.canRedo)
                Spacer(minLength: DS.Space.s2)
                IconButton(l10n[.actionCrop], systemImage: "crop", shortcutHint: "C", detail: l10n[.actionCropHint], isActive: model.isCropping) {
                    model.isCropping ? model.applyCrop() : model.beginCrop()
                }
                IconButton(
                    l10n[.actionBeautify], systemImage: "sparkles.rectangle.stack", detail: l10n[.actionBeautifyHint], isActive: model.observer.beautify
                ) { model.toggleBeautify() }
                if model.services.pipeline != nil {
                    IconButton(
                        l10n[.actionSmartMosaic], systemImage: "eye.trianglebadge.exclamationmark", detail: l10n[.actionSmartMosaicHint],
                        isActive: model.scanning
                    ) { model.smartMosaic() }
                    IconButton(l10n[.actionRecognize], systemImage: "text.viewfinder", detail: l10n[.actionRecognizeHint]) { model.recognize() }
                    IconButton(l10n[.actionTranslate], systemImage: "character.bubble", detail: l10n[.actionTranslateHint]) { model.translate() }
                }
                IconButton(l10n[.actionPin], systemImage: "pin", shortcutHint: "P", detail: l10n[.actionPinHint]) { model.pin() }
                IconButton(l10n[.actionSave], systemImage: "square.and.arrow.down", shortcutHint: "⌘S", detail: l10n[.actionSaveHint]) { model.save() }
                Button(l10n[.actionCopy]) { model.copyAndClose(close) }
                    .buttonStyle(.borderedProminent)
                    .hoverHint(l10n[.actionCopy], keys: ["↩", "⌘C"], detail: l10n[.actionCopyHint])
            }
            .padding(.horizontal, DS.Space.s3)
            .padding(.vertical, DS.Space.s2)
            .padding(.top, DS.Space.s5)
            if model.editor.showsStyleBar {
                HStack(spacing: 0) {
                    AnnotationStyleBar(editor: model.editor)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Space.s3)
                .padding(.bottom, DS.Space.s2)
            }
            Divider()
            HStack(spacing: 0) {
                CanvasHost(canvas: canvas, model: model)
                if model.showsResults {
                    Divider()
                    ResultsDrawerView(model: model.results) { model.showsResults = false }
                        .frame(width: 360)
                        .padding(DS.Space.s2)
                }
            }
        }
        .background(DS.Palette.surfaceWindow)
        .hoverHintScope()
    }
}

/// Scrolls the canvas when the image is larger than the window (EDT-15) and draws the crop frame (EDT-04).
struct CanvasHost: NSViewRepresentable {
    let canvas: DocumentCanvasView
    let model: EditorModel

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let container = CenteringClipView()
        container.drawsBackground = false
        scroll.contentView = container
        scroll.documentView = canvas
        let crop = CropOverlay(model: model, canvas: canvas)
        canvas.addSubview(crop)
        context.coordinator.crop = crop
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.crop?.frame = canvas.bounds
        context.coordinator.crop?.isHidden = !model.isCropping
        context.coordinator.crop?.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var crop: CropOverlay? }
}

final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

@MainActor
final class CropOverlay: NSView {
    let model: EditorModel
    weak var canvas: DocumentCanvasView?
    private var start: DocumentPoint?

    init(model: EditorModel, canvas: DocumentCanvasView) {
        self.model = model
        self.canvas = canvas
        super.init(frame: canvas.bounds)
        autoresizingMask = [.width, .height]
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, let rect = model.cropRect, let context = NSGraphicsContext.current?.cgContext else { return }
        let view = canvas.viewRect(for: rect)
        context.setFillColor(DS.Overlay.scrim.cgColor)
        context.addRect(bounds)
        context.addRect(view)
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(DS.Overlay.accent.cgColor)
        context.setLineWidth(DS.Overlay.selectionLineWidth)
        context.stroke(view)
        let label = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: DS.Overlay.labelFont(), .foregroundColor: DS.Overlay.labelText, .backgroundColor: DS.Overlay.labelBackground,
        ]
        label.draw(at: CGPoint(x: view.minX + 4, y: max(view.minY - 20, 2)), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        guard let canvas else { return }
        start = canvas.documentPoint(for: canvas.convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let canvas, let start, let session = model.observer.session else { return }
        let point = canvas.documentPoint(for: canvas.convert(event.locationInWindow, from: nil))
        model.cropRect = AnnotationGeometry.rect(from: start, to: point, square: event.modifierFlags.contains(.command)).intersection(session.imageBounds)
        needsDisplay = true
    }
}
