import Foundation
import Testing
import TFDomain
import TFDomainTestSupport

@Suite("Annotation geometry and edit inverses")
struct AnnotationTransactionTests {
    private let first = DocumentPoint(x: 10, y: 20)
    private let last = DocumentPoint(x: 30, y: 35)
    private let rect = DocumentRect(x: 10, y: 20, width: 20, height: 15)

    @Test func boundsIncludeStrokeArrowheadAndCalloutPointer() throws {
        let shape = ShapeAnnotation(rect: rect, strokeColor: .black, lineWidth: 2)
        let padded = DocumentRect(x: 9, y: 19, width: 22, height: 17)
        let line = LineAnnotation(start: last, end: first, color: .black, lineWidth: 2)
        let path = PathAnnotation(points: [last, first], color: .black, lineWidth: 2)
        let text = TextAnnotation(anchor: first, maxWidth: 80, text: "line one\n\nline three", color: .black, fontSize: 12, fontName: "Fixture")
        let number = NumberLabelAnnotation(center: first, number: 2, color: .white, diameter: 8)
        let callout = CalloutAnnotation(bubble: rect, pointer: DocumentPoint(x: 5, y: 45), text: "caption", color: .white, fontSize: 12,
                                        fillColor: .black)
        let mosaic = MosaicAnnotation(rect: rect, blockSize: 4, isPrivacy: true)
        let redaction = RedactionAnnotation(rect: rect)
        let fixtures: [(Annotation, DocumentRect, AnnotationRole)] = [
            (.rectangle(shape), padded, .decoration),
            (.ellipse(shape), padded, .decoration),
            (.highlight(shape), padded, .decoration),
            (.line(line), padded, .decoration),
            (.arrow(line), DocumentRect(x: 4, y: 14, width: 32, height: 27), .decoration),
            (.freehand(path), padded, .decoration),
            (.text(text), DocumentRect(x: 10, y: 20, width: 80, height: 45), .decoration),
            (.numberLabel(number), DocumentRect(x: 6, y: 16, width: 8, height: 8), .decoration),
            (.callout(callout), DocumentRect(x: 5, y: 20, width: 25, height: 25), .decoration),
            (.mosaic(mosaic), rect, .redaction),
            (.redaction(redaction), rect, .redaction),
        ]
        #expect(Set(fixtures.map { $0.0.kind }) == Set(AnnotationKind.allCases))
        for (annotation, bounds, role) in fixtures {
            #expect(annotation.bounds == bounds, "\(annotation.kind)")
            #expect(annotation.role == role)
            let translated = annotation.translated(dx: -15, dy: 7)
            #expect(translated.id == annotation.id)
            #expect(translated.kind == annotation.kind)
            #expect(translated.bounds == bounds.offsetBy(dx: -15, dy: 7))
            #expect(translated.translated(dx: 15, dy: -7) == annotation)
            #expect(try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(translated)) == translated)
        }
    }

    @Test func emptyFreehandAndUnconstrainedTextHaveUsableBounds() {
        let empty = Annotation.freehand(PathAnnotation(points: [], color: .black, lineWidth: 2))
        #expect(empty.bounds.isEmpty)
        let text = Annotation.text(TextAnnotation(anchor: first, text: "A\nWider", color: .black, fontSize: 10))
        #expect(text.bounds == DocumentRect(x: 10, y: 20, width: 31, height: 25))
        let mosaic = Annotation.mosaic(MosaicAnnotation(rect: rect, blockSize: 4))
        #expect(!mosaic.affectsAnalysisInput)
    }

    @Test func removingNonAdjacentAnnotationsRestoresOriginalStackOrder() throws {
        let bottom = Annotation.redaction(RedactionAnnotation(rect: rect))
        let middle = Annotation.mosaic(MosaicAnnotation(rect: rect, blockSize: 8))
        let top = Annotation.rectangle(ShapeAnnotation(rect: rect, strokeColor: .black, lineWidth: 2))
        let session = makeSession([bottom, middle, top])
        let removal = try #require(EditTransaction.remove([top.id, AnnotationID(), bottom.id], from: session, label: "remove"))
        #expect(removal.forward == [.removeAnnotation(bottom.id), .removeAnnotation(top.id)])
        #expect(removal.inverse == [.insertAnnotation(bottom, at: 0), .insertAnnotation(top, at: 2)])
        #expect(EditTransaction.remove([AnnotationID()], from: session, label: "remove") == nil)

        let move = try #require(EditTransaction.move(bottom.id, to: 99, in: session, label: "front"))
        #expect(move.forward == [.moveAnnotation(bottom.id, to: 2)])
        #expect(move.inverse == [.moveAnnotation(bottom.id, to: 0)])
        #expect(EditTransaction.move(top.id, to: 2, in: session, label: "front") == nil)
        #expect(EditTransaction.move(AnnotationID(), to: 0, in: session, label: "front") == nil)
    }

    @Test func replacementAndBatchInsertionRetainIdentityAndOriginalValues() throws {
        let before = Annotation.redaction(RedactionAnnotation(rect: rect))
        let after = before.translated(dx: 5, dy: 10)
        let session = makeSession([before])
        let replacement = try #require(EditTransaction.replace(after, in: session, label: "move annotation"))
        #expect(replacement.forward == [.replaceAnnotation(after)])
        #expect(replacement.inverse == [.replaceAnnotation(before)])
        #expect(EditTransaction.replace(before, in: session, label: "unchanged") == nil)
        let mosaic = Annotation.mosaic(MosaicAnnotation(rect: rect, blockSize: 6, isPrivacy: true))
        let redaction = Annotation.redaction(RedactionAnnotation(rect: rect.offsetBy(dx: 15, dy: 0)))
        #expect(EditTransaction.replace(redaction, in: session, label: "missing") == nil)
        let inserted = try #require(EditTransaction.insertAll([mosaic, redaction], into: session, label: "mosaic"))
        #expect(inserted.forward == [.insertAnnotation(mosaic, at: 1), .insertAnnotation(redaction, at: 2)])
        #expect(inserted.inverse == [.removeAnnotation(redaction.id), .removeAnnotation(mosaic.id)])
        #expect(EditTransaction.insertAll([], into: session, label: "mosaic") == nil)
    }

    @Test func cropAndPresentationTransactionsCapturePreviousState() throws {
        var session = makeSession([])
        #expect(EditTransaction.setCrop(session.imageBounds, in: session, label: "crop") == nil)
        session.crop = rect
        let restore = try #require(EditTransaction.setCrop(session.imageBounds, in: session, label: "crop"))
        #expect(restore.forward == [.setCrop(nil)])
        #expect(restore.inverse == [.setCrop(rect)])

        let updated = PresentationOptions(showsTranslationOverlay: true, overlayMode: .replaceOriginal, beautify: true)
        let presentation = try #require(EditTransaction.setPresentation(updated, in: session, label: "presentation"))
        #expect(presentation.forward == [.setPresentation(updated)])
        #expect(presentation.inverse == [.setPresentation(session.presentation)])
        #expect(EditTransaction.setPresentation(session.presentation, in: session, label: "presentation") == nil)
        #expect(EditTransaction.reviseSegment(SegmentID(), text: "new", in: session, label: "revise") == nil)
    }

    private func makeSession(_ annotations: [Annotation]) -> DocumentSession {
        DocumentSession(origin: .importedFile(name: "fixture"), baseImage: TestImages.solid(width: 100, height: 80), annotations: annotations)
    }
}
