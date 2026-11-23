import CoreGraphics
import Foundation
import Testing
import TFDomain
import TFDomainTestSupport
@testable import TFPipelines

@Suite("Recognition structure, reading order and tile reconciliation")
struct StructuredRecognitionTests {
    private let region = DocumentRect(x: 40, y: 60, width: 300, height: 200)

    private func normalize(_ raw: RawRecognition) -> AnalysisResult {
        RecognitionNormalizer.normalize(
            raw, region: region, session: SessionID(), inputRevision: 5, fingerprint: ContentHash(sha256: Data()),
            provenance: Provenance(engine: .openAICompatible, configDigest: "fixture", locality: .cloud, duration: .zero, sent: raw.sent)
        )
    }

    @Test func nestedBlocksFollowDepthFirstOrderAndRemapGeometryAndTableIDs() throws {
        let frame = FrameRect(x: 0, y: 0, width: 120, height: 100)
        let blocks = [
            RawBlock(kind: .list(ordered: true), box: frame),
            RawBlock(kind: .table(rows: 2, columns: 2), box: frame, parentIndex: 0),
            RawBlock(kind: .codeBlock, box: frame, parentIndex: 0),
            RawBlock(kind: .formulaBlock, box: frame, parentIndex: 7),
            RawBlock(kind: .figure, box: frame, parentIndex: 4),
            RawBlock(kind: .handwriting, box: frame),
            RawBlock(kind: .paragraph, box: frame),
        ]
        let cell = TableCellRef(table: BlockID(), row: 1, column: 0, columnSpan: 2, isHeader: true)
        let corners = [CGPoint(x: 3, y: 7), CGPoint(x: 13, y: 7), CGPoint(x: 13, y: 13), CGPoint(x: 3, y: 13)]
        let tableBox = FrameRect(x: 3, y: 7, width: 10, height: 6)
        let style = SegmentStyleHint(fontSize: 12, foreground: .black, alignment: .center)
        let raw = RawRecognition(observations: [
            RawObservation(text: "Loose caption", box: tableBox, kind: .caption, blockIndex: 77),
            RawObservation(text: "x squared", box: tableBox, kind: .formula(latex: "x^2"), blockIndex: 3),
            RawObservation(text: "Snippet", box: tableBox, kind: .code(language: "swift"), blockIndex: 2),
            RawObservation(text: "Data", box: tableBox, quad: corners, confidence: 0.9, language: .english, kind: .tableCell(cell),
                           blockIndex: 1, style: style),
            RawObservation(text: "Section", box: tableBox.offsetBy(dx: 15, dy: 22), kind: .listItem(level: 1, marker: "1."), blockIndex: 0),
        ], blocks: blocks, languages: [.english], sent: .image)
        let result = normalize(raw)
        #expect(result.segments.map(\.text) == ["Section", "Data", "Snippet", "x squared", "Loose caption"])
        #expect(result.blocks.map(\.kind) == [
            .list(ordered: true), .table(rows: 2, columns: 2), .codeBlock, .formulaBlock, .figure, .handwriting, .paragraph,
        ])
        #expect(result.blocks[1].parent == result.blocks[0].id)
        #expect(result.blocks[3].parent == nil && result.blocks[4].parent == nil)
        #expect(result.segments.last?.parent == nil)
        #expect(result.blocks[0].box == DocumentRect(x: 40, y: 60, width: 120, height: 100))
        let table = try #require(result.segments.first { $0.kind.tableCell != nil })
        #expect(table.box == DocumentRect(x: 43, y: 67, width: 10, height: 6))
        #expect(table.quad?.boundingBox == table.box)
        #expect(table.style == style && table.language == .english && table.confidence == 0.9)
        #expect(table.kind.tableCell == TableCellRef(table: result.blocks[1].id, row: 1, column: 0, columnSpan: 2, isHeader: true))
        #expect(result.segments[2].translatability == .keepOriginal(.code))
        #expect(result.segments[3].translatability == .keepOriginal(.formula))
        #expect(StructureValidation.issues(segments: result.segments, blocks: result.blocks).isEmpty)
    }

    @Test func visualLinesMergeAcrossSmallGapsAndExcludeOnlyNoiseOrDuplicates() {
        let letter = FrameRect(x: 0, y: 0, width: 12, height: 10)
        let raw = RawRecognition(observations: [
            RawObservation(text: "界", box: letter.offsetBy(dx: 13, dy: 14), confidence: 0.8),
            RawObservation(text: "Good", box: letter, confidence: 0.9),
            RawObservation(text: "morning", box: letter.offsetBy(dx: 14, dy: 0), confidence: 0.7),
            RawObservation(text: "世", box: letter.offsetBy(dx: 0, dy: 14)),
            RawObservation(text: "?", box: letter.offsetBy(dx: 60, dy: 0)),
            RawObservation(text: "uncertain", box: letter.offsetBy(dx: 60, dy: 14), confidence: 0.1),
            RawObservation(text: "extract the text", box: letter.offsetBy(dx: 60, dy: 28)),
            RawObservation(text: "JSON 3", box: letter.offsetBy(dx: 60, dy: 42)),
            RawObservation(text: "Good", box: letter),
            RawObservation(text: "ORD-4200", box: letter.offsetBy(dx: 0, dy: 50)),
            RawObservation(text: "12.50", box: letter.offsetBy(dx: 0, dy: 64)),
        ], sent: .image)
        let result = normalize(raw)
        #expect(result.segments.map(\.text) == ["Good morning", "世界", "JSON 3", "ORD-4200", "12.50"])
        #expect(result.segments.prefix(2).map(\.confidence) == [0.7, 0.8])
        #expect(result.segments.prefix(2).map(\.parent) == [result.blocks.first?.id, result.blocks.first?.id])
        #expect(result.excluded.map(\.reason) == [.noise, .lowConfidence, .promptLeakage, .duplicate])
        #expect(result.segments.suffix(2).map(\.translatability) == [.keepOriginal(.identifier), .keepOriginal(.numeric)])
    }

    @Test func overlappingTablesMergeRowIndicesAndDeduplicateSharedCells() throws {
        let firstTable = BlockID()
        let secondTable = BlockID()
        let frame = FrameRect(x: 0, y: 0, width: 100, height: 100)
        func cell(_ name: String, _ row: Int, y: Double, table: BlockID, block: Int) -> RawObservation {
            let box = FrameRect(x: 12, y: y, width: 25, height: 10)
            return RawObservation(text: name, box: box, quad: [CGPoint(x: box.minX, y: box.minY)],
                                  kind: .tableCell(TableCellRef(table: table, row: row, column: 0)), blockIndex: block, lines: [box])
        }
        let first = RawRecognition(
            observations: [cell("Header", 0, y: 10, table: firstTable, block: 1), cell("Shared", 1, y: 76, table: firstTable, block: 1)],
            blocks: [RawBlock(kind: .figure, box: frame), RawBlock(kind: .table(rows: 2, columns: 1), box: frame, parentIndex: 0)],
            languages: [.english], sent: .image
        )
        let second = RawRecognition(
            observations: [
                cell("Shared", 0, y: 6, table: secondTable, block: 0),
                cell("New", 1, y: 35, table: secondTable, block: 0),
                cell("Out of bounds", 511, y: 46, table: secondTable, block: 0),
            ], blocks: [RawBlock(kind: .table(rows: 2, columns: 1), box: frame)], languages: [.english, LanguageCode("fr")], sent: .image
        )
        let merged = ImageTiling.merge([(frame.raw, first), (frame.offsetBy(dx: 0, dy: 70).raw, second)])
        #expect(merged.blocks.count == 2)
        #expect(merged.blocks[1].kind == .table(rows: 3, columns: 1))
        #expect(merged.blocks[1].parentIndex == 0)
        #expect(merged.blocks[1].box.height == 170)
        #expect(merged.observations.map(\.text) == ["Header", "Shared", "New"])
        #expect(merged.observations.compactMap { $0.kind.tableCell?.row } == [0, 1, 2])
        let last = try #require(merged.observations.last)
        #expect(last.blockIndex == 1)
        #expect(last.quad?.first == CGPoint(x: 12, y: 105))
        #expect(last.lines?.first == FrameRect(x: 12, y: 105, width: 25, height: 10))
        #expect(merged.languages == [.english, LanguageCode("fr")])
    }
}

