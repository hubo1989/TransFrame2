import AppKit
import Observation
import SwiftUI
import TFDomain

/// Tools in toolbar order; digits 1–9 follow this order (EDT-03), letters follow 1.x (EDT-02).
public enum AnnotationTool: String, CaseIterable, Sendable, Hashable {
    case rectangle, ellipse, line, arrow, freehand, highlight, mosaic, text, numberLabel, redaction, callout

    public var shortcutKey: Character {
        switch self {
        case .rectangle: "r"
        case .ellipse: "o"
        case .line: "l"
        case .arrow: "a"
        case .freehand: "d"
        case .highlight: "h"
        case .mosaic: "m"
        case .text: "t"
        case .numberLabel: "n"
        case .redaction: "x"
        case .callout: "b"
        }
    }

    public var systemImage: String {
        switch self {
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .freehand: "scribble"
        case .highlight: "highlighter"
        case .mosaic: "square.grid.3x3"
        case .text: "textformat"
        case .numberLabel: "1.circle"
        case .redaction: "eye.slash"
        case .callout: "bubble.left"
        }
    }

    public static func forKey(_ character: Character) -> AnnotationTool? {
        let lower = Character(character.lowercased())
        if let digit = lower.wholeNumberValue, (1...9).contains(digit) { return allCases[digit - 1] }
        return allCases.first { $0.shortcutKey == lower }
    }

    var usesStroke: Bool { [.rectangle, .ellipse, .line, .arrow, .freehand].contains(self) }
    var usesFont: Bool { [.text, .callout, .numberLabel].contains(self) }
    var supportsFill: Bool { [.rectangle, .ellipse].contains(self) }
}

/// Current style, in points (converted to document pixels with the image scale).
public struct AnnotationStyle: Equatable, Sendable {
    public var color: RGBA
    public var lineWidth: Double
    public var fontSize: Double
    public var isFilled: Bool
    public var fillColor: RGBA
    public var mosaicBlockSize: Double

    public init(defaults: AnnotationDefaults) {
        color = defaults.strokeColor
        lineWidth = defaults.lineWidth
        fontSize = defaults.fontSize
        isFilled = defaults.isFilled
        fillColor = defaults.fillColor
        mosaicBlockSize = defaults.mosaicBlockSize
    }

    public var asDefaults: AnnotationDefaults {
        var d = AnnotationDefaults()
        d.strokeColor = color
        d.lineWidth = lineWidth
        d.fontSize = fontSize
        d.isFilled = isFilled
        d.fillColor = fillColor
        d.mosaicBlockSize = mosaicBlockSize
        return d
    }
}

/// Handle positions for resizing (eight around a box, or the two endpoints of a line).
public enum AnnotationHandle: Hashable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    case start, end
}

public struct TextEditingState: Equatable {
    public var annotationID: AnnotationID?
    public var anchor: DocumentPoint
    public var text: String
    public var fontSize: Double
    public var color: RGBA
    public var isCallout: Bool
}

/// Shared annotation interaction for the capture overlay, editor and (read-only) pins (SPEC §01 §3.1).
/// All edits go through `SessionManaging` as one transaction per gesture (ANN-11, ADR-0003 §7).
@MainActor
@Observable
public final class AnnotationEditor {
    public var tool: AnnotationTool? { didSet { if tool != nil { selectedID = nil } } }
    public var style: AnnotationStyle { didSet { if style != oldValue { styleChanged(from: oldValue); onStyleChange?(style) } } }
    public private(set) var selectedID: AnnotationID?
    public private(set) var draft: Annotation?
    /// The committed annotation hidden while being dragged (drawn as the draft instead).
    public private(set) var hiddenID: AnnotationID?
    public var textEditing: TextEditingState?
    public private(set) var session: DocumentSession?

    @ObservationIgnored public var onStyleChange: ((AnnotationStyle) -> Void)?
    @ObservationIgnored public var onPickColor: (() async -> RGBA?)?
    @ObservationIgnored private let sessions: any SessionManaging
    @ObservationIgnored public let sessionID: SessionID
    @ObservationIgnored let labelProvider: (String) -> String
    @ObservationIgnored private var gesture: Gesture?
    @ObservationIgnored public var isReadOnly = false
    @ObservationIgnored private var styleBase: Annotation?
    @ObservationIgnored private var styleFields: Set<StyleField> = []
    @ObservationIgnored private var styleCommit: Task<Void, Never>?

    private enum Gesture {
        case create(start: DocumentPoint)
        case move(original: Annotation, start: DocumentPoint)
        case resize(original: Annotation, handle: AnnotationHandle)
        case freehand([DocumentPoint])
    }

    public init(sessions: any SessionManaging, sessionID: SessionID, defaults: AnnotationDefaults, labels: @escaping (String) -> String = { $0 }) {
        self.sessions = sessions
        self.sessionID = sessionID
        style = AnnotationStyle(defaults: defaults)
        self.labelProvider = labels
    }

