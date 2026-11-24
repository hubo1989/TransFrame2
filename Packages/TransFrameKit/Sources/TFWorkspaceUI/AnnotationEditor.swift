import AppKit
import Observation
import SwiftUI
import TFDomain

/// Shared annotation interaction for the capture overlay, editor and (read-only) pins (SPEC §01 §3.1).
/// All edits go through `SessionManaging` as one transaction per gesture (ANN-11, ADR-0003 §7).
@MainActor
@Observable
public final class AnnotationEditor {
    public var tool: AnnotationTool? {
        didSet {
            guard tool != oldValue else { return }
            if tool != nil { flushStyle(); selectedID = nil }
            notify(.cursor)
        }
    }
    public private(set) var style: AnnotationStyle
    public private(set) var selectedID: AnnotationID? { didSet { if selectedID != oldValue { notify(.overlay) } } }
    public private(set) var draft: Annotation? { didSet { notify(.overlay) } }
    /// The committed annotation hidden while being dragged or restyled (drawn as the draft instead).
    public private(set) var hiddenID: AnnotationID? { didSet { if hiddenID != oldValue { notify(.render) } } }
    public private(set) var pending: [PendingEdit] = [] { didSet { notify([.overlay, .render]) } }
    public var textEditing: TextEditingState? { didSet { if !(textEditing?.isSameField(as: oldValue) ?? (oldValue == nil)) { notify(.text) } } }
    public private(set) var session: DocumentSession?
    /// Keeps the style bar open without a tool or selection (the style button).
    public var stylePinned = false

    @ObservationIgnored public var onStyleChange: ((AnnotationStyle) -> Void)?
    @ObservationIgnored public var onPickColor: (() async -> RGBA?)?
    /// Synchronous display notifications for the canvas (no observation round trip on the drag path).
    @ObservationIgnored public var onDisplayChange: ((DisplayChange) -> Void)?
    @ObservationIgnored private let sessions: any SessionManaging
    @ObservationIgnored public let sessionID: SessionID
    @ObservationIgnored let labelProvider: (String) -> String
    @ObservationIgnored private var gesture: Gesture?
    @ObservationIgnored public var isReadOnly = false
    @ObservationIgnored private var styleBase: Annotation?
    @ObservationIgnored private var styleFields: Set<StyleField> = []
    @ObservationIgnored private var styleCommit: Task<Void, Never>?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var lastPersist: ContinuousClock.Instant?
    @ObservationIgnored private var lastSubmission: Task<Void, Never>?
    @ObservationIgnored private var strokeID = AnnotationID()
    @ObservationIgnored private var strokePoints: [DocumentPoint] = []
    @ObservationIgnored private var batchDepth = 0
    @ObservationIgnored private var batched: DisplayChange = []

    private enum Gesture {
        case create(start: DocumentPoint)
        case move(original: Annotation, start: DocumentPoint)
        case resize(original: Annotation, handle: AnnotationHandle)
        case freehand
    }

    public init(sessions: any SessionManaging, sessionID: SessionID, defaults: AnnotationDefaults, labels: @escaping (String) -> String = { $0 }) {
        self.sessions = sessions
        self.sessionID = sessionID
        style = AnnotationStyle(defaults: defaults)
        self.labelProvider = labels
    }

    public func update(_ session: DocumentSession) {
        batch {
            self.session = session
            if pending.contains(where: { $0.baseRevision < session.editRevision - 16 }) {
                pending.removeAll { $0.baseRevision < session.editRevision - 16 }
            }
            if let selectedID, effectiveAnnotation(selectedID) == nil { self.selectedID = nil }
        }
    }

    var scale: Double { session?.baseImage.scale ?? 1 }

    /// The selection as the user sees it (pending edits included).
    public var selected: Annotation? { selectedID.flatMap(effectiveAnnotation) }

    /// What the selection chrome surrounds: the live style preview, else the selection; nothing mid-gesture.
    public var chromeTarget: Annotation? {
        guard gesture == nil else { return nil }
        return styleBase != nil ? draft : selected
    }

    public var isGestureActive: Bool { gesture != nil }

    // MARK: Pending edits (no flicker between commit and the store echo)

    /// Annotations kept out of a render of `revision`: the dragged one and those replaced by unsettled edits.
    public func renderExclusions(at revision: Int) -> Set<AnnotationID> {
        var ids = Set(pending.filter { $0.baseRevision >= revision }.compactMap(\.hidden))
        if let hiddenID { ids.insert(hiddenID) }
        return ids
    }