@Suite("Smart actions from recognized content")
struct SmartActionsWorkflowTests {
    @Test func exportsTableRevisionsFormulaCodeLinksAndQR() async throws {
        let fixture = DocumentWorkflowFixture()
        let box = DocumentRect(x: 2, y: 2, width: 25, height: 12)
        let table = BlockID()
        let header = TextSegment(kind: .tableCell(TableCellRef(table: table, row: 0, column: 0)), text: "Name", box: box, parent: table)
        let cell = TextSegment(
            kind: .tableCell(TableCellRef(table: table, row: 1, column: 0)), text: "Old", revisedText: "A, B\nC", box: box, parent: table)
        let formula = TextSegment(kind: .formula(latex: "x^2"), text: "x squared", box: box)
        let code = TextSegment(kind: .code(language: "swift"), text: "1: let x = 1\n2: print(x)", box: box)
        let links = TextSegment(text: "https://example.invalid/page; demo@example.invalid; https://example.invalid/page", box: box)
        var session = fixture.session()
        let segments = [header, cell, formula, code, links]
        session.analysis = AnalysisResult(
            session: session.id, inputRevision: 0, inputFingerprint: CacheKey.fingerprint(session.baseImage), region: session.imageBounds,
            segments: segments, blocks: [ContentBlock(id: table, kind: .table(rows: 2, columns: 1), box: box)],
            provenance: Provenance(engine: .visionDocument, configDigest: "fixture", locality: .onDevice, duration: .zero, sent: .nothing)
        )
        let id = await fixture.sessions.insert(session)
        let qr = try #require(URL(string: "https://example.invalid/qr"))
        let detector = FakeCodeDetector([
            DetectedCode(payload: qr.absoluteString, box: .zero), DetectedCode(payload: "plain text", box: .zero),
        ])
        let pipeline = fixture.pipeline(recognition: fixture.recognition([]), codes: detector)

        let actions = await pipeline.smartActions(for: id)
        #expect(actions.first { $0.kind == .copyTableAsMarkdown }?.payload == "| Name |\n| --- |\n| A, B C |")
        #expect(actions.first { $0.kind == .copyTableAsCSV }?.payload == "Name\n\"A, B C\"")
        #expect(actions.first { $0.kind == .copyFormulaAsLaTeX }?.payload == "x^2")
        #expect(actions.first { $0.kind == .copyCode }?.payload == "let x = 1\nprint(x)")
        #expect(actions.filter { if case .openLink = $0.kind { true } else { false } }.count == 1)
        #expect(actions.contains { $0.kind == .composeEmail("demo@example.invalid") })
        #expect(actions.filter { if case .openQRCode = $0.kind { true } else { false } }.map(\.kind) == [.openQRCode(qr)])
        #expect(detector.calls.count == 1)
        #expect(await pipeline.smartActions(for: SessionID()).isEmpty)
    }
}
