import AppKit
import Foundation
import Testing
import TFDomain
import TFDomainTestSupport
import TFRenderInfra
@testable import TFWorkspaceUI

/// Interactive annotation hot paths on a 3840×2160 @2x canvas (a full 4K display): one drag frame is event handling plus
/// the overlay redraw; commit latency runs from mouse-up until the canvas shows the new revision.
@Suite("Perf annotation canvas", .serialized)
@MainActor
struct AnnotationPerfTests {
    private static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

    private func report(_ name: String, _ values: [Double]) {
        guard !values.isEmpty else { return }
        let p50 = PerfProbe.percentile(values, 50), p95 = PerfProbe.percentile(values, 95), max = values.max() ?? 0
        print(String(format: "PERF %-22@ n=%4d p50=%7.3f ms p95=%7.3f ms max=%7.3f ms", name as NSString, values.count, p50, p95, max))
        if let directory = ProcessInfo.processInfo.environment["TF_PERF_OUT"] {
            let url = URL(fileURLWithPath: directory).appending(path: "\(name).json")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: values).write(to: url)
        }
    }

    /// One drag frame: the event, then the overlay redraw into a backing-store-sized bitmap clipped to the dirty region.
    private func frame(_ h: CanvasHarness, _ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        h.drawOverlayFrame()
        return Self.ms(.now - start)
    }

    @Test func dragFramesAndCommitLatency() async throws {
        let h = await CanvasHarness(width: 3840, height: 2160, scale: 2)
        defer { h.tearDown() }
        let rounds = PerfProbe.enabled ? 12 : 2
        var rectFrames: [Double] = [], moveFrames: [Double] = [], mosaicFrames: [Double] = [], commits: [Double] = []
        for round in 0..<rounds {
            let y = 80 + Double(round % 6) * 150, x = 80 + Double(round / 6) * 900
            // Rectangle: create.
            h.editor.tool = .rectangle
            h.down(CGPoint(x: x, y: y))
            for i in 1...60 { rectFrames.append(frame(h) { h.drag(CGPoint(x: x + Double(i) * 6, y: y + Double(i) * 2)) }) }
            var before = try await h.session().editRevision
            var start = ContinuousClock.now
            h.up(CGPoint(x: x + 360, y: y + 120))
            await h.waitForRender(revision: before + 1)
            commits.append(Self.ms(.now - start))
            // Move it.
            h.editor.tool = nil
            h.down(CGPoint(x: x, y: y + 60))
            for i in 1...60 { moveFrames.append(frame(h) { h.drag(CGPoint(x: x + Double(i) * 3, y: y + 60 + Double(i))) }) }
            before = try await h.session().editRevision
            start = ContinuousClock.now
            h.up(CGPoint(x: x + 180, y: y + 120))
            await h.waitForRender(revision: before + 1)
            commits.append(Self.ms(.now - start))
            // Mosaic: grows from the top-left corner.
            h.editor.tool = .mosaic
            h.down(CGPoint(x: x + 420, y: y))
            for i in 1...60 { mosaicFrames.append(frame(h) { h.drag(CGPoint(x: x + 420 + Double(i) * 6, y: y + Double(i) * 2)) }) }
            before = try await h.session().editRevision
            h.up(CGPoint(x: x + 780, y: y + 120))
            await h.waitForRender(revision: before + 1)
        }
        report("ANN-drag-rect", rectFrames)
        report("ANN-drag-move", moveFrames)
        report("ANN-drag-mosaic", mosaicFrames)
        report("ANN-commit", commits)
        #expect(!commits.isEmpty)
    }

    @Test func longFreehandStroke() async throws {
        let h = await CanvasHarness(width: 3840, height: 2160, scale: 2)
        defer { h.tearDown() }
        h.editor.tool = .freehand
        h.down(CGPoint(x: 100, y: 100))
        let count = PerfProbe.enabled ? 3000 : 300
        var frames: [Double] = []
        for i in 1...count {
            let t = Double(i) / 40
            let p = CGPoint(x: 100 + Double(i) * 0.5, y: 500 + sin(t) * 300)
            let d = frame(h) { h.drag(p) }
            if i > count - 200 { frames.append(d) }
        }
        h.up(CGPoint(x: 100 + Double(count) * 0.5, y: 500))
        report("ANN-freehand-tail", frames)
        #expect(!frames.isEmpty)
    }
}
