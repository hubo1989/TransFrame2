import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LocalAuthentication
import os
import PermissionFlow
import Sparkle
import TFDomain

// MARK: - Permissions (SET-02, ONB-02, ONB-03, CAP-20, TXT-13)

@MainActor
public final class PermissionService: PermissionChecking, PermissionGuiding {
    private var controllers: [PermissionKind: PermissionFlowController] = [:]
    private let appURL: URL

    public init(appURL: URL) {
        self.appURL = appURL
    }

    public func isGranted(_ kind: PermissionKind) async -> Bool { Self.check(kind) }

    public static func check(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility: AXIsProcessTrusted()
        }
    }

    /// Drag-to-authorize guide; polls until granted (the only allowed polling, SPEC §01 §6) for up to 60 s.
    public func guide(_ kind: PermissionKind, from sourceFrame: CGRect?) async -> Bool {
        if Self.check(kind) { return true }
        if kind == .screenRecording { CGRequestScreenCaptureAccess() }
        let controller = controllers[kind] ?? PermissionFlowController()
        controllers[kind] = controller
        controller.authorize(pane: kind.pane, suggestedAppURLs: [appURL], sourceFrameInScreen: sourceFrame)
        for _ in 0..<300 {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
            if Self.check(kind) {
                controller.closePanel(returnToPreviousApp: true)
                return true
            }
        }
        controller.closePanel()
        return Self.check(kind)
    }

    public func openSystemSettings(_ pane: SystemSettingsPane) {
        let kind: PermissionKind = pane == .screenRecording ? .screenRecording : .accessibility
        NSWorkspace.shared.open(kind.pane.settingsURL)
    }
}

private extension PermissionKind {
    var pane: PermissionFlowPane { self == .screenRecording ? .screenRecording : .accessibility }
}

// MARK: - Updates (ONB-05). Sparkle starts only after onboarding (APP-07) and only with a configured feed.

@MainActor
public final class SparkleUpdater: AppUpdating {
    private var controller: SPUStandardUpdaterController?
    private let isConfigured: Bool
    private let feedURL: URL?
    private let currentBuild: Int
    private let currentVersion: String
    private let transport: (any HTTPTransport)?

    public init(bundle: Bundle, transport: (any HTTPTransport)? = nil) {
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = !feed.isEmpty && !key.isEmpty
        feedURL = URL(string: feed)
        currentBuild = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        self.transport = transport
    }

    public func start() {
        guard isConfigured, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Reads the feed first; Sparkle's UI is shown only when a newer build exists. A missing feed (no release yet) means
    /// up to date, so the user never sees Sparkle's "error retrieving update information" for a normal "no update".
    public func checkForUpdates() async -> UpdateCheckOutcome {
        start()
        guard let feedURL, let transport else {
            controller?.checkForUpdates(nil)
            return .updateAvailable
        }
        let outcome: UpdateCheckOutcome
        do {
            let response = try await transport.send(HTTPRequest(url: feedURL, timeout: .seconds(15)), engine: .updateFeed)
            outcome = UpdateFeedDecision.outcome(status: response.status, body: response.body, currentBuild: currentBuild, currentVersion: currentVersion)
        } catch {
            outcome = .unavailable
        }
        if outcome == .updateAvailable { controller?.checkForUpdates(nil) }
        return outcome
    }

    public var canCheckForUpdates: Bool { isConfigured }
}

/// Pure decision for a fetched update feed (testable without Sparkle or network).
public enum UpdateFeedDecision {
    public static func outcome(status: Int, body: Data, currentBuild: Int, currentVersion: String) -> UpdateCheckOutcome {
        if status == 404 { return .upToDate(version: currentVersion) }
        guard (200..<300).contains(status) else { return .unavailable }
        let xml = String(bytes: body, encoding: .utf8) ?? ""
        guard xml.contains("<rss") || xml.contains("<channel") else { return .unavailable }
        let builds = newestBuilds(in: xml)
        guard let newest = builds.max() else { return .upToDate(version: currentVersion) }
        return newest > currentBuild ? .updateAvailable : .upToDate(version: currentVersion)
    }

    /// `<sparkle:version>` values (build numbers) of every item.
    static func newestBuilds(in xml: String) -> [Int] {
        var result: [Int] = []
        var rest = xml[...]
        while let open = rest.range(of: "<sparkle:version>"), let close = rest.range(of: "</sparkle:version>", range: open.upperBound..<rest.endIndex) {
            if let value = Int(rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)) { result.append(value) }
            rest = rest[close.upperBound...]
        }
        for match in xml.matches(of: /sparkle:version="([0-9]+)"/) {
            if let value = Int(match.1) { result.append(value) }
        }
        return result
    }
}

// MARK: - Session unlock (APP-06)

@MainActor
public final class SessionUnlocker: CredentialUnlocking {
    public private(set) var isUnlocked = false

    public init() {}

    /// Touch ID or the login password once per run.
    public func unlock(reason: String) async -> Bool {
        if isUnlocked { return true }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Without system authentication the session stays locked (APP-06); keys remain unreadable.
            isUnlocked = false
            return false
        }
        do {
            isUnlocked = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            isUnlocked = false
        }
        return isUnlocked
    }
}

// MARK: - Running apps (N-14)

public struct RunningAppService: RunningAppDetecting {
    public init() {}

    public func running(bundleIDs: [String]) async -> [RunningAppInfo] {
        await MainActor.run {
            bundleIDs.flatMap { id in
                NSRunningApplication.runningApplications(withBundleIdentifier: id).map {
                    RunningAppInfo(bundleID: id, name: $0.localizedName ?? id, processID: $0.processIdentifier)
                }
            }
        }
    }

    public func terminate(processID: Int32) async -> Bool {
        await MainActor.run { NSRunningApplication(processIdentifier: processID)?.terminate() ?? false }
    }
}

// MARK: - Sound (CAP-19)

@MainActor
public final class SystemSound: SoundPlaying {
    private var sound: NSSound?

    public init() {}

    public func play(_ effect: SoundEffect) async {
        if sound == nil {
            let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
            sound = NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Grab")
        }
        sound?.stop()
        sound?.play()
    }
}

// MARK: - Color sampler (COL-01)

@MainActor
public final class ScreenColorSampler: ColorSampling {
    public init() {}

    public func pickColor() async -> RGBA? {
        await withCheckedContinuation { continuation in
            NSColorSampler().show { color in
                guard let color = color?.usingColorSpace(.sRGB) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: RGBA(
                    red: color.redComponent, green: color.greenComponent, blue: color.blueComponent, alpha: color.alphaComponent
                ))
            }
        }
    }
}

// MARK: - Logging (no user content, SPEC §01 §7.6)

public struct OSEventLogger: EventLogging {
    private let subsystem: String
    public init(subsystem: String) { self.subsystem = subsystem }

    public func log(_ level: LogLevel, category: String, _ message: String) {
        let logger = Logger(subsystem: subsystem, category: category)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }
}
