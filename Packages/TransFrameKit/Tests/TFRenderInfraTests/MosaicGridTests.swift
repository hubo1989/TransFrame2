import CoreGraphics
import Foundation
import Testing
import TFDomain
import TFDomainTestSupport
@testable import TFRenderInfra

@Suite("Mosaic grid")
struct MosaicGridTests {
    private func render(_ annotations: [Annotation], base: PixelImage) async throws -> CGImage {
        let size = PixelSize(width: base.cgImage.width, height: base.cgImage.height)
        let full = DocumentRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height))
        let plan = RenderPlan(
            session: SessionID(), editRevision: 1, canvas: size, scale: 1, background: .transparent,
            layers: [
                .base(source: full, destination: CanvasRect(full.raw)),
                .decorations(annotations.map { PlacedAnnotation(annotation: $0, offsetX: 0, offsetY: 0) }),
            ],
            contentFrame: CanvasRect(full.raw))
        return try await CoreGraphicsRenderer().image(for: plan, base: base).cgImage
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let context = TestImages.context(width: 1, height: 1)!
        context.draw(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return [data[0], data[1], data[2], data[3]]
    }

    @Test func blocksSitOnTheImageGridSoMovingTheRegionDoesNotReGrid() async throws {
        let base = TestImages.pattern(width: 200, height: 150)
        let a = try await render([.mosaic(MosaicAnnotation(rect: DocumentRect(x: 10, y: 10, width: 120, height: 100), blockSize: 12))], base: base)
        let b = try await render([.mosaic(MosaicAnnotation(rect: DocumentRect(x: 17, y: 15, width: 120, height: 100), blockSize: 12))], base: base)
        for (x, y) in [(40, 40), (61, 70), (100, 99)] { #expect(pixel(a, x, y) == pixel(b, x, y)) }
        // One block is one color.
        #expect(pixel(a, 48, 48) == pixel(a, 59, 59))
        #expect(pixel(a, 48, 48) != pixel(a, 60, 48) || pixel(a, 48, 48) != pixel(a, 48, 60))
    }

    @Test func partialEdgeBlocksAreOpaqueAndTheRegionIsClipped() async throws {
        let base = TestImages.pattern(width: 100, height: 70)
        let image = try await render([.mosaic(MosaicAnnotation(rect: DocumentRect(x: 30, y: 20, width: 70, height: 50), blockSize: 12))], base: base)
        #expect(pixel(image, 99, 69)[3] == 255)
        #expect(pixel(image, 29, 30) == pixel(try await render([], base: base), 29, 30))
        let tile = try #require(CoreGraphicsRenderer().mosaic(base, CGRect(x: 30, y: 20, width: 70, height: 50), 12))
        #expect(tile.cover == CGRect(x: 24, y: 12, width: 84, height: 60))
        #expect(tile.region == CGRect(x: 30, y: 20, width: 70, height: 50))
    }
}