    /// The canvas shows a render of `revision`: edits made against older revisions are now in the image.
    public func settle(throughRevision revision: Int) {
        guard pending.contains(where: { $0.baseRevision < revision }) else { return }
        pending.removeAll { $0.baseRevision < revision }
    }

    func effectiveAnnotation(_ id: AnnotationID) -> Annotation? {
        if let edit = pending.last(where: { $0.annotation?.id == id || $0.hidden == id }) {
            return edit.annotation?.id == id ? edit.annotation : nil
        }
        return session?.annotation(id)
    }

    /// Session annotations with unsettled edits applied, in drawing order.
    var effectiveAnnotations: [Annotation] {
        let base = session?.annotations ?? []
        guard !pending.isEmpty else { return base }
        var result = base.compactMap { effectiveAnnotation($0.id) }
        var ids = Set(base.map(\.id))
        for edit in pending {
            guard let annotation = edit.annotation, !ids.contains(annotation.id) else { continue }
            ids.insert(annotation.id)
            result.append(annotation)
        }
        return result
    }

    // MARK: Mouse input (document pixels)

    public func mouseDown(at point: DocumentPoint, clickCount: Int, constrain: Bool) {
        guard !isReadOnly, session != nil else { return }
        batch {
            if textEditing != nil { commitText() }
            flushStyle()
            if clickCount >= 2, let hit = hitTest(point), let annotation = effectiveAnnotation(hit) {
                switch annotation {
                case .text(let t):
                    beginTextEditing(existing: t)
                    return
                case .callout(let c):
                    selectedID = nil
                    textEditing = TextEditingState(
                        annotationID: c.id, anchor: c.bubble.origin, text: c.text, fontSize: c.fontSize, color: c.color, isCallout: true)
                    return
                default:
                    break
                }
            }
            if let selected, let handle = handle(at: point, for: selected) {
                gesture = .resize(original: selected, handle: handle)
                hiddenID = selected.id
                draft = selected
                return
            }
            if let tool {
                switch tool {
                case .text:
                    selectedID = nil
                    textEditing = TextEditingState(
                        annotationID: nil, anchor: point, text: "", fontSize: style.fontSize * scale, color: style.color, isCallout: false)
                case .numberLabel:
                    commitInsert(
                        .numberLabel(
                            NumberLabelAnnotation(center: point, number: nextNumber(), color: style.color, diameter: style.numberDiameter(scale: scale))))
                case .freehand:
                    strokeID = AnnotationID()
                    strokePoints = [point]
                    gesture = .freehand
                default:
                    gesture = .create(start: point)
                }
                return
            }
            if let hit = hitTest(point), let annotation = effectiveAnnotation(hit) {
                selectedID = hit
                gesture = .move(original: annotation, start: point)
                notify(.cursor)
            } else {
                selectedID = nil
            }
        }
    }

    public func mouseDragged(to point: DocumentPoint, constrain: Bool) {
        guard let gesture else { return }
        switch gesture {
        case .create(let start):
            draft = makeShape(from: start, to: point, constrain: constrain)
        case .freehand:
            if let last = strokePoints.last, last.distance(to: point) < 1 * scale { return }
            strokePoints.append(point)
            draft = .freehand(PathAnnotation(id: strokeID, points: strokePoints, color: style.color, lineWidth: style.lineWidth * scale))
        case .move(let original, let start):
            batch {
                if hiddenID == nil { hiddenID = original.id }
                draft = original.translated(dx: point.x - start.x, dy: point.y - start.y)
            }
        case .resize(let original, let handle):
            draft = AnnotationGeometry.resize(original, handle: handle, to: point, constrain: constrain)
        }
    }

    public func mouseUp(at point: DocumentPoint) {
        guard let gesture else { return }
        batch {
            defer {
                self.gesture = nil
                strokePoints = []
                draft = nil
                hiddenID = nil
                notify(.cursor)
            }
            switch gesture {
            case .create:
                guard let draft, Self.isMeaningful(draft, scale: scale) else { return }
                commitInsert(draft)
                if case .callout(let c) = draft {
                    selectedID = nil
                    textEditing = TextEditingState(annotationID: c.id, anchor: c.bubble.origin, text: "", fontSize: c.fontSize, color: c.color, isCallout: true)
                }
            case .freehand:
                guard strokePoints.count > 1 else { return }
                commitInsert(.freehand(PathAnnotation(id: strokeID, points: strokePoints, color: style.color, lineWidth: style.lineWidth * scale)))
            case .move(let original, _), .resize(let original, _):
                guard let draft else { return }
                commitReplace(draft, old: original, label: "undo.edit")
            }
        }
    }

