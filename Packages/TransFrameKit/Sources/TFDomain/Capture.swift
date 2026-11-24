import CoreGraphics
import Foundation

// MARK: - DisplayTopology (SPEC §02 §2)

public struct DisplayTopology: Sendable, Equatable {
    /// Monotonic within the process; any display change increments it.
    public let version: Int
    /// Non-empty; mirror sets keep one logical source.
    public let displays: [DisplayDescriptor]
    public let primary: DisplayID

    public init(version: Int, displays: [DisplayDescriptor], primary: DisplayID) {
        self.version = version
        self.displays = displays
        self.primary = primary
    }

    public func display(_ id: DisplayID) -> DisplayDescriptor? { displays.first { $0.id == id } }

    /// The display containing the point; falls back to the nearest display.
    public func display(containing point: QuartzPoint) -> DisplayDescriptor? {
        if let hit = displays.first(where: { $0.frame.contains(point) }) { return hit }
        return displays.min { lhs, rhs in
            Self.distance(from: point, to: lhs.frame) < Self.distance(from: point, to: rhs.frame)
        }
    }

    /// Union of all display frames.
    public var bounds: QuartzRect {
        displays.dropFirst().reduce(displays.first?.frame ?? .zero) { $0.union($1.frame) }
    }

    private static func distance(from p: QuartzPoint, to r: QuartzRect) -> Double {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
}

public struct DisplayDescriptor: Sendable, Equatable, Identifiable {
    public let id: DisplayID
    public let localizedName: String
    public let frame: QuartzRect
    public let pixelSize: PixelSize
    public let scale: Double
    public let rotationDegrees: Int
    public let refreshRateHz: Double?
    public let isBuiltin: Bool

    public init(
        id: DisplayID, localizedName: String, frame: QuartzRect, pixelSize: PixelSize,
        scale: Double? = nil, rotationDegrees: Int = 0, refreshRateHz: Double? = nil, isBuiltin: Bool = false
    ) {
        self.id = id
        self.localizedName = localizedName
        self.frame = frame
        self.pixelSize = pixelSize
        self.scale = scale ?? (frame.width > 0 ? Double(pixelSize.width) / frame.width : 1)
        self.rotationDegrees = rotationDegrees
        self.refreshRateHz = refreshRateHz
        self.isBuiltin = isBuiltin
    }

    /// One refresh period; nil refresh rates are treated as 60 Hz.
    public var refreshPeriod: Duration { .seconds(1.0 / (refreshRateHz ?? 60)) }
}

// MARK: - Capture (SPEC §02 §3)

public enum CaptureIntent: String, Sendable, Equatable, Codable, CaseIterable {
    case region, regionThenTranslate, fullDisplay, scroll
}

public enum CaptureTrigger: String, Sendable, Equatable, Codable {
    case hotkey, menu, programmatic
}

public struct CaptureRequest: Sendable {
    public let id: OperationID
    public let intent: CaptureIntent
    public let trigger: CaptureTrigger
    /// Recorded at the hotkey callback entry, before any actor hop.
    public let triggerInstant: ContinuousClock.Instant
    public let triggerDate: Date
    public let pointer: QuartzPoint
    /// This app's overlays and toolbars; pins are not excluded.
    public let excludedWindows: Set<WindowID>

    public init(
        id: OperationID = OperationID(), intent: CaptureIntent, trigger: CaptureTrigger,
        triggerInstant: ContinuousClock.Instant = .now, triggerDate: Date = Date(),
        pointer: QuartzPoint, excludedWindows: Set<WindowID> = []
    ) {
        self.id = id
        self.intent = intent
        self.trigger = trigger
        self.triggerInstant = triggerInstant
        self.triggerDate = triggerDate
        self.pointer = pointer
        self.excludedWindows = excludedWindows
    }
}

public struct CapturedFrame: Sendable {
    public let display: DisplayDescriptor
    /// Pixel size equals `display.pixelSize`; contains no cursor.
    public let image: PixelImage
    public let requestedAt: ContinuousClock.Instant
    public let completedAt: ContinuousClock.Instant
    /// Only calibrated frame timestamps; otherwise nil.
    public let presentationTime: ContinuousClock.Instant?

    public init(
        display: DisplayDescriptor, image: PixelImage, requestedAt: ContinuousClock.Instant,
        completedAt: ContinuousClock.Instant, presentationTime: ContinuousClock.Instant? = nil
    ) {
        self.display = display
        self.image = image
        self.requestedAt = requestedAt
        self.completedAt = completedAt
        self.presentationTime = presentationTime
    }

    /// Actual pixels per point of the frame (never assumes 2x).
    public var pixelScale: Double {
        display.frame.width > 0 ? Double(image.pixelSize.width) / display.frame.width : image.scale
    }
}

public struct FrozenFrameSet: Sendable {
    public let request: CaptureRequest
    public let topology: DisplayTopology
    /// Exactly one frame per participating display; all-or-nothing.
    public let frames: [CapturedFrame]
    /// Front-to-back Z order.
    public let windows: [WindowCandidate]
    /// Frontmost application at freeze time (SPEC §02 §5 CaptureContext).
    public let context: CaptureContext?

    public init(
        request: CaptureRequest, topology: DisplayTopology, frames: [CapturedFrame],
        windows: [WindowCandidate], context: CaptureContext? = nil
    ) {
        self.request = request
        self.topology = topology
        self.frames = frames
        self.windows = windows
        self.context = context
    }

    public func frame(for display: DisplayID) -> CapturedFrame? { frames.first { $0.display.id == display } }

    /// Approximate memory footprint of the frozen pixels.
    public var byteCount: Int { frames.reduce(0) { $0 + $1.image.pixelSize.pixelCount * 4 } }
}

public enum WindowKind: String, Sendable, Hashable, Codable {
    case window, sheet, popoverOrMenu, ownPin
}

public struct WindowCandidate: Sendable, Identifiable, Hashable {
    public let id: WindowID
    public let ownerPID: Int32
    public let ownerBundleID: String?
    public let ownerName: String
    public let title: String?
    public let frame: QuartzRect
    public let layer: Int
    public let kind: WindowKind
    /// Same position and layer in the enumerations before and after capture.
    public let isStable: Bool

    public init(
        id: WindowID, ownerPID: Int32, ownerBundleID: String?, ownerName: String, title: String?,
        frame: QuartzRect, layer: Int, kind: WindowKind, isStable: Bool
    ) {
        self.id = id
        self.ownerPID = ownerPID
        self.ownerBundleID = ownerBundleID
        self.ownerName = ownerName
        self.title = title
        self.frame = frame
        self.layer = layer
        self.kind = kind
        self.isStable = isStable
    }
}

/// Where the captured content came from (used for glossary scope and translation context).
public struct CaptureContext: Sendable, Equatable, Codable {
    public let appBundleID: String?
    public let appName: String?
    public let windowTitle: String?

    public init(appBundleID: String?, appName: String?, windowTitle: String?) {
        self.appBundleID = appBundleID
        self.appName = appName
        self.windowTitle = windowTitle
    }
}
