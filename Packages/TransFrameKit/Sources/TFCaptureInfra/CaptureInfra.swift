import AppKit
import CoreGraphics
import Foundation
import os
@preconcurrency import ScreenCaptureKit
import TFDomain

// MARK: - Display topology (SPEC §02 §2)

/// Builds the topology from CoreGraphics (Quartz global points, primary display by CG) and bumps the version on
/// every screen-parameter change.
@MainActor
public final class DisplayTopologyService: DisplayTopologyProviding {
    private var version = 1
    private var cached: DisplayTopology?
    private var observer: (any NSObjectProtocol)?

    public init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.version += 1
                self?.cached = nil
            }
        }
    }

    public func topology() async throws(AppError) -> DisplayTopology {
        if let cached { return cached }
        let topology = try Self.build(version: version)
        cached = topology
        return topology
    }

    public func pointerLocation() -> QuartzPoint {
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return QuartzConversion.quartzPoint(fromCocoa: mouse, primaryHeight: primaryHeight)
    }

    static func build(version: Int) throws(AppError) -> DisplayTopology {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { throw .capture(.noDisplays) }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let names = Dictionary(NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (CGDirectDisplayID(number.uint32Value), screen.localizedName)
        }, uniquingKeysWith: { first, _ in first })
        var displays: [DisplayDescriptor] = []
        for id in ids.prefix(Int(count)) {
            // Mirror sets keep one logical source.
            if CGDisplayIsInMirrorSet(id) != 0, CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay { continue }
            let bounds = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let pixelWidth = mode.map { Int($0.pixelWidth) } ?? Int(bounds.width)
            let pixelHeight = mode.map { Int($0.pixelHeight) } ?? Int(bounds.height)
            let refresh = mode?.refreshRate ?? 0
            displays.append(DisplayDescriptor(
                id: DisplayID(id), localizedName: names[id] ?? "Display \(id)", frame: QuartzRect(bounds),
                pixelSize: PixelSize(width: pixelWidth, height: pixelHeight), rotationDegrees: Int(CGDisplayRotation(id)),
                refreshRateHz: refresh > 0 ? refresh : nil, isBuiltin: CGDisplayIsBuiltin(id) != 0
            ))
        }
        guard !displays.isEmpty else { throw .capture(.noDisplays) }
        return DisplayTopology(version: version, displays: displays, primary: DisplayID(CGMainDisplayID()))
    }
}

// MARK: - Window enumeration (CAP-05, CAP-22)

public struct WindowEnumerator: WindowEnumerating {
    /// System processes whose windows are never offered as candidates.
    static let excludedOwners: Set<String> = ["Window Server", "Dock", "WindowManager", "Control Center", "Notification Center", "Spotlight", "screencaptureui"]
    private let ownPID: Int32
    private let ownBundleID: String?

    public init(ownPID: Int32 = ProcessInfo.processInfo.processIdentifier, ownBundleID: String? = Bundle.main.bundleIdentifier) {
        self.ownPID = ownPID
        self.ownBundleID = ownBundleID
    }

    public func windows(excluding: Set<WindowID>) async -> [WindowCandidate] { list(excluding: excluding) }

