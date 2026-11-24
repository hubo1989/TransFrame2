import Testing
import TFDomain
@testable import TFCaptureInfra

@Suite("Window enumeration")
struct WindowEnumeratorTests {
    private let enumerator = WindowEnumerator(ownPID: 100, ownBundleID: "com.transframe.test")
    private let frame = QuartzRect(x: 10, y: 20, width: 300, height: 200)

    @Test func keepsAppWindowsAndPinsAndSkipsDesktopAndOverlays() {
        #expect(enumerator.candidate(id: WindowID(1), pid: 200, owner: "Browser", title: nil, frame: frame, layer: 0)?.kind == .window)
        #expect(enumerator.candidate(id: WindowID(2), pid: 100, owner: "TransFrame", title: "TF2Pin", frame: frame, layer: 3)?.kind == .ownPin)
        #expect(enumerator.candidate(id: WindowID(3), pid: 100, owner: "TransFrame", title: "Settings", frame: frame, layer: 0)?.kind == .window)
        #expect(enumerator.candidate(id: WindowID(3), pid: 100, owner: "TransFrame", title: nil, frame: frame, layer: 500) == nil)
        #expect(enumerator.candidate(id: WindowID(4), pid: 200, owner: "Wallpaper", title: nil, frame: frame, layer: 0) == nil)
        #expect(enumerator.candidate(id: WindowID(5), pid: 200, owner: "Desktop", title: nil, frame: frame, layer: -1) == nil)
    }

    @Test func aFullscreenFloatingSurfaceDoesNotMaskTheTopAppWindow() throws {
        let left = DisplayDescriptor(
            id: DisplayID(1), localizedName: "Left", frame: QuartzRect(x: -800, y: 0, width: 800, height: 600),
            pixelSize: PixelSize(width: 800, height: 600))
        let topology = DisplayTopology(version: 1, displays: [left], primary: left.id)
        let full = left.frame.offsetBy(dx: 1, dy: 1)
        let floating = try #require(enumerator.candidate(id: WindowID(1), pid: 200, owner: "Display Manager", title: nil, frame: full, layer: 3))
        let top = try #require(enumerator.candidate(id: WindowID(2), pid: 300, owner: "Browser", title: nil,
                                                   frame: QuartzRect(x: -760, y: 10, width: 500, height: 400), layer: 0))
        let maximized = try #require(enumerator.candidate(id: WindowID(3), pid: 400, owner: "Editor", title: nil, frame: left.frame, layer: 0))
        #expect(WindowEnumerator.selectable([floating, top, maximized], on: topology).map(\.id) == [top.id, maximized.id])
    }

    @Test func comparesTheSameWindowBeforeAndAfterAndKeepsCurrentStackingOrder() throws {
        let first = try #require(enumerator.candidate(id: WindowID(1), pid: 200, owner: "Browser", title: nil, frame: frame, layer: 0))
        let second = try #require(enumerator.candidate(id: WindowID(2), pid: 200, owner: "Browser", title: nil, frame: frame, layer: 0))
        let movedFrame = frame.offsetBy(dx: 40, dy: 0)
        let moved = try #require(enumerator.candidate(id: first.id, pid: 200, owner: "Browser", title: nil, frame: movedFrame, layer: 0))
        let new = try #require(enumerator.candidate(id: WindowID(3), pid: 200, owner: "Browser", title: nil, frame: frame, layer: 0))
        let result = WindowEnumerator.compare(before: [first, second], after: [new, second, moved])
        #expect(result.map(\.id) == [new.id, second.id, first.id])
        #expect(result.map(\.isStable) == [false, true, false])
    }
}
