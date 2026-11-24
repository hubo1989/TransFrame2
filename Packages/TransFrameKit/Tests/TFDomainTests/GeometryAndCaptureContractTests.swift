import CoreGraphics
import Foundation
import Testing
import TFDomain
import TFDomainTestSupport

@Suite("Coordinate, capture and rendering contracts")
struct GeometryAndCaptureContractTests {
    @Test func pointConversionAndSerializationPreserveNegativeScreenCoordinates() throws {
        let point = CGPoint(x: -420.25, y: 910.5)
        let quartz = QuartzConversion.quartzPoint(fromCocoa: point, primaryHeight: 900)
        #expect(quartz == QuartzPoint(x: -420.25, y: -10.5))
        #expect(QuartzConversion.cocoaPoint(fromQuartz: quartz, primaryHeight: 900) == point)
        let decoded = try JSONDecoder().decode(QuartzPoint.self, from: JSONEncoder().encode(quartz))
        #expect(Set([quartz, decoded]).count == 1)
        #expect(quartz.distance(to: decoded.offsetBy(dx: 3, dy: 4)) == 5)
        let local = quartz.relabeled(as: DisplayLocal.self)
        #expect(local.raw == decoded.raw)
    }

    @Test func rotatedQuadContributesEveryCornerToDocumentBounds() {
        let quad = Quad(
            topLeft: DocumentPoint(x: -1, y: 3), topRight: DocumentPoint(x: 5, y: -1),
            bottomRight: DocumentPoint(x: 8, y: 4), bottomLeft: DocumentPoint(x: 2, y: 8)
        )
        let shifted = quad.offsetBy(dx: 10, dy: 20)
        #expect(shifted.topRight == DocumentPoint(x: 15, y: 19))
        #expect(shifted.boundingBox == DocumentRect(x: 9, y: 19, width: 9, height: 9))
        let clipped = shifted.boundingBox.intersection(DocumentRect(x: 12, y: 0, width: 10, height: 25))
        #expect(clipped == DocumentRect(x: 12, y: 19, width: 6, height: 6))
        #expect(shifted.boundingBox.contains(DocumentPoint(x: 15, y: 23)))
        #expect(shifted.boundingBox.intersection(DocumentRect(x: 18, y: 19, width: 3, height: 3)) == nil)
        let canvas = shifted.boundingBox.relabeled(as: CanvasPixel.self)
        #expect(Set([canvas, CanvasRect(canvas.raw)]).count == 1)
    }

    @Test func frozenFrameScaleUsesActualPixelsAndBoundsIncludeSecondaryDisplay() throws {
        let primary = DisplayDescriptor(id: DisplayID(1), localizedName: "Main", frame: QuartzRect(x: 0, y: 0, width: 100, height: 60),
                                        pixelSize: PixelSize(width: 200, height: 120), isBuiltin: true)
        let secondary = TestImages.display(2, x: -80, y: -20, width: 80, height: 60, scale: 1)
        let frames = TestImages.frozen([primary, secondary], pointer: QuartzPoint(x: -40, y: -10))
        #expect(frames.topology.bounds == QuartzRect(x: -80, y: -20, width: 180, height: 80))
        #expect(frames.topology.display(containing: frames.request.pointer)?.id == secondary.id)
        #expect(frames.topology.display(secondary.id) == secondary)
        #expect(primary.scale == 2 && primary.refreshPeriod == .seconds(1.0 / 60))
        #expect(frames.byteCount == 4 * (200 * 120 + 80 * 60))
        let frame = try #require(frames.frame(for: primary.id))
        let actual = CapturedFrame(
            display: frame.display, image: TestImages.solid(width: 150, height: 90, scale: 2),
            requestedAt: frame.requestedAt, completedAt: frame.completedAt
        )
        #expect(actual.pixelScale == 1.5)
    }

    @Test func renderLayerReportsWhichTranslationCouldNotFit() throws {
        let text = CanvasRect(x: 0, y: 0, width: 20, height: 15)
        let fitted = TranslationPlacement(segment: SegmentID(), text: "Fits", frame: text, fontSize: 12, color: .black, backdrop: .none, fit: .fits)
        let omitted = TranslationPlacement(
            segment: SegmentID(), text: "Long", frame: text, fontSize: 9, color: .black, backdrop: .none, fit: .omitted)
        let layer = TranslationLayer(mode: .replaceOriginal, placements: [fitted, omitted])
        let base = RenderLayer.base(source: DocumentRect(text.raw), destination: text)
        let plan = RenderPlan(
            session: SessionID(), editRevision: 0, canvas: PixelSize(width: 20, height: 15), scale: 1, background: .white,
            layers: [base, .translation(layer), .decorations([]), .redactions([])], contentFrame: text
        )
        #expect(plan.hasValidLayerOrder)
        #expect(plan.translationLayer?.omitted == [omitted])
        #expect(plan.translationLayer?.placements.first == fitted)
        #expect(ColorCopyFormat.rgb.string(for: try #require(RGBA(hex: "#01234580"))) == "rgb(1, 35, 69)")
        #expect(RGBA.contrastRatio(.white, .black) == 21)
    }

    @Test(arguments: [(ExportFormat.png, "png", "public.png", 1.0), (.jpeg, "jpg", "public.jpeg", 0.6), (.heic, "heic", "public.heic", 0.75)])
    func exportFormatsKeepEncodingQualityAndFileMetadataAligned(format: ExportFormat, name: String, type: String, quality: Double) {
        var settings = ExportSettings()
        settings.jpegQuality = 0.6
        settings.heicQuality = 0.75
        #expect(settings.quality(for: format) == quality)
        #expect(format.fileExtension == name)
        #expect(format.uniformTypeIdentifier == type)
        #expect(format.isLossy == (quality < 1))
    }
}
