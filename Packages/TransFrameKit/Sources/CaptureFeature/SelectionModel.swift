import CoreGraphics
import Foundation
import Observation
import TFDomain

/// Selection handles on the frozen overlay (CAP-08).
public enum SelectionHandle: CaseIterable, Sendable, Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// A hover/snap candidate: a window or a local content block (CAP-05, AI-03).
public struct SnapCandidate: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case window(WindowID), block(BlockID) }
    public let kind: Kind
    public let rect: QuartzRect
    public let title: String

    public var source: SelectionSource {
        switch kind {
        case .window(let id): .window(id)
        case .block(let id): .contentBlock(id)
        }
    }
}

/// Pure selection state for one capture session (CAP-04…CAP-13). Everything is in Quartz global points.
@MainActor
@Observable
public final class SelectionModel {
    public enum Phase: Equatable { case choosing, dragging, selected }

    public private(set) var phase: Phase = .choosing
    public private(set) var rect: QuartzRect?
    public private(set) var source: SelectionSource = .freeform
    public private(set) var hovered: SnapCandidate?
    public private(set) var pointer: QuartzPoint
    public var snapsToWindows = true
    /// Locked once the selection has a document with content (annotations or results).
    public var isLocked = false

    public let bounds: QuartzRect
    public let topology: DisplayTopology
    @ObservationIgnored private var windowCandidates: [SnapCandidate]
    @ObservationIgnored private(set) var blockCandidates: [SnapCandidate] = []
    @ObservationIgnored private var dragStart: QuartzPoint?
    @ObservationIgnored private var moveOrigin: (pointer: QuartzPoint, rect: QuartzRect)?
    @ObservationIgnored private var resizing: (handle: SelectionHandle, rect: QuartzRect)?
    @ObservationIgnored private var cycleIndex = 0
    @ObservationIgnored private var cyclePoint: QuartzPoint?

    public static let dragThreshold = 3.0

    /// `snapsToWindows` follows the "detect windows" setting; Space still toggles it for one capture.
    public init(frames: FrozenFrameSet, snapsToWindows: Bool = true) {
        topology = frames.topology
        bounds = frames.topology.bounds
        pointer = frames.request.pointer
        self.snapsToWindows = snapsToWindows
        windowCandidates = frames.windows.filter { $0.isStable }.map {
            SnapCandidate(kind: .window($0.id), rect: $0.frame, title: $0.title.flatMap { $0.isEmpty ? nil : $0 } ?? $0.ownerName)
        }
        updateHover()
    }

    public func setBlocks(_ blocks: [SelectionCandidate]) {
        blockCandidates = blocks.map { SnapCandidate(kind: .block($0.id), rect: $0.rect, title: "") }
        updateHover()
    }

    // MARK: Candidates

    /// Candidates under a point: topmost window, then content blocks inside it (smallest first), then windows behind.
    public func candidates(at point: QuartzPoint) -> [SnapCandidate] {
        let windows = windowCandidates.filter { $0.rect.contains(point) }
        let top = windows.first
        let blocks = blockCandidates.filter { block in block.rect.contains(point) && (top.map { w in w.rect.contains(block.rect) } ?? true) }
            .sorted { $0.rect.area < $1.rect.area }
        return (top.map { [$0] } ?? []) + blocks + windows.dropFirst()
    }

    private func updateHover() {
        guard phase == .choosing, snapsToWindows else { hovered = nil; return }
        let list = candidates(at: pointer)
        if cyclePoint.map({ abs($0.x - pointer.x) > 2 || abs($0.y - pointer.y) > 2 }) ?? true { cycleIndex = 0; cyclePoint = nil }
        hovered = list.isEmpty ? nil : list[cycleIndex % list.count]
    }

    /// Tab cycles overlapping candidates under the pointer (CAP-06).
    public func cycleCandidates() {
        guard snapsToWindows else { return }
        let list = candidates(at: pointer)
        guard list.count > 1 else { return }
        cycleIndex = (cycleIndex + 1) % list.count
        cyclePoint = pointer
        hovered = list[cycleIndex]
    }

    /// Space toggles window snapping and free selection (CAP-07).
    public func toggleSnapping() {
        snapsToWindows.toggle()
        updateHover()
    }

    // MARK: Pointer

    public func pointerMoved(to point: QuartzPoint) {
        pointer = point
        if phase == .choosing { updateHover() }
    }

    public func handle(at point: QuartzPoint, tolerance: Double = 6) -> SelectionHandle? {
        guard let rect, !isLocked else { return nil }
        return Self.handlePoints(rect).first { hypot($0.value.x - point.x, $0.value.y - point.y) <= tolerance }?.key
    }

    public static func handlePoints(_ r: QuartzRect) -> [SelectionHandle: QuartzPoint] {
        [
            .topLeft: QuartzPoint(x: r.minX, y: r.minY), .top: QuartzPoint(x: r.midX, y: r.minY), .topRight: QuartzPoint(x: r.maxX, y: r.minY),
            .right: QuartzPoint(x: r.maxX, y: r.midY), .bottomRight: QuartzPoint(x: r.maxX, y: r.maxY), .bottom: QuartzPoint(x: r.midX, y: r.maxY),
            .bottomLeft: QuartzPoint(x: r.minX, y: r.maxY), .left: QuartzPoint(x: r.minX, y: r.midY),
        ]
    }