    // MARK: Keyboard

    /// Returns true when the key was handled: Delete removes the selection, arrows nudge it (Shift: 10 pt),
    /// letters and digits pick tools.
    public func handleKey(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !isReadOnly, textEditing == nil else { return false }
        let plain = modifiers.isDisjoint(with: [.command, .control, .option])
        if keyCode == 51 || keyCode == 117 { return deleteSelection() }
        if let direction = Self.arrow(keyCode) {
            guard plain, selectedID != nil else { return false }
            let step = (modifiers.contains(.shift) ? 10 : 1) * scale
            return nudgeSelection(dx: direction.dx * step, dy: direction.dy * step)
        }
        guard plain, let character = characters.first, let tool = AnnotationTool.forKey(character) else { return false }
        self.tool = self.tool == tool ? nil : tool
        return true
    }

    static func arrow(_ keyCode: UInt16) -> (dx: Double, dy: Double)? {
        switch keyCode {
        case 123: (-1, 0)
        case 124: (1, 0)
        case 125: (0, 1)
        case 126: (0, -1)
        default: nil
        }
    }

    /// Esc ladder (EDT-08): text input → selection → tool → pinned style bar. Returns false when nothing was left to cancel.
    public func cancelStep() -> Bool {
        if textEditing != nil { cancelText(); return true }
        if selectedID != nil { flushStyle(); selectedID = nil; return true }
        if tool != nil { tool = nil; return true }
        if stylePinned { stylePinned = false; return true }
        return false
    }

    /// Removes the selected annotation (ANN-10). False when nothing is selected.
    @discardableResult
    public func deleteSelection() -> Bool {
        guard !isReadOnly, let id = selectedID, let session else { return false }
        batch {
            flushStyle()
            if let transaction = EditTransaction.remove([id], from: session, label: labelProvider("undo.delete")) {
                submit(transaction, pending: PendingEdit(annotation: nil, hidden: id, baseRevision: session.editRevision))
            }
            selectedID = nil
        }
        return true
    }

    /// Moves the selection by document pixels as one undo step.
    @discardableResult
    public func nudgeSelection(dx: Double, dy: Double) -> Bool {
        guard !isReadOnly, gesture == nil, let current = selected else { return false }
        batch {
            flushStyle()
            commitReplace(current.translated(dx: dx, dy: dy), old: current, label: "undo.edit")
        }
        return true
    }

    // MARK: Text (ANN-08)

    private func beginTextEditing(existing t: TextAnnotation) {
        selectedID = nil
        hiddenID = t.id
        textEditing = TextEditingState(annotationID: t.id, anchor: t.anchor, text: t.text, fontSize: t.fontSize, color: t.color, isCallout: false)
    }

    public func commitText() {
        guard let editing = textEditing, let session else { return }
        batch {
            textEditing = nil
            let text = editing.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = editing.annotationID, let existing = effectiveAnnotation(id) {
                if text.isEmpty, !editing.isCallout, let remove = EditTransaction.remove([id], from: session, label: labelProvider("undo.delete")) {
                    submit(remove, pending: PendingEdit(annotation: nil, hidden: id, baseRevision: session.editRevision))
                } else {
                    var updated = existing
                    switch existing {
                    case .text(var t): t.text = text; updated = .text(t)
                    case .callout(var c): c.text = text; updated = .callout(c)
                    default: break
                    }
                    if updated == existing { restoreHidden(id) } else { commitReplace(updated, old: existing, label: "undo.edit") }
                }
                if hiddenID == id { hiddenID = nil }
            } else if !text.isEmpty {
                commitInsert(.text(TextAnnotation(anchor: editing.anchor, text: text, color: editing.color, fontSize: editing.fontSize)))
            }
        }
    }

    /// Esc in the text field: keeps the annotation as it was.
    public func cancelText() {
        guard let editing = textEditing else { return }
        batch {
            textEditing = nil
            if let id = editing.annotationID { restoreHidden(id) }
        }
    }

    /// Shows a hidden annotation again without a gap: it stays on the overlay until the next render includes it.
    private func restoreHidden(_ id: AnnotationID) {
        guard hiddenID == id else { return }
        if let original = effectiveAnnotation(id), let session {
            pending.append(PendingEdit(annotation: original, hidden: nil, baseRevision: session.editRevision - 1))
        }
        if hiddenID == id { hiddenID = nil }
    }

