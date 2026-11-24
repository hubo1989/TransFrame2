import Foundation
import Testing
import TFDomain
@testable import TFPipelines

@Suite("Automatic on-image mode")
struct OverlayModeAdvisorTests {
    private func analysis(gap: Double, count: Int = 4, monospaced: Bool = false) -> AnalysisResult {
        let segments = (0..<count).map { i in
            TextSegment(text: "Line \(i) of text", box: DocumentRect(x: 0, y: Double(i) * (20 + gap), width: 300, height: 20),
                        style: SegmentStyleHint(fontSize: 16, monospaced: monospaced))
        }
        return AnalysisResult(
            session: SessionID(), inputRevision: 0, inputFingerprint: ContentHash(sha256: Data()), region: DocumentRect(x: 0, y: 0, width: 400, height: 400),
            segments: segments, provenance: Provenance(engine: .visionText, configDigest: "", locality: .onDevice, duration: .zero, sent: .nothing)
        )
    }

    @Test func denseLinesReplaceSpacedLinesGoBelow() {
        #expect(OverlayModeAdvisor.mode(for: analysis(gap: 4)) == .replaceOriginal)
        #expect(OverlayModeAdvisor.mode(for: analysis(gap: 24)) == .belowOriginal)
    }

    @Test func monospacedSourcesReplace() {
        #expect(OverlayModeAdvisor.mode(for: analysis(gap: 30, monospaced: true)) == .replaceOriginal)
    }

    @Test func singleLineGoesBelow() {
        #expect(OverlayModeAdvisor.mode(for: analysis(gap: 0, count: 1)) == .belowOriginal)
    }

    @Test func settingDecodesWithoutTheNewKey() throws {
        let decoded = try JSONDecoder().decode(PresentationSettings.self, from: Data(#"{"schemaVersion":1,"overlayMode":"replaceOriginal"}"#.utf8))
        #expect(decoded.automaticOverlay)
        #expect(decoded.overlayMode == .replaceOriginal)
    }
}
