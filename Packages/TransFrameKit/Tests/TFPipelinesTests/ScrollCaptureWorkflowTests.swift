import CoreGraphics
import Testing
import TFDomain
import TFDomainTestSupport
@testable import TFPipelines

private struct ScriptedStrips: ScrollCapturing {
    let requests = CallLog<(QuartzRect, Set<WindowID>)>()
    let sequence: Locked<[Result<PixelImage, AppError>]>

    init(_ sequence: [Result<PixelImage, AppError>]) { self.sequence = Locked(sequence) }

    func captureStrip(_ rect: QuartzRect, excluding: Set<WindowID>) async throws(AppError) -> PixelImage {
        requests.append((rect, excluding))
        let next = sequence.mutate { $0.isEmpty ? .failure(.capture(.timedOut)) : $0.removeFirst() }
        return try next.get()
    }
}

@Suite("Scrolling capture")
struct ScrollCaptureWorkflowTests {
    private let rect = QuartzRect(x: -10, y: 20, width: 4, height: 12)
    private let sessions = DocumentSessionStore(composer: FakeFrameComposer())

    private func strip(_ rows: Range<Int>, width: Int = 8) throws -> PixelImage {
        let context = try #require(TestImages.context(width: width, height: rows.count))
        for (index, row) in rows.enumerated() {
            context.setFillColor(red: Double(row * 8) / 255, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: rows.count - 1 - index, width: width, height: 1))
        }
        return PixelImage(cgImage: try #require(context.makeImage()), scale: 2)
    }

    @Test(.timeLimit(.minutes(1))) func skipsDuplicatesMismatchesAndFailedSamplesThenStitchesNewRows() async throws {
        let first = try strip(0..<24)
        let second = try strip(6..<30)
        let mismatch = try strip(0..<24, width: 12)
        let unrelated = TestImages.solid(width: 8, height: 24, color: .white, scale: 2)
        let strips = ScriptedStrips([
            .success(first), .success(first), .success(mismatch), .failure(.capture(.timedOut)), .success(unrelated), .success(second),
        ])
        let service = ScrollCaptureService(capturer: strips, sessions: sessions)
        let stream = try await service.begin(rect, excluding: [WindowID(4)])
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .progress(height: 24))
        #expect(await iterator.next() == .progress(height: 30))
        let id = try await service.finish()
        #expect(await iterator.next() == nil)
        let output = try await sessions.snapshot(of: id).baseImage
        #expect(output.pixelSize == PixelSize(width: 8, height: 30) && output.scale == 2)
        #expect(TestImages.bytes(output) == TestImages.bytes(try strip(0..<30)))
        #expect(strips.requests.calls.count == 6)
        #expect(strips.requests.calls.allSatisfy { $0.0 == rect && $0.1 == [WindowID(4)] })
        await #expect(throws: AppError.capture(.timedOut)) { _ = try await service.finish() }
    }

    @Test func oversizedFirstStripIsClippedAndSignalsLimit() async throws {
        let height = ScrollCaptureService.maxHeight
        let strips = ScriptedStrips([.success(TestImages.solid(width: 4, height: height + 11))])
        let service = ScrollCaptureService(capturer: strips, sessions: sessions)
        let stream = try await service.begin(rect, excluding: [])
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .progress(height: height))
        #expect(await iterator.next() == .reachedLimit)
        #expect(await iterator.next() == nil)
        let id = try await service.finish()
        #expect(try await sessions.snapshot(of: id).baseImage.pixelSize == PixelSize(width: 4, height: height))
        #expect(strips.requests.count == 1)
    }

    @Test func initialFailureAndExplicitCancellationDoNotCreateSessions() async throws {
        let strips = ScriptedStrips([.failure(.capture(.timedOut)), .success(try strip(0..<24))])
        let service = ScrollCaptureService(capturer: strips, sessions: sessions)
        await #expect(throws: AppError.capture(.timedOut)) { _ = try await service.begin(rect, excluding: []) }
        let stream = try await service.begin(rect, excluding: [])
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .progress(height: 24))
        await service.cancel()
        #expect(await iterator.next() == nil)
        await #expect(throws: AppError.capture(.timedOut)) { _ = try await service.finish() }
        #expect(await sessions.sessionCount == 0)
    }
}