    // MARK: Style (ANN-03…ANN-07, ANN-13, ANN-15)

    /// What the style bar shows: the selected annotation's own values when there is one.
    public var displayedStyle: AnnotationStyle {
        guard let shown = chromeTarget else { return style }
        return AnnotationGeometry.currentStyle(of: shown, scale: scale, fallback: style)
    }

    /// Controls that apply to the selection, else the tool; everything when neither is set.
    public var styleControls: StyleControls {
        if let shown = styleBase ?? selected { return AnnotationTool(kind: shown.kind)?.styleControls ?? [] }
        return tool?.styleControls ?? .all
    }

    public var showsStyleBar: Bool {
        guard !isReadOnly, stylePinned || tool != nil || selectedID != nil else { return false }
        return selectedID != nil || !styleControls.isEmpty
    }

    /// Edits the displayed style. Only the changed fields reach the selection (one undo step per slider drag) and the
    /// style for new annotations; a fill that follows the stroke keeps following it.
    public func setStyle(_ change: (inout AnnotationStyle) -> Void) {
        let old = displayedStyle
        var new = old
        change(&new)
        if new.color != old.color, new.fillColor == old.fillColor, old.fillColor == old.color.withAlpha(AnnotationStyle.autoFillAlpha) {
            new.fillColor = new.color.withAlpha(AnnotationStyle.autoFillAlpha)
        }
        let fields = StyleField.changed(from: old, to: new)
        guard !fields.isEmpty else { return }
        batch {
            style = style.applying(fields, from: new)
            if gesture == nil, styleBase != nil || selected != nil { previewRestyle(fields) }
        }
        persistStyle()
    }

