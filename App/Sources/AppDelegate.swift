import AppKit
import TFDomain

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var root: CompositionRoot?
    private var pendingOpenURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchInstant = ContinuousClock.now
        let environment = AppEnvironment(bundle: .main, processInfo: .processInfo)
        let root = CompositionRoot(environment: environment)
        self.root = root
        root.coordinator.start(launchedAt: launchInstant)
        for url in pendingOpenURLs { root.coordinator.route(.openImage(url)) }
        pendingOpenURLs.removeAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        root?.coordinator.shutdown()
    }

    /// Images opened from Finder or dropped on the Dock tile go to the editor (APP-08).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let root else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        for url in urls { root.coordinator.route(.openImage(url)) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

/// Values read once from the bundle and process (identity, paths, test mode).
struct AppEnvironment {
    let bundleID: String
    let version: String
    let build: String
    let copyright: String
    let projectURL: URL?
    let appURL: URL
    let isSmokeTest: Bool
    let isUITest: Bool
    let isDevBuild: Bool

    init(bundle: Bundle, processInfo: ProcessInfo) {
        bundleID = bundle.bundleIdentifier ?? "com.transframe.v2.dev"
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        copyright = bundle.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
        projectURL = (bundle.object(forInfoDictionaryKey: "TFProjectURL") as? String).flatMap(URL.init(string:))
        appURL = bundle.bundleURL
        isSmokeTest = processInfo.environment["TF_SMOKE_TEST"] == "1"
        isUITest = processInfo.arguments.contains("-TFUITest")
        isDevBuild = bundleID.hasSuffix(".dev")
    }

    /// Keychain service separate per identity (ADR-0001 §3).
    var credentialService: String { "\(bundleID).credentials" }

    /// `~/Library/Application Support/TransFrame 2[ Dev]/` (ADR-0009 §2).
    var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: isDevBuild ? "TransFrame 2 Dev" : "TransFrame 2", directoryHint: .isDirectory)
    }

    /// Bundle IDs of TransFrame 1.x, used for the coexistence check (N-14).
    static let legacyBundleIDs = ["com.transframe.app"]
}
