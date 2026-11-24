import AppKit

// Menu-bar app (LSUIElement): AppKit entry point, SwiftUI for window content (APP-01).
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        application.run()
    }
}
