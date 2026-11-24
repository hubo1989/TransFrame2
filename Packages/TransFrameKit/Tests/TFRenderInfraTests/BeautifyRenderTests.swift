import CoreGraphics
import Foundation
import Testing
import TFDomain
import TFDomainTestSupport
@testable import TFRenderInfra

@Suite("Beautify frame")
struct BeautifyRenderTests {
    private func render(_ style: BeautifyStyle) async throws -> CGImage {
        let base = TestImages.solid(width: 200, height: 100, color: RGBA(red: 1, green: 0, blue: 0))
        let plan = RenderPlan(
            session: SessionID(), editRevision: 1, canvas: PixelSize(width: 272, height: 172), scale: 1, background: .beautify(style),
            layers: [.base(source: DocumentRect(x: 0, y: 0, width: 200, height: 100), destination: CanvasRect(x: 36, y: 36, width: 200, height: 100))],
            contentFrame: CanvasRect(x: 36, y: 36, width: 200, height: 100))
        return try await CoreGraphicsRenderer().image(for: plan, base: base).cgImage
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let context = TestImages.context(width: 1, height: 1)!
        context.draw(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return [data[0], data[1], data[2], data[3]]
    }

    @Test func marginIsTransparentWithAShadowAndNoBackdrop() async throws {
        let image = try await render(.transparent)
        #expect(pixel(image, 1, 1)[3] < 8)
        #expect(pixel(image, 136, 86) == [255, 0, 0, 255])
        // Rounded corner: just inside the content box but outside the arc is not content red.
        #expect(pixel(image, 37, 37) != [255, 0, 0, 255])
        // The shadow falls into the margin under the content.
        let below = pixel(image, 136, 150), above = pixel(image, 136, 22)
        #expect(below[3] > 10 && below[0] < 40, "below \(below) above \(above)")
        #expect(below[3] > above[3], "below \(below) above \(above)")
    }

    @Test func jpegGetsAWhiteMatte() async throws {
        let image = try await render(.matte(.white))
        #expect(pixel(image, 1, 1) == [255, 255, 255, 255])
        #expect(pixel(image, 136, 86) == [255, 0, 0, 255])
    }
}
