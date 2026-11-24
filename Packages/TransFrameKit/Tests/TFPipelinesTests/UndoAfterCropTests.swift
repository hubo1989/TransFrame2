import Foundation
import Testing
import TFDomain
import TFDomainTestSupport
@testable import TFPipelines

/// A crop discards the analysis; text revisions made against it must not jam the undo stack afterwards (review: Codex P2).
@Suite("Undo after crop")
struct UndoAfterCropTests {
    @Test func cropUndoDoesNotStrandEarlierTextRevisions() async throws {
        let store = DocumentSessionStore(composer: FakeFrameComposer())
        let segment = TextSegment(text: "Hello", box: DocumentRect(x: 0, y: 0, width: 50, height: 10))
        var session = DocumentSession(origin: .importedFile(name: "test"), baseImage: TestImages.pattern(width: 100, height: 100))
        session.analysis = AnalysisResult(
            session: session.id, inputRevision: 0, inputFingerprint: ContentHash(sha256: Data()),
            region: DocumentRect(x: 0, y: 0, width: 100, height: 100), segments: [segment],
            provenance: Provenance(engine: .visionText, configDigest: "", locality: .onDevice, duration: .zero, sent: .nothing))
        let id = await store.insert(session)
        // 1. An annotation, 2. a text revision, 3. a crop.
        let rect = Annotation.rectangle(ShapeAnnotation(rect: DocumentRect(x: 10, y: 10, width: 20, height: 20), strokeColor: .black, lineWidth: 2))
        try await store.apply(.insert(rect, into: try await store.snapshot(of: id), label: "add"), to: id)
        let revise = try #require(EditTransaction.reviseSegment(segment.id, text: "Hallo", in: try await store.snapshot(of: id), label: "revise"))
        try await store.apply(revise, to: id)
        let crop = try #require(EditTransaction.setCrop(DocumentRect(x: 0, y: 0, width: 60, height: 60), in: try await store.snapshot(of: id), label: "crop"))
        try await store.apply(crop, to: id)
        #expect(try await store.snapshot(of: id).analysis == nil)
        // Undo the crop, then keep undoing: the revision is gone with its analysis, the annotation undoes normally.
        #expect(await store.undo(id))
        #expect(try await store.snapshot(of: id).crop == nil)
        #expect(await store.undo(id))
        #expect(try await store.snapshot(of: id).annotations.isEmpty)
        #expect(!(await store.canUndo(id)))
        // Redo works back up without tripping over the stale revision either.
        #expect(await store.redo(id))
        #expect(try await store.snapshot(of: id).annotations.count == 1)
        #expect(await store.redo(id))
        #expect(try await store.snapshot(of: id).crop != nil)
    }
}
