import XCTest

/// Launches the Debug identity in UI-test mode (no hotkeys, no onboarding) and checks it stays running.
final class LaunchSmokeUITests: XCTestCase {
    @MainActor
    func testLaunchesAsMenuBarApp() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TFUITest"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10) || app.state == .runningBackground)
        app.terminate()
    }
}
