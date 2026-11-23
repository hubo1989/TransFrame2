import CoreGraphics
import Foundation
import Testing
import TFDomain
import TFDomainTestSupport
@testable import TFRenderInfra

@Suite("Perf R-06 render execution")
struct RenderPerfTests {
    /// 3840×2160 base, 100 translation placements, 20 annotations through the real executor.
    @Test func renderExecution4K() async throws {
        let renderer = CoreGraphicsRenderer()
        let base = TestImages.pattern(width: 3840, height: 2160, scale: 2)
        let placements = (0..<100).map { i in
            TranslationPlacement(
                segment: SegmentID(), text: "Translated line number \(i) with some words", frame: CanvasRect(x: Double(i % 10) * 380, y: Double(i / 10) * 210, width: 360, height: 40),
                fontSize: 24, color: .black, backdrop: .fill(.white), fit: .fits
            )
        }
        let annotations: [PlacedAnnotation] = (0..<20).map { i in
            PlacedAnnotation(annotation: .rectangle(ShapeAnnotation(rect: DocumentRect(x: Double(i) * 150, y: 100, width: 120, height: 80), strokeColor: RGBA(red: 1, green: 0, blue: 0), lineWidth: 4)), offsetX: 0, offsetY: 0)
        }
        let plan = RenderPlan(
            session: SessionID(), editRevision: 1, canvas: PixelSize(width: 3840, height: 2160), scale: 2, background: .transparent,
            layers: [.base(source: DocumentRect(x: 0, y: 0, width: 3840, height: 2160), destination: CanvasRect(x: 0, y: 0, width: 3840, height: 2160)),
                     .translation(TranslationLayer(mode: .replaceOriginal, placements: placements)), .decorations(annotations)],
            contentFrame: CanvasRect(x: 0, y: 0, width: 3840, height: 2160)
        )
        let samples = try await PerfProbe.measure("R-06") { _ = try await renderer.image(for: plan, base: base) }
        #expect(!samples.isEmpty)
    }
}