    public func update(_ session: DocumentSession) {
        self.session = session
        if let selectedID, session.annotation(selectedID) == nil { self.selectedID = nil }
    }

    var scale: Double { session?.baseImage.scale ?? 1 }
    public var selected: Annotation? { selectedID.flatMap { session?.annotation($0) } }

    // MARK: Mouse input (document pixels)

    public func mouseDown(at point: DocumentPoint, clickCount: Int, constrain: Bool) {
        guard !isReadOnly, let session else { return }
        if textEditing != nil { commitText() }
        if clickCount >= 2, let hit = hitTest(point), case .text(let t) = session.annotation(hit) {
            beginTextEditing(existing: t)
            return
        }
        if clickCount >= 2, let hit = hitTest(point), case .callout(let c) = session.annotation(hit) {
            textEditing = TextEditingState(annotationID: c.id, anchor: c.bubble.origin, text: c.text, fontSize: c.fontSize, color: c.color, isCallout: true)
            return
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
                textEditing = TextEditingState(
                    annotationID: nil, anchor: point, text: "", fontSize: style.fontSize * scale, color: style.color, isCallout: false)
            case .numberLabel:
                commitInsert(
                    .numberLabel(
                        NumberLabelAnnotation(
                            center: point, number: nextNumber(), color: style.color, diameter: max(style.fontSize * 1.6, 18) * scale)))
            case .freehand:
                gesture = .freehand([point])
            default:
                gesture = .create(start: point)
            }
            return
        }
        if let hit = hitTest(point), let annotation = session.annotation(hit) {
            selectedID = hit
            gesture = .move(original: annotation, start: point)
        } else {
            selectedID = nil
        }
    }

    public func mouseDragged(to point: DocumentPoint, constrain: Bool) {
        guard let gesture else { return }
        switch gesture {
        case .create(let start):
            draft = makeShape(from: start, to: point, constrain: constrain)
        case .freehand(var points):
            if let last = points.last, last.distance(to: point) < 1 * scale { return }
            points.append(point)
            self.gesture = .freehand(points)
            draft = .freehand(PathAnnotation(points: points, color: style.color, lineWidth: style.lineWidth * scale))
        case .move(let original, let start):
            if hiddenID == nil { hiddenID = original.id }
            draft = original.translated(dx: point.x - start.x, dy: point.y - start.y)
        case .resize(let original, let handle):
            draft = AnnotationGeometry.resize(original, handle: handle, to: point, constrain: constrain)
        }
    }

    public func mouseUp(at point: DocumentPoint) {
        defer {
            gesture = nil
            draft = nil
            hiddenID = nil
        }
        guard let gesture, let session else { return }
        switch gesture {
        case .create:
            guard let draft, Self.isMeaningful(draft, scale: scale) else { return }
            if case .callout(let c) = draft {
                commitInsert(draft)
                textEditing = TextEditingState(annotationID: c.id, anchor: c.bubble.origin, text: "", fontSize: c.fontSize, color: c.color, isCallout: true)
            } else {
                commitInsert(draft)
            }
        case .freehand(let points):
            guard points.count > 1 else { return }
            commitInsert(.freehand(PathAnnotation(points: points, color: style.color, lineWidth: style.lineWidth * scale)))
        case .move, .resize:
            guard let draft, let transaction = EditTransaction.replace(draft, in: session, label: labelProvider("undo.edit")) else { return }
            submit(transaction)
        }
    }

    // MARK: Keyboard

    /// Returns true when the key was handled (Delete removes the selection, letters/digits pick tools).
    public func handleKey(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !isReadOnly, textEditing == nil else { return false }
        if keyCode == 51 || keyCode == 117, let selectedID, let session,
           let transaction = EditTransaction.remove([selectedID], from: session, label: labelProvider("undo.delete")) {
            submit(transaction)
            self.selectedID = nil
            return true
        }
        guard modifiers.isDisjoint(with: [.command, .control, .option]), let character = characters.first,
              let tool = AnnotationTool.forKey(character) else { return false }
        self.tool = self.tool == tool ? nil : tool
        return true
    }

    /// Esc ladder (EDT-08): text input → selection → tool. Returns false when nothing was left to cancel.
    public func cancelStep() -> Bool {
        if textEditing != nil { textEditing = nil; return true }
        if selectedID != nil { selectedID = nil; return true }
        if tool != nil { tool = nil; return true }
        return false
    }

    // MARK: Text

    private func beginTextEditing(existing t: TextAnnotation) {
        selectedID = nil
        textEditing = TextEditingState(annotationID: t.id, anchor: t.anchor, text: t.text, fontSize: t.fontSize, color: t.color, isCallout: false)
    }

    public func commitText() {
        guard let editing = textEditing, let session else { return }
        textEditing = nil
        let text = editing.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = editing.annotationID, let existing = session.annotation(id) {
            if text.isEmpty, !editing.isCallout, let remove = EditTransaction.remove([id], from: session, label: labelProvider("undo.delete")) {
                submit(remove)
                return
            }
            var updated = existing
            switch existing {
            case .text(var t): t.text = text; updated = .text(t)
            case .callout(var c): c.text = text; updated = .callout(c)
            default: break
            }
            if let transaction = EditTransaction.replace(updated, in: session, label: labelProvider("undo.edit")) { submit(transaction) }
        } else if !text.isEmpty {
            commitInsert(.text(TextAnnotation(anchor: editing.anchor, text: text, color: editing.color, fontSize: editing.fontSize)))
        }
    }

    // MARK: Style

    /// Only the changed style fields are applied; a slider drag previews live and commits one transaction (ANN-11, ANN-13).
    private func styleChanged(from old: AnnotationStyle) {
        guard let selected, gesture == nil else { return }
        if styleBase == nil { styleBase = selected }
        if old.color != style.color { styleFields.insert(.color) }
        if old.lineWidth != style.lineWidth { styleFields.insert(.lineWidth) }
        if old.fontSize != style.fontSize { styleFields.insert(.fontSize) }
        if old.isFilled != style.isFilled || old.fillColor != style.fillColor { styleFields.insert(.fill) }
        if old.mosaicBlockSize != style.mosaicBlockSize { styleFields.insert(.mosaic) }
        guard let base = styleBase else { return }
        hiddenID = base.id
        draft = AnnotationGeometry.restyle(base, with: style, scale: scale, fields: styleFields)
        styleCommit?.cancel()
        styleCommit = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.commitStyle()
        }
    }

    private func commitStyle() {
        defer {
            styleBase = nil
            styleFields = []
            draft = nil
            hiddenID = nil
        }
        guard let base = styleBase, let session else { return }
        let updated = AnnotationGeometry.restyle(base, with: style, scale: scale, fields: styleFields)
        if let transaction = EditTransaction.replace(updated, in: session, label: labelProvider("undo.style")) { submit(transaction) }
    }

    public func pickColor() {
        guard let onPickColor else { return }
        Task { if let color = await onPickColor() { style.color = color } }
    }

    // MARK: Helpers

    private func makeShape(from start: DocumentPoint, to end: DocumentPoint, constrain: Bool) -> Annotation? {
        guard let tool else { return nil }
        let rect = AnnotationGeometry.rect(from: start, to: end, square: constrain && [.rectangle, .ellipse].contains(tool))
        let width = style.lineWidth * scale
        switch tool {
        case .rectangle:
            return .rectangle(
                ShapeAnnotation(rect: rect, strokeColor: style.color, lineWidth: width, isFilled: style.isFilled, fillColor: style.fillColor))
        case .ellipse:
            return .ellipse(
                ShapeAnnotation(rect: rect, strokeColor: style.color, lineWidth: width, isFilled: style.isFilled, fillColor: style.fillColor))
        case .highlight: return .highlight(ShapeAnnotation(rect: rect, strokeColor: style.color, lineWidth: 0))
        case .line:
            return .line(
                LineAnnotation(start: start, end: constrain ? AnnotationGeometry.snap45(start, end) : end, color: style.color, lineWidth: width))
        case .arrow:
            return .arrow(
                LineAnnotation(start: start, end: constrain ? AnnotationGeometry.snap45(start, end) : end, color: style.color, lineWidth: width))
        case .mosaic: return .mosaic(MosaicAnnotation(rect: rect, blockSize: style.mosaicBlockSize * scale))
        case .redaction: return .redaction(RedactionAnnotation(rect: rect))
        case .callout:
            return .callout(
                CalloutAnnotation(
                    bubble: rect, pointer: DocumentPoint(x: rect.minX - 20 * scale, y: rect.maxY + 20 * scale), text: "", color: style.color,
                    fontSize: style.fontSize * scale, fillColor: .white))
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

    private func nextNumber() -> Int {
        (session?.annotations.compactMap { if case .numberLabel(let n) = $0 { n.number } else { nil } }.max() ?? 0) + 1
    }

    private func commitInsert(_ annotation: Annotation) {
        guard let session else { return }
        submit(.insert(annotation, into: session, label: labelProvider("undo.add")))
        if case .text = annotation { return }
        selectedID = nil
    }

    private func submit(_ transaction: EditTransaction) {
        let id = sessionID
        let sessions = sessions
        Task { try? await sessions.apply(transaction, to: id) }
    }

    public func hitTest(_ point: DocumentPoint) -> AnnotationID? {
        guard let session else { return nil }
        let tolerance = 6 * scale
        return session.annotations.reversed().first { AnnotationGeometry.hit($0, point: point, tolerance: tolerance) }?.id
    }

    public func handle(at point: DocumentPoint, for annotation: Annotation) -> AnnotationHandle? {
        let radius = 7 * scale
        return AnnotationGeometry.handles(for: annotation).first { $0.value.distance(to: point) <= radius }?.key
    }
}
