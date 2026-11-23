import CoreGraphics
import Foundation
import Observation
import TFDomain

/// Thread-safe recorder used by every fake to capture calls.
public final class CallLog<Call: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Call] = []
    public init() {}
    public func append(_ call: Call) { lock.withLock { storage.append(call) } }
    public var calls: [Call] { lock.withLock { storage } }
    public var count: Int { lock.withLock { storage.count } }
    public func reset() { lock.withLock { storage.removeAll() } }
}

/// Thread-safe mutable box for programmable fake behaviour.
public final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    public init(_ value: Value) { self.value = value }
    public var current: Value {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    public func mutate<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}

// MARK: - Settings

@MainActor
@Observable
public final class FakeSettings: SettingsProviding {
    public var general = GeneralSettings()
    public var export = ExportSettings()
    public var shortcuts = ShortcutSettings()
    public var annotationDefaults = AnnotationDefaults()
    public var languages = LanguageSettings()
    public var recognition = RecognitionSettings()
    public var engines = EngineSettings()
    public var prompts = PromptSettings()
    public var presentation = PresentationSettings()
    public var privacy = PrivacySettings()
    public var ai = AISettings()
    public var history = HistorySettings()
    public var imageHost = ImageHostSettings()
    public var onboarding = OnboardingSettings()
    public private(set) var resetCount = 0

    public init() {}

    public func resetAll() {
        let fresh = SettingsSnapshot()
        general = fresh.general
        export = fresh.export
        shortcuts = fresh.shortcuts
        annotationDefaults = fresh.annotationDefaults
        languages = fresh.languages
        recognition = fresh.recognition
        engines = fresh.engines
        prompts = fresh.prompts
        presentation = fresh.presentation
        privacy = fresh.privacy
        ai = fresh.ai
        history = fresh.history
        imageHost = fresh.imageHost
        onboarding = fresh.onboarding
        resetCount += 1
    }
}

// MARK: - Credentials

public final class FakeCredentialStore: CredentialStoring, @unchecked Sendable {
    public let secrets = Locked<[CredentialRef: String]>([:])
    public let failure = Locked<AppError?>(nil)
    public init(_ initial: [CredentialRef: String] = [:]) { secrets.current = initial }

    public func secret(for ref: CredentialRef) async throws(AppError) -> String? {
        if let failure = failure.current { throw failure }
        return secrets.current[ref]
    }
    public func store(_ secret: String, for ref: CredentialRef) async throws(AppError) {
        if let failure = failure.current { throw failure }
        secrets.mutate { $0[ref] = secret }
    }
    public func remove(_ ref: CredentialRef) async throws(AppError) { secrets.mutate { $0[ref] = nil } }
    public func hasSecret(for ref: CredentialRef) async -> Bool { secrets.current[ref]?.isEmpty == false }
}

// MARK: - Pasteboard

public final class FakePasteboard: PasteboardAccessing, @unchecked Sendable {
    public let contents = Locked<[PasteboardContent]>([])
    public let changes = Locked(0)
    public let restored = CallLog<PasteboardSnapshot>()
    public init() {}

    public func write(_ content: PasteboardContent) async throws(AppError) {
        contents.mutate { $0.append(content) }
        changes.mutate { $0 += 1 }
    }
    public func writeImage(_ image: PixelImage) async throws(AppError) {
        try await write(.image(Data(count: image.pixelSize.pixelCount)))
    }
    public func readString() async -> String? {
        for case .string(let s) in contents.current.reversed() { return s }
        return nil
    }
    public func changeCount() async -> Int { changes.current }
    public func snapshot() async -> PasteboardSnapshot {
        PasteboardSnapshot(items: contents.current.map {
            switch $0 {
            case .string(let s): ["public.utf8-plain-text": Data(s.utf8)]
            case .image(let d): ["public.png": d]
            }
        })
    }
    public func restore(_ snapshot: PasteboardSnapshot) async {
        restored.append(snapshot)
        contents.current = snapshot.items.compactMap { item in
            if let d = item["public.utf8-plain-text"] { return .string(String(decoding: d, as: UTF8.self)) }
            if let d = item["public.png"] { return .image(d) }
            return nil
        }
        changes.mutate { $0 += 1 }
    }
    public var lastString: String? {
        for case .string(let s) in contents.current.reversed() { return s }
        return nil
    }
}

// MARK: - Permissions, hotkeys, apps, sound, logging

public final class FakePermissions: PermissionChecking, PermissionGuiding, @unchecked Sendable {
    public let granted = Locked<Set<PermissionKind>>([])
    public let guided = CallLog<PermissionKind>()
    public let openedPanes = CallLog<SystemSettingsPane>()
    public let grantWhenGuided = Locked(false)
    public init(granted: Set<PermissionKind> = Set(PermissionKind.allCases)) { self.granted.current = granted }

    public func isGranted(_ kind: PermissionKind) async -> Bool { granted.current.contains(kind) }
    @MainActor public func guide(_ kind: PermissionKind, from sourceFrame: CGRect?) async -> Bool {
        guided.append(kind)
        if grantWhenGuided.current { granted.mutate { _ = $0.insert(kind) } }
        return granted.current.contains(kind)
    }
    @MainActor public func openSystemSettings(_ pane: SystemSettingsPane) { openedPanes.append(pane) }
}

