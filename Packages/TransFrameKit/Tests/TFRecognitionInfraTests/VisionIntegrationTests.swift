import AppKit
import CoreGraphics
import Foundation
import Testing
import TFDomain
@testable import TFRecognitionInfra

/// Real Vision OCR on a rendered fixture (no permissions needed): proves the on-device recognition path end to end.
@Suite("Vision OCR integration")
struct VisionIntegrationTests {
    static func fixture(_ text: String, size: CGSize = CGSize(width: 800, height: 200)) -> CGImage {
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 40, y: 80)
        CTLineDraw(line, context)
        return context.makeImage()!
    }

    @Test func recognizesRenderedText() async throws {
        let engine = VisionTextEngine(descriptor: RecognitionEngineFactory(transport: NoTransport(), secrets: { _ throws(AppError) in nil }).descriptor(.visionText, settings: SettingsSnapshot()))
        let raw = try await engine.recognize(PixelImage(cgImage: Self.fixture("Hello TransFrame 2025"), scale: 1), hints: [.english], detail: .lines)
        let text = raw.observations.map(\.text).joined(separator: " ")
        #expect(text.contains("Hello"))
        #expect(text.contains("2025"))
        let box = try #require(raw.observations.first?.box)
        #expect(box.minY < 120 && box.maxY > 60) // top-left origin: text drawn ~80 px from the bottom of a 200 px image
    }

    @Test func sensitiveDetectorFindsCardNumber() async throws {
        let findings = try await LocalSensitiveContentDetector().detect(in: PixelImage(cgImage: Self.fixture("Card 4111 1111 1111 1111", size: CGSize(width: 1000, height: 200)), scale: 1))
        #expect(findings.contains { $0.category == .paymentCard })
    }
}

struct NoTransport: HTTPTransport {
    func send(_ request: HTTPRequest, engine: EngineID) async throws(AppError) -> HTTPResponse { throw .invariant("no network in tests") }
}
