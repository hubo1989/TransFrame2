import CoreGraphics
import Foundation
import Testing
import TFDomain
import TFDomainTestSupport
@testable import TFPipelines

@Suite("In-place overlay styling")
struct OverlayStyleTests {
    /// Dark background with a light bar standing in for a line of text.
    private func terminalImage() -> CGImage {
        let context = CGContext(data: nil, width: 200, height: 60, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.08, green: 0.09, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 60))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        for x in stride(from: 22, to: 170, by: 8) { context.fill(CGRect(x: x, y: 24, width: 5, height: 12)) }
        return context.makeImage()!
    }

    private func analysis(_ texts: [String], box: DocumentRect = DocumentRect(x: 20, y: 20, width: 160, height: 20)) -> AnalysisResult {
        AnalysisResult(
            session: SessionID(), inputRevision: 0, inputFingerprint: ContentHash(sha256: Data()), region: DocumentRect(x: 0, y: 0, width: 200, height: 60),
            segments: texts.map { TextSegment(text: $0, box: box, style: SegmentStyleHint(fontSize: 16)) },
            provenance: Provenance(engine: .visionText, configDigest: "", locality: .onDevice, duration: .zero, sent: .nothing)
        )
    }

    @Test func samplesDarkBackgroundAndLightText() throws {
        let styled = StyleSampler.annotate(analysis(["Waiting for a message"]), image: terminalImage(), origin: DocumentPoint(x: 0, y: 0), appBundleID: nil)
        let style = try #require(styled.segments.first?.style)
        let background = try #require(style.background), foreground = try #require(style.foreground)
        #expect(background.red < 0.2 && background.green < 0.2)
        #expect(foreground.red > 0.7)
        #expect(style.fontSize == 16)
        #expect(style.monospaced == false)
    }

    @Test func terminalAppsAndCodeAreMonospaced() {
        let fromTerminal = StyleSampler.annotate(analysis(["hello there"]), image: terminalImage(), origin: DocumentPoint(x: 0, y: 0),
                                                 appBundleID: "com.apple.Terminal")
        #expect(fromTerminal.segments[0].style?.monospaced == true)
        let code = StyleSampler.annotate(analysis(["let value = compute(x);"]), image: terminalImage(), origin: DocumentPoint(x: 0, y: 0), appBundleID: nil)
        #expect(code.segments[0].style?.monospaced == true)
    }

    @Test(arguments: [
        ("\"titleParts\": [", false), ("0143cb090199/.system_generated/steps/347/output.txt\",", false),
        ("\"fullOutputUri\": \"file:///Users/hubo/.gemini/antigravity/brain/385f\",", false), ("\"titlePrefix\": \"Waiting\",", false),
        ("},", false), ("2026-11-24T09:58:17+08:00", false), ("\"text\": \"for @mentions after #55\"", true),
        ("Note: the build finished in 3 minutes", true), ("Waiting for a message that calls on you by name", true),
    ])
    func translatability(text: String, translates: Bool) {
        #expect(RecognitionNormalizer.translatability(for: text, kind: .text).isTranslatable == translates)
    }

    @Test func jsonValueIsTranslatedAloneAndReassembled() throws {
        let template = try #require(CodeLines.jsonValueTemplate(#"  "text": "for @mentions after #55","#))
        #expect(template.prefix == #"  "text": ""#)
        #expect(template.value == "for @mentions after #55")
        #expect(template.suffix == #"","#)
        let id = SegmentID()
        let outcome = TranslationOutcome(
            operation: OperationID(), routing: .ordered([.mtran]),
            results: [EngineResult(id: .mtran, segments: [BilingualSegment(id: id, source: template.value, translated: "针对 #55 之后的 \"@提及\"",
                                                                          status: .translated, from: .english, to: .simplifiedChinese)])],
            effective: .mtran, target: .simplifiedChinese
        )
        let full = #"  "text": "for @mentions after #55","#
        let rebuilt = DocumentPipelineService.reassemble(outcome, templates: [id: (template.prefix, template.suffix, full)])
        let segment = try #require(rebuilt.effectiveResult?.segments.first)
        #expect(segment.source == full)
        #expect(segment.translated == #"  "text": "针对 #55 之后的 \"@提及\"","#)
    }

    @Test func replaceModeKeepsSizeCentresAndUsesOpaqueSampledBackdrop() throws {
        var a = analysis(["Hello"], box: DocumentRect(x: 10, y: 10, width: 200, height: 20))
        let dark = RGBA(red: 0.1, green: 0.1, blue: 0.1)
        a = AnalysisResult(
            session: a.session, inputRevision: 0, inputFingerprint: a.inputFingerprint, region: a.region,
            segments: [a.segments[0].with(style: SegmentStyleHint(fontSize: 16.4, foreground: .white, background: dark, monospaced: true))],
            provenance: a.provenance
        )
        let translation = BilingualSegment(id: a.segments[0].id, source: "Hello", translated: "你好", status: .translated, from: .english, to: .simplifiedChinese)
        let placements = TranslationLayoutPlanner(measurer: FakeTextMeasurer()).layout(
            analysis: a, translations: [translation], mode: .replaceOriginal, offsetX: 0, offsetY: 0,
            canvas: CanvasRect(x: 0, y: 0, width: 400, height: 100), scale: 1
        )
        let placement = try #require(placements.first)
        #expect(placement.fit == .fits)
        #expect(placement.fontSize == 16.4)
        #expect(placement.monospaced)
        #expect(placement.color == .white)
        #expect(placement.backdrop == .sampled(dark.withAlpha(1)))
        #expect(abs(placement.frame.midY - 20) < 0.6)
        // Cover grows 18 % vertically (no neighbours here) and 2 px sideways.
        #expect(abs((placement.backdropFrame?.minY ?? 0) - 6.4) < 0.01)
        #expect(abs((placement.backdropFrame?.height ?? 0) - 27.2) < 0.01)
        #expect(placement.backdropFrame?.minX == 8)
    }

    @Test func coverStopsHalfwayToNeighbouringLines() {
        let planner = TranslationLayoutPlanner(measurer: FakeTextMeasurer())
        let boxes = [0.0, 24, 48].map { CanvasRect(x: 0, y: $0, width: 100, height: 20) }
        let middle = planner.coverFrame(for: boxes[1], index: 1, boxes: boxes, scale: 1)
        #expect(middle.minY == 22)
        #expect(middle.maxY == 46)
    }
}
