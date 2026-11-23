import CoreGraphics
import Foundation
import TFDomain

/// Scrolling capture (N-09): samples the rect, appends only newly scrolled rows found by overlap search, stops at 32 768 px.
public actor ScrollCaptureService: ScrollCaptureWorkflow {
    public static let maxHeight = 32_768
    private let capturer: any ScrollCapturing
    private let sessions: DocumentSessionStore
    private var loop: Task<Void, Never>?
    private var rows: [[UInt64]] = []
    private var strips: [CGImage] = []
    private var offsets: [Int] = []
    private var height = 0
    private var scale = 1.0
    private var width = 0

    public init(capturer: any ScrollCapturing, sessions: DocumentSessionStore) {
        self.capturer = capturer
        self.sessions = sessions
    }

    public func begin(_ rect: QuartzRect, excluding: Set<WindowID>) async throws(AppError) -> AsyncStream<ScrollCaptureEvent> {
        reset()
        let first = try await capturer.captureStrip(rect, excluding: excluding)
        append(first.cgImage, at: 0)
        scale = first.scale
        width = first.cgImage.width
        let (stream, continuation) = AsyncStream<ScrollCaptureEvent>.makeStream()
        continuation.yield(.progress(height: height))
        loop = Task { [capturer] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard let strip = try? await capturer.captureStrip(rect, excluding: excluding) else { continue }
                if self.ingest(strip.cgImage) { continuation.yield(.progress(height: self.height)) }
                if self.height >= Self.maxHeight {
                    continuation.yield(.reachedLimit)
                    break
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { [weak self] _ in Task { await self?.stopLoop() } }
        return stream
    }

    private func stopLoop() {
        loop?.cancel()
        loop = nil
    }

    /// Finds how far the new strip scrolled relative to the last one by matching row hashes; appends new rows only.
    func ingest(_ strip: CGImage) -> Bool {
        guard strip.width == width, let last = rows.last else { return false }
        let hashes = Self.rowHashes(strip)
        guard hashes != last else { return false }
        guard let shift = Self.scrollShift(previous: last, current: hashes), shift > 0 else { return false }
        let newRows = min(shift, Self.maxHeight - height)
        guard newRows > 0, let crop = strip.cropping(to: CGRect(x: 0, y: strip.height - newRows, width: strip.width, height: newRows)) else { return false }
        append(crop, at: height)
        rows[rows.count - 1] = hashes
        return true
    }

    private func append(_ image: CGImage, at offset: Int) {
        strips.append(image)
        offsets.append(offset)
        height = offset + image.height
        if rows.isEmpty { rows.append(Self.rowHashes(image)) }
    }

    /// Smallest shift s where the previous strip's rows [s...] equal the current strip's rows [0..<n-s] (≥ 85 % match).
    public static func scrollShift(previous: [UInt64], current: [UInt64]) -> Int? {
        let n = min(previous.count, current.count)
        guard n > 8 else { return nil }
        let minOverlap = max(n / 5, 8)
        for shift in 1...(n - minOverlap) {
            let overlap = n - shift
            var matches = 0
            for i in stride(from: 0, to: overlap, by: max(overlap / 64, 1)) where previous[i + shift] == current[i] { matches += 1 }
            let samples = (overlap + max(overlap / 64, 1) - 1) / max(overlap / 64, 1)
            if Double(matches) >= Double(samples) * 0.85 { return shift }
        }
        return nil
    }

    static func rowHashes(_ image: CGImage) -> [UInt64] {
        let w = image.width, h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let _ = { context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true }(),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        // Memory rows are top-down for a CGContext bitmap.
        return (0..<h).map { row in
            var hash: UInt64 = 1_469_598_103_934_665_603
            let base = row * w * 4
            for x in stride(from: 0, to: w * 4, by: 16) {
                hash = (hash ^ UInt64(data[base + x] >> 3)) &* 1_099_511_628_211
                hash = (hash ^ UInt64(data[base + x + 1] >> 3)) &* 1_099_511_628_211
            }
            return hash
        }
    }

    public func finish() async throws(AppError) -> SessionID {
        stopLoop()
        guard !strips.isEmpty, width > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw .capture(.timedOut) }
        for (strip, offset) in zip(strips, offsets) {
            context.draw(strip, in: CGRect(x: 0, y: height - offset - strip.height, width: strip.width, height: strip.height))
        }
        guard let image = context.makeImage() else { throw .render(.contextUnavailable) }
        reset()
        return await sessions.create(importing: PixelImage(cgImage: image, scale: scale), name: "Scrolling Capture")
    }

    public func cancel() async {
        stopLoop()
        reset()
    }

    private func reset() {
        rows = []
        strips = []
        offsets = []
        height = 0
    }
}
