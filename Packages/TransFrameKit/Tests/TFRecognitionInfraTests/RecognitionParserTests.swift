import Foundation
import Testing
import TFDomain
@testable import TFRecognitionInfra

@Suite("Recognition parsers")
struct RecognitionParserTests {
    @Test func vlmJSONToPixels() {
        let raw = VLMResponseParser.parse(
            #"{"items":[{"text":"Hi","bbox":[100,200,300,250]},{"text":"A","bbox":[0,0,100,100],"kind":"table_cell","table":0,"row":1,"col":2}]}"#,
            width: 1000, height: 500)
        #expect(raw.observations.count == 2)
        #expect(raw.observations[0].box == FrameRect(x: 100, y: 100, width: 200, height: 25))
        #expect(raw.blocks.count == 1)
        #expect(raw.blocks[0].kind == .table(rows: 2, columns: 3))
    }

    @Test func vlmPlainTextFallback() {
        let raw = VLMResponseParser.parse("line one\nline two", width: 100, height: 100)
        #expect(raw.observations.map(\.text) == ["line one", "line two"])
    }

    @Test func paddleResult() {
        let raw = PaddleResultParser.parse(["rec_texts": ["a", "b"], "rec_scores": [0.9, 0.8], "rec_boxes": [[0, 0, 10, 5], [0, 10, 20, 15]]])
        #expect(raw.observations.map(\.text) == ["a", "b"])
        #expect(raw.observations[1].box == FrameRect(x: 0, y: 10, width: 20, height: 5))
        #expect(raw.observations[0].confidence == 0.9)
    }

    @Test func clusteringGroupsNearbyLines() {
        let clusters = TextClustering.cluster([
            CGRect(x: 0, y: 0, width: 100, height: 10), CGRect(x: 0, y: 14, width: 80, height: 10), CGRect(x: 0, y: 200, width: 50, height: 10),
        ])
        #expect(clusters.count == 2)
        #expect(clusters[0].count == 2)
    }
}

extension RecognitionParserTests {
    @Test func rejectsInvalidTableCoordinatesAndMalformedJSON() {
        let reply = #"{"items":[{"text":"bad","bbox":[0,0,100,100],"kind":"table_cell","row":-1,"col":0}]}"#
        #expect(VLMResponseParser.parse(reply, width: 100, height: 100).observations.isEmpty)
        #expect(VLMResponseParser.parse(#"{"items":[{"text":"cut"#, width: 100, height: 100).observations.isEmpty)
    }

    @Test func subprocessDrainsOutputAndTimesOut() async throws {
        let result = try await ProcessRunner.run(
            "/bin/sh", ["-c", "/bin/dd if=/dev/zero bs=65536 count=4 >&2; printf ready"], timeout: .seconds(3)
        )
        #expect(result.status == 0)
        #expect(result.stdout == "ready")
        await #expect(throws: AppError.engine(.timedOut(.paddleLocal))) {
            try await ProcessRunner.run("/bin/sleep", ["15"], timeout: .milliseconds(100))
        }
    }
}
