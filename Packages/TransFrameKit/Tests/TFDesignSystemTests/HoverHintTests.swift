import AppKit
import Testing
@testable import TFDesignSystem

@Suite("Hover hints", .serialized)
@MainActor
struct HoverHintTests {
    @Test func plainTextCombinesNameKeysAndDetail() {
        #expect(HoverHintContent("Rectangle", keys: ["R", "1"], detail: "Drag to draw.").plainText == "Rectangle (R / 1)\nDrag to draw.")
        #expect(HoverHintContent("Save").plainText == "Save")
    }

    /// A toolbar window at the capture overlay's shielding level, far off-screen.
    private func toolbarWindow() -> (NSWindow, NSView, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        let first = NSView(frame: NSRect(x: 100, y: 60, width: 28, height: 28))
        let second = NSView(frame: NSRect(x: 132, y: 60, width: 28, height: 28))
        content.addSubview(first)
        content.addSubview(second)
        window.contentView = content
        window.orderFrontRegardless()
        return (window, first, second)
    }

    @Test func hintFloatsAboveTheOverlayToolbarUnderTheControlAndWarmsUp() async throws {
        let (window, first, second) = toolbarWindow()
        defer { window.close() }
        let presenter = HoverHintPresenter()
        let a = HoverHintAnchor(), b = HoverHintAnchor()
        a.view = first
        b.view = second
        presenter.enter(HoverHintContent("Rectangle", keys: ["R", "1"], detail: "Drag to draw."), anchor: a)
        #expect(presenter.shown == nil)
        try await Task.sleep(for: HoverHintPresenter.delay + .milliseconds(150))
        #expect(presenter.shown?.title == "Rectangle")
        let panel = try #require(presenter.panel)
        #expect(panel.isVisible)
        #expect(panel.level.rawValue > window.level.rawValue)
        #expect(panel.ignoresMouseEvents)
        let anchor = window.convertToScreen(first.convert(first.bounds, to: nil))
        #expect(abs(panel.frame.midX - anchor.midX) < 1)
        #expect(panel.frame.maxY <= anchor.minY + 0.5)
        // Moving to the neighbour answers at once.
        presenter.exit(a)
        presenter.enter(HoverHintContent("Ellipse"), anchor: b)
        #expect(presenter.shown?.title == "Ellipse")
        presenter.exit(b)
        #expect(presenter.shown == nil)
        #expect(!panel.isVisible)
    }

    @Test func leavingBeforeTheDelayShowsNothing() async throws {
        let (window, first, _) = toolbarWindow()
        defer { window.close() }
        let presenter = HoverHintPresenter()
        let a = HoverHintAnchor()
        a.view = first
        presenter.enter(HoverHintContent("Arrow"), anchor: a)
        presenter.exit(a)
        try await Task.sleep(for: HoverHintPresenter.delay + .milliseconds(150))
        #expect(presenter.shown == nil)
        #expect(!(presenter.panel?.isVisible ?? false))
    }
}