public final class FakeHotkeys: HotkeyRegistering, @unchecked Sendable {
    public let registrations = CallLog<[HotkeyAction: GlobalShortcut]>()
    public let failing = Locked<Set<HotkeyAction>>([])
    public let unregisterCount = Locked(0)
    private let handler = Locked<(@Sendable (HotkeyAction, ContinuousClock.Instant) -> Void)?>(nil)
    public init() {}

    public func register(
        _ bindings: [HotkeyAction: GlobalShortcut],
        handler: @escaping @Sendable (HotkeyAction, ContinuousClock.Instant) -> Void
    ) async -> [HotkeyAction] {
        registrations.append(bindings)
        self.handler.current = handler
        return bindings.keys.filter { failing.current.contains($0) }.sorted { $0.rawValue < $1.rawValue }
    }
    public func unregisterAll() async {
        unregisterCount.mutate { $0 += 1 }
        handler.current = nil
    }
    /// Simulates a key press.
    public func press(_ action: HotkeyAction) { handler.current?(action, .now) }
    public var lastBindings: [HotkeyAction: GlobalShortcut]? { registrations.calls.last }
}

public final class FakeRunningApps: RunningAppDetecting, @unchecked Sendable {
    public let apps = Locked<[RunningAppInfo]>([])
    public let terminated = CallLog<Int32>()
    public init(_ apps: [RunningAppInfo] = []) { self.apps.current = apps }
    public func running(bundleIDs: [String]) async -> [RunningAppInfo] { apps.current.filter { bundleIDs.contains($0.bundleID) } }
    public func terminate(processID: Int32) async -> Bool {
        terminated.append(processID)
        apps.mutate { $0.removeAll { $0.processID == processID } }
        return true
    }
}

public final class FakeSound: SoundPlaying, @unchecked Sendable {
    public let played = CallLog<SoundEffect>()
    public init() {}
    public func play(_ effect: SoundEffect) async { played.append(effect) }
}

public final class FakeLogger: EventLogging, @unchecked Sendable {
    public let entries = CallLog<String>()
    public init() {}
    public func log(_ level: LogLevel, category: String, _ message: String) { entries.append("\(level.rawValue) \(category) \(message)") }
}

public final class FakePerformanceRecorder: PerformanceRecording, @unchecked Sendable {
    public let recorded = CallLog<PerformanceSample>()
    public init() {}
    public func record(_ sample: PerformanceSample) { recorded.append(sample) }
    public func samples() async -> [PerformanceSample] { recorded.calls }
    public func samples(_ budget: String) -> [PerformanceSample] { recorded.calls.filter { $0.budget == budget } }
}

@MainActor
public final class FakeRouter: AppRouting {
    public private(set) var routes: [AppRoute] = []
    public init() {}
    public func route(_ route: AppRoute) { routes.append(route) }
}

public final class FakeUpdater: AppUpdating, @unchecked Sendable {
    public let started = Locked(0)
    public let checks = Locked(0)
    public init() {}
    @MainActor public func start() { started.mutate { $0 += 1 } }
    @MainActor public func checkForUpdates() { checks.mutate { $0 += 1 } }
    @MainActor public var canCheckForUpdates: Bool { started.current > 0 }
}

public final class FakeUnlocker: CredentialUnlocking, @unchecked Sendable {
    public let unlocked = Locked(false)
    public let succeeds = Locked(true)
    public let attempts = Locked(0)
    public init() {}
    @MainActor public var isUnlocked: Bool { unlocked.current }
    @MainActor public func unlock(reason: String) async -> Bool {
        attempts.mutate { $0 += 1 }
        if succeeds.current { unlocked.current = true }
        return unlocked.current
    }
}

// MARK: - Network

/// Fails any request that has no programmed response, so tests can never reach the network (SPEC §06 §3).
public final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {
    public typealias Responder = @Sendable (HTTPRequest) async throws(AppError) -> HTTPResponse
    public let requests = CallLog<HTTPRequest>()
    private let responders = Locked<[(match: @Sendable (HTTPRequest) -> Bool, respond: Responder)]>([])

    public init() {}

    public func on(_ match: @escaping @Sendable (HTTPRequest) -> Bool, respond: @escaping Responder) {
        responders.mutate { $0.append((match, respond)) }
    }

    public func on(pathSuffix: String, status: Int = 200, json: String, headers: [String: String] = [:]) {
        on({ $0.url.path.hasSuffix(pathSuffix) }) { _ throws(AppError) in
            HTTPResponse(status: status, headers: headers, body: Data(json.utf8))
        }
    }

    public func onAny(status: Int = 200, json: String) {
        on({ _ in true }) { _ throws(AppError) in HTTPResponse(status: status, body: Data(json.utf8)) }
    }

    public func send(_ request: HTTPRequest, engine: EngineID) async throws(AppError) -> HTTPResponse {
        requests.append(request)
        if Task.isCancelled { throw .cancelled }
        guard let responder = responders.current.last(where: { $0.match(request) }) else {
            throw .invariant("unexpected network request to \(request.url.host ?? "?")")
        }
        return try await responder.respond(request)
    }
}
