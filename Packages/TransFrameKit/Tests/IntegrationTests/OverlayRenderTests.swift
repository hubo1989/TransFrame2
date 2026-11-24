import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import TFDomain
@testable import TFPipelines
@testable import TFRecognitionInfra
@testable import TFRenderInfra

/// Real Vision OCR on a dark terminal-style fixture, local style sampling, translatability and the real renderer.
/// Set `TF_RENDER_OUT=<dir>` to write before/after PNGs for visual review.
@Suite("Overlay rendering on a terminal screenshot")
struct OverlayRenderTests {
    static let lines = [
        #"  "result": "Waiting for a message that calls on you by name.","#,
        #"  "fullOutputUri": "file:///Users/hubo/.gemini/brain/385f4498/output.txt","#,
        #"    "titlePrefix": "Waiting","#,
        #"    "titleParts": ["#,
        #"        "text": "for mentions after the last update""#,
        #"    ]"#,
        "Build finished in three minutes",
    ]

    static func fixture() -> CGImage {
        let width = 1400, height = 40 * lines.count + 40
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.07, green: 0.08, blue: 0.09, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = NSFont.monospacedSystemFont(ofSize: 24, weight: .regular)
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor(white: 0.92, alpha: 1)])
            context.textPosition = CGPoint(x: 24, y: Double(height) - 46 - Double(index) * 40)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        return context.makeImage()!
    }

    /// Deterministic stand-in for an engine: marks the text as translated so placement and styling are what is under test.
    static func translate(_ text: String) -> String { "译：" + text.prefix(18) }

    @Test func darkTerminalGetsDarkBackdropsAndDataStaysOriginal() async throws {
        let image = PixelImage(cgImage: Self.fixture(), scale: 1)
        let vision = VisionTextEngine(descriptor: RecognitionEngineFactory(transport: NoTransport(), secrets: { _ throws(AppError) in nil })
            .descriptor(.visionText, settings: SettingsSnapshot()))
        let raw = try await vision.recognize(image, hints: [.english], detail: .lines)
        let region = DocumentRect(x: 0, y: 0, width: Double(image.cgImage.width), height: Double(image.cgImage.height))
        var analysis = RecognitionNormalizer.normalize(
            raw, region: region, session: SessionID(), inputRevision: 0, fingerprint: ContentHash(sha256: Data()),
            provenance: Provenance(engine: .visionText, configDigest: "", locality: .onDevice, duration: .zero, sent: .nothing)
        )
        analysis = StyleSampler.annotate(analysis, image: image.cgImage, origin: DocumentPoint(x: 0, y: 0), appBundleID: "com.apple.Terminal")

        let translatable = analysis.segments.filter { $0.translatability.isTranslatable }.map(\.text)
        #expect(!translatable.contains { $0.contains("titleParts") || $0.contains("file:///") || $0.contains("titlePrefix") })
        #expect(translatable.contains { $0.contains("Build finished") })

        let translations = analysis.segments.filter { $0.translatability.isTranslatable }.map { segment -> BilingualSegment in
            let value = CodeLines.jsonValueTemplate(segment.text).map { $0.prefix + Self.translate($0.value) + $0.suffix } ?? Self.translate(segment.text)
            return BilingualSegment(id: segment.id, source: segment.text, translated: value, status: .translated, from: .english, to: .simplifiedChinese)
        }
        var session = DocumentSession(origin: .importedFile(name: "terminal"), baseImage: image)
        session.analysis = analysis
        session.translation = TranslationOutcome(
            operation: OperationID(), routing: .ordered([.mtran]), results: [EngineResult(id: .mtran, segments: translations)], effective: .mtran,
            target: .simplifiedChinese
        )
        session.presentation.showsTranslationOverlay = true
        session.presentation.overlayMode = .replaceOriginal
        let renderer = CoreGraphicsRenderer()
        let plan = try RenderPlanner(measurer: renderer).plan(for: session, purpose: .screen)
        guard case .translation(let layer)? = plan.layers.first(where: { if case .translation = $0 { true } else { false } }) else {
            Issue.record("no translation layer")
            return
        }
        #expect(!layer.placements.isEmpty)
        for placement in layer.placements where placement.fit != .omitted {
            guard case .sampled(let color) = placement.backdrop else { Issue.record("backdrop should be sampled"); continue }
            #expect(color.red < 0.25 && color.green < 0.25 && color.blue < 0.25)
            #expect(placement.color.red > 0.6)
            #expect(placement.monospaced)
        }
        let rendered = try await renderer.image(for: plan, base: image)
        if let directory = ProcessInfo.processInfo.environment["TF_RENDER_OUT"] {
            try Self.png(image.cgImage, to: URL(fileURLWithPath: directory).appending(path: "overlay-source.png"))
            try Self.png(rendered.cgImage, to: URL(fileURLWithPath: directory).appending(path: "overlay-after.png"))
        }
    }

    static func png(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
    }
}

struct NoTransport: HTTPTransport {
    func send(_ request: HTTPRequest, engine: EngineID) async throws(AppError) -> HTTPResponse { throw .invariant("no network in tests") }
}