    public func mouseDown(at point: QuartzPoint) {
        pointer = point
        switch phase {
        case .choosing, .dragging:
            dragStart = point
        case .selected:
            if let handle = handle(at: point), let rect {
                resizing = (handle, rect)
            } else if let rect, rect.contains(point), !isLocked {
                moveOrigin = (point, rect)
            } else if !isLocked {
                dragStart = point
                phase = .choosing
            }
        }
    }

    public func mouseDragged(to point: QuartzPoint) {
        pointer = point
        if let resizing {
            let resized = Self.resized(resizing.rect, handle: resizing.handle, to: point)
            if let clipped = resized.intersection(bounds), clipped.width >= SelectionGeometry.minimumPointSize,
                clipped.height >= SelectionGeometry.minimumPointSize
            {
                setRect(clipped, source: .freeform)
            }
        } else if let moveOrigin {
            let dx = point.x - moveOrigin.pointer.x, dy = point.y - moveOrigin.pointer.y
            setRect(clampedMove(moveOrigin.rect, dx: dx, dy: dy), source: source)
        } else if let start = dragStart, hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold {
            phase = .dragging
            hovered = nil
            let r = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
            rect = QuartzRect(r).intersection(bounds)
            source = .freeform
        }
    }

    /// Returns true when the gesture produced a (new) selection.
    @discardableResult
    public func mouseUp(at point: QuartzPoint) -> Bool {
        defer {
            dragStart = nil
            moveOrigin = nil
            resizing = nil
        }
        if resizing != nil || moveOrigin != nil { return false }
        if phase == .dragging {
            if let rect, rect.width >= SelectionGeometry.minimumPointSize, rect.height >= SelectionGeometry.minimumPointSize {
                phase = .selected
                return true
            }
            rect = nil
            phase = .choosing
            updateHover()
            return false
        }
        if dragStart != nil, phase == .choosing, snapsToWindows {
            pointer = point
            updateHover()
            if let hovered {
                select(hovered.rect, source: hovered.source)
                return true
            }
        }
        return false
    }

    /// Double click: copy the selection, else the window under the pointer (when window detection is on), else the display
    /// under the pointer (CAP-13).
    public func doubleClickTarget(at point: QuartzPoint) -> (QuartzRect, SelectionSource)? {
        if let rect, rect.contains(point) { return (rect, source) }
        if snapsToWindows, let window = candidates(at: point).first { return (window.rect, window.source) }
        guard let display = topology.display(containing: point) else { return nil }
        return (display.frame, .display(display.id))
    }

    public func select(_ rect: QuartzRect, source: SelectionSource) {
        guard let clipped = rect.intersection(bounds) else { return }
        self.rect = clipped
        self.source = source
        phase = .selected
        hovered = nil
    }

    // MARK: Keyboard nudging (CAP-09)

    /// Moves by 1 pt (10 with Shift); with Option the size changes instead. Never leaves the displays.
    public func nudge(dx: Double, dy: Double, resize: Bool) {
        guard let rect, phase == .selected, !isLocked else { return }
        if resize {
            let r = CGRect(
                x: rect.minX, y: rect.minY, width: max(rect.width + dx, SelectionGeometry.minimumPointSize),
                height: max(rect.height + dy, SelectionGeometry.minimumPointSize))
            setRect(QuartzRect(r).intersection(bounds) ?? rect, source: .freeform)
        } else {
            setRect(clampedMove(rect, dx: dx, dy: dy), source: source)
        }
    }

    private func clampedMove(_ rect: QuartzRect, dx: Double, dy: Double) -> QuartzRect {
        let x = min(max(rect.minX + dx, bounds.minX), bounds.maxX - rect.width)
        let y = min(max(rect.minY + dy, bounds.minY), bounds.maxY - rect.height)
        return QuartzRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    private func setRect(_ newRect: QuartzRect, source: SelectionSource) {
        guard newRect != rect else { return }
        rect = newRect
        self.source = source
    }

    static func resized(_ r: QuartzRect, handle: SelectionHandle, to p: QuartzPoint) -> QuartzRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch handle {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        }
        return QuartzRect(x: min(minX, maxX), y: min(minY, maxY), width: max(abs(maxX - minX), 1), height: max(abs(maxY - minY), 1))
    }

    public func geometry() -> SelectionGeometry? {
        rect.map { SelectionGeometry(rect: $0, source: source, topologyVersion: topology.version) }
    }

    /// Size label text in pixels of the densest display under the selection (CAP-10).
    public var pixelSizeLabel: String? {
        guard let rect else { return nil }
        let scale = topology.displays.filter { $0.frame.intersects(rect) }.map(\.scale).max() ?? 1
        return "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded()))"
    }
}