    private func previewRestyle(_ fields: Set<StyleField>) {
        guard let target = styleBase ?? selected else { return }
        if styleBase == nil { styleBase = target }
        styleFields.formUnion(fields)
        hiddenID = target.id
        draft = AnnotationGeometry.restyle(target, with: style, scale: scale, fields: styleFields)
        styleCommit?.cancel()
        styleCommit = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.flushStyle()
        }
    }

    /// Commits a live style preview now (before another edit starts).
    public func flushStyle() {
        guard let base = styleBase else { return }
        styleCommit?.cancel()
        styleCommit = nil
        batch {
            let updated = AnnotationGeometry.restyle(base, with: style, scale: scale, fields: styleFields)
            styleBase = nil
            styleFields = []
            if updated == base { restoreHidden(base.id) } else { commitReplace(updated, old: base, label: "undo.style") }
            draft = nil
            if hiddenID == base.id { hiddenID = nil }
        }
    }

    /// Leading edge right away, then one write per burst (slider drags write once, not per tick).
    private func persistStyle() {
        guard let onStyleChange else { return }
        let now = ContinuousClock.now
        if persistTask == nil, lastPersist.map({ now - $0 > .milliseconds(300) }) ?? true {
            lastPersist = now
            onStyleChange(style)
            return
        }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.persistTask = nil
            self.lastPersist = .now
            self.onStyleChange?(self.style)
        }
    }

    public func pickColor() {
        guard let onPickColor else { return }
        Task { if let color = await onPickColor() { setStyle { $0.color = color } } }
    }

    // MARK: Cursor (ANN-14)

    public func cursor(at point: DocumentPoint) -> CanvasCursor {
        if case .move? = gesture { return .moving }
        if let resize = gesture.flatMap({ if case .resize(_, let h) = $0 { h } else { nil } }) { return .resize(resize) }
        if gesture == nil, let target = chromeTarget, let handle = handle(at: point, for: target) { return .resize(handle) }
        switch tool {
        case .text?: return .iBeam
        case nil: return hitTest(point) != nil ? .move : .arrow
        default: return .crosshair
        }
    }

    // MARK: Helpers

    private func makeShape(from start: DocumentPoint, to end: DocumentPoint, constrain: Bool) -> Annotation? {
        guard let tool else { return nil }
        let rect = AnnotationGeometry.rect(from: start, to: end, square: constrain && [.rectangle, .ellipse].contains(tool))
        let width = style.lineWidth * scale
        switch tool {
        case .rectangle:
            return .rectangle(
                ShapeAnnotation(id: strokeID, rect: rect, strokeColor: style.color, lineWidth: width, isFilled: style.isFilled, fillColor: style.fillColor))
        case .ellipse:
            return .ellipse(
                ShapeAnnotation(id: strokeID, rect: rect, strokeColor: style.color, lineWidth: width, isFilled: style.isFilled, fillColor: style.fillColor))
        case .highlight: return .highlight(ShapeAnnotation(id: strokeID, rect: rect, strokeColor: style.color, lineWidth: 0))
        case .line:
            return .line(
                LineAnnotation(
                    id: strokeID, start: start, end: constrain ? AnnotationGeometry.snap45(start, end) : end, color: style.color, lineWidth: width))
        case .arrow:
            return .arrow(
                LineAnnotation(
                    id: strokeID, start: start, end: constrain ? AnnotationGeometry.snap45(start, end) : end, color: style.color, lineWidth: width))
        case .mosaic: return .mosaic(MosaicAnnotation(id: strokeID, rect: rect, blockSize: style.mosaicBlockSize * scale))
        case .redaction: return .redaction(RedactionAnnotation(id: strokeID, rect: rect))
        case .callout:
            return .callout(
                CalloutAnnotation(
                    id: strokeID, bubble: rect, pointer: DocumentPoint(x: rect.minX - 20 * scale, y: rect.maxY + 20 * scale), text: "",
                    color: style.color, fontSize: style.fontSize * scale, fillColor: .white))
        case .freehand, .text, .numberLabel: return nil
        }
    }

    static func isMeaningful(_ annotation: Annotation, scale: Double) -> Bool {
        let b = annotation.bounds
        switch annotation {
        case .line(let l), .arrow(let l): return l.start.distance(to: l.end) >= 3 * scale
        default: return b.width >= 3 * scale && b.height >= 3 * scale
        }
    }

    func nextNumber() -> Int {
        (effectiveAnnotations.compactMap { if case .numberLabel(let n) = $0 { n.number } else { nil } }.max() ?? 0) + 1
    }

    /// Inserts and selects the new annotation, so its handles and the style bar act on it right away.
    private func commitInsert(_ annotation: Annotation) {
        guard let session else { return }
        // On top of everything the user sees, including inserts the store has not echoed yet.
        let transaction = EditTransaction(
            label: labelProvider("undo.add"), forward: [.insertAnnotation(annotation, at: effectiveAnnotations.count)],
            inverse: [.removeAnnotation(annotation.id)])
        submit(transaction, pending: PendingEdit(annotation: annotation, hidden: nil, baseRevision: session.editRevision))
        selectedID = annotation.id
        strokeID = AnnotationID()
    }

    /// The inverse restores what the user saw (`old`), even when the store has not echoed an earlier edit yet.
    private func commitReplace(_ new: Annotation, old: Annotation, label: String) {
        guard new != old, let session else { return }
        let transaction = EditTransaction(label: labelProvider(label), forward: [.replaceAnnotation(new)], inverse: [.replaceAnnotation(old)])
        submit(transaction, pending: PendingEdit(annotation: new, hidden: new.id, baseRevision: session.editRevision))
    }

    /// Transactions reach the store in submission order; a rejected one drops its pending overlay.
    private func submit(_ transaction: EditTransaction, pending edit: PendingEdit) {
        pending.append(edit)
        let sessions = sessions, id = sessionID, previous = lastSubmission
        lastSubmission = Task { [weak self] in
            await previous?.value
            do {
                try await sessions.apply(transaction, to: id)
            } catch {
                self?.pending.removeAll { $0.id == edit.id }
            }
        }
    }

    private func notify(_ change: DisplayChange) {
        if batchDepth > 0 {
            batched.formUnion(change)
        } else {
            onDisplayChange?(change)
        }
    }

    /// Groups the notifications of one input event into one.
    private func batch(_ body: () -> Void) {
        batchDepth += 1
        body()
        batchDepth -= 1
        guard batchDepth == 0, !batched.isEmpty else { return }
        let change = batched
        batched = []
        onDisplayChange?(change)
    }

    public func hitTest(_ point: DocumentPoint) -> AnnotationID? {
        let tolerance = 6 * scale
        return effectiveAnnotations.reversed().first { AnnotationGeometry.hit($0, point: point, tolerance: tolerance) }?.id
    }

    public func handle(at point: DocumentPoint, for annotation: Annotation) -> AnnotationHandle? {
        let radius = 7 * scale
        return AnnotationGeometry.handles(for: annotation).min { $0.value.distance(to: point) < $1.value.distance(to: point) }
            .flatMap { $0.value.distance(to: point) <= radius ? $0.key : nil }
    }
}