    func list(excluding: Set<WindowID>, stableAgainst previous: [WindowCandidate]? = nil) -> [WindowCandidate] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let previousByID = Dictionary((previous ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [WindowCandidate] = []
        for entry in info {
            guard let number = entry[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32 else { continue }
            let id = WindowID(number)
            guard !excluding.contains(id), bounds.width >= 20, bounds.height >= 20 else { continue }
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.01 else { continue }
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            guard !Self.excludedOwners.contains(owner) else { continue }
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            let title = entry[kCGWindowName as String] as? String
            let isOwn = pid == ownPID
            // Own windows are only candidates when they are pins (normal level, titled "TF2Pin").
            if isOwn && title != "TF2Pin" { continue }
            let kind: WindowKind = isOwn ? .ownPin : (layer == 0 ? .window : (layer >= 100 ? .popoverOrMenu : .sheet))
            if !isOwn && layer >= 25 && layer < 100 { continue }
            let bundleID = isOwn ? ownBundleID : NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            let frame = QuartzRect(bounds)
            let stable: Bool
            if previous != nil, let before = previousByID[id] {
                stable = before.frame == frame && before.layer == layer
            } else {
                stable = previous == nil
            }
            result.append(WindowCandidate(
                id: id, ownerPID: pid, ownerBundleID: bundleID, ownerName: owner, title: isOwn ? nil : title,
                frame: frame, layer: layer, kind: kind, isStable: stable
            ))
        }
        return result
    }

    public func frontmostContext() async -> CaptureContext? {
        await MainActor.run {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            let title = list(excluding: []).first { $0.ownerPID == app.processIdentifier && $0.layer == 0 }?.title
            return CaptureContext(appBundleID: app.bundleIdentifier, appName: app.localizedName, windowTitle: title)
        }
    }
}

// MARK: - One-shot snapshot of every display (CAP-01, CAP-18)

/// ScreenCaptureKit screenshots of all displays in parallel; all-or-nothing, 2 s timeout, no cursor.
public actor ScreenSnapshotter: SnapshotCapturing, ScrollCapturing {
    private let topology: any DisplayTopologyProviding
    private let windows: WindowEnumerator
    private var content: SCShareableContent?
    private let logger = Logger(subsystem: "com.transframe.v2", category: "capture")

    public init(topology: any DisplayTopologyProviding, windows: WindowEnumerator) {
        self.topology = topology
        self.windows = windows
    }

    /// Warms the shareable-content cache so the first capture is not cold.
    public func prewarm() async {
        content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    public func freeze(_ request: CaptureRequest) async throws(AppError) -> FrozenFrameSet {
        guard CGPreflightScreenCaptureAccess() else { throw .permission(.screenRecordingDenied) }
        let topology = try await topology.topology()
        let before = windows.list(excluding: request.excludedWindows)
        let context = await windows.frontmostContext()
        let frames = try await captureAll(topology)
        let after = windows.list(excluding: request.excludedWindows, stableAgainst: before)
        Task { await self.prewarm() }
        return FrozenFrameSet(request: request, topology: topology, frames: frames, windows: after, context: context)
    }

    private func captureAll(_ topology: DisplayTopology) async throws(AppError) -> [CapturedFrame] {
        let shareable = try await shareableContent(refresh: false)
        do {
            return try await capture(topology.displays, using: shareable)
        } catch where error == .capture(.displayDisconnected("")) || error == .capture(.noDisplays) {
            return try await capture(topology.displays, using: try await shareableContent(refresh: true))
        }
    }

    private func shareableContent(refresh: Bool) async throws(AppError) -> SCShareableContent {
        if !refresh, let content { return content }
        do {
            let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            content = fresh
            return fresh
        } catch {
            throw .permission(.screenRecordingDenied)
        }
    }

    private func capture(_ displays: [DisplayDescriptor], using shareable: SCShareableContent) async throws(AppError) -> [CapturedFrame] {
        let scDisplays = Dictionary(shareable.displays.map { ($0.displayID, $0) }, uniquingKeysWith: { first, _ in first })
        for display in displays where scDisplays[display.id.raw] == nil { throw .capture(.displayDisconnected("")) }
        do {
            return try await withThrowingTaskGroup(of: CapturedFrame.self) { group in
                for display in displays {
                    guard let scDisplay = scDisplays[display.id.raw] else { continue }
                    group.addTask { try await Self.capture(display, scDisplay) }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(2))
                    throw AppError.capture(.timedOut)
                }
                var frames: [CapturedFrame] = []
                while frames.count < displays.count, let frame = try await group.next() { frames.append(frame) }
                group.cancelAll()
                return displays.compactMap { d in frames.first { $0.display.id == d.id } }
            }
        } catch let error as AppError {
            throw error
        } catch {
            logger.error("capture failed: \(String(describing: type(of: error)), privacy: .public)")
            throw .capture(.timedOut)
        }
    }

    private static func capture(_ display: DisplayDescriptor, _ scDisplay: SCDisplay) async throws -> CapturedFrame {
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.pixelSize.width
        configuration.height = display.pixelSize.height
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let requested = ContinuousClock.now
        let image = try await OneShotCapture.image(filter: filter, configuration: configuration, timeout: .seconds(2))
        let completed = ContinuousClock.now
        return CapturedFrame(
            display: display, image: PixelImage(cgImage: image, scale: Double(image.width) / max(display.frame.width, 1)),
            requestedAt: requested, completedAt: completed
        )
    }

    /// Live strip of one rect for scrolling capture; this app's windows are excluded.
    public func captureStrip(_ rect: QuartzRect, excluding: Set<WindowID>) async throws(AppError) -> PixelImage {
        let topology = try await topology.topology()
        guard let display = topology.display(containing: QuartzPoint(x: rect.midX, y: rect.midY)) else { throw .capture(.selectionOutOfBounds) }
        let shareable = try await shareableContent(refresh: true)
        guard let scDisplay = shareable.displays.first(where: { $0.displayID == display.id.raw }) else {
            throw .capture(.displayDisconnected(display.localizedName))
        }
        let own = shareable.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: scDisplay, excludingApplications: own, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let local = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.sourceRect = local.raw
        configuration.width = Int((local.width * display.scale).rounded())
        configuration.height = Int((local.height * display.scale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return PixelImage(cgImage: image, scale: display.scale)
        } catch {
            throw .capture(.timedOut)
        }
    }
}

/// Completion-handler capture with a hard deadline: resumes exactly once, late frames are dropped (review-1 P1-3).
enum OneShotCapture {
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CGImage, any Error>?
        init(_ continuation: CheckedContinuation<CGImage, any Error>) { self.continuation = continuation }
        func resume(_ result: Result<CGImage, any Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }

    static func image(filter: SCContentFilter, configuration: SCStreamConfiguration, timeout: Duration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let gate = Gate(continuation)
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let image { gate.resume(.success(image)) } else { gate.resume(.failure(error ?? AppError.capture(.timedOut))) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                gate.resume(.failure(AppError.capture(.timedOut)))
            }
        }
    }
}
