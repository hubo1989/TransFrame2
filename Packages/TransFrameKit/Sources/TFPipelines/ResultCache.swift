import CoreGraphics
import CryptoKit
import Foundation
import TFDomain

/// In-memory LRU result cache with count and byte limits and in-flight coalescing (ADR-0005).
public actor ResultCache<Value: Sendable> {
    private struct Entry {
        let value: Value
        let bytes: Int
        var tick: Int
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Value, any Error>] = [:]
    private var tick = 0
    private var totalBytes = 0
    private let maxCount: Int
    private let maxBytes: Int
    private let sizeOf: @Sendable (Value) -> Int

    public init(maxCount: Int, maxBytes: Int, sizeOf: @escaping @Sendable (Value) -> Int) {
        self.maxCount = maxCount
        self.maxBytes = maxBytes
        self.sizeOf = sizeOf
    }

    public var count: Int { entries.count }

    public func value(for key: String) -> Value? {
        guard var entry = entries[key] else { return nil }
        tick += 1
        entry.tick = tick
        entries[key] = entry
        return entry.value
    }

    public func store(_ value: Value, for key: String) {
        let bytes = sizeOf(value)
        if let old = entries[key] { totalBytes -= old.bytes }
        tick += 1
        entries[key] = Entry(value: value, bytes: bytes, tick: tick)
        totalBytes += bytes
        while entries.count > maxCount || totalBytes > maxBytes, let oldest = entries.min(by: { $0.value.tick < $1.value.tick }) {
            totalBytes -= oldest.value.bytes
            entries[oldest.key] = nil
        }
    }

    /// Same key in flight: later callers await the first request instead of sending again.
    /// `force` bypasses the read but still writes on success. Failures are not cached.
    public func value(for key: String, force: Bool, compute: @escaping @Sendable () async throws -> Value) async throws -> (Value, fromCache: Bool) {
        if !force, let cached = value(for: key) { return (cached, true) }
        if let running = inFlight[key] { return (try await running.value, false) }
        let task = Task { try await compute() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let value = try await task.value
        store(value, for: key)
        return (value, false)
    }

    public func removeAll() {
        entries.removeAll()
        totalBytes = 0
    }
}

public enum CacheKey {
    public static func digest(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\u{1f}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of the image's RGBA bytes (computed off the main actor).
    public static func fingerprint(_ image: PixelImage) -> ContentHash {
        let width = image.cgImage.width, height = image.cgImage.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return ContentHash(sha256: Data()) }
        context.draw(image.cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return ContentHash(sha256: Data()) }
        let digest = SHA256.hash(data: UnsafeRawBufferPointer(start: data, count: width * height * 4))
        return ContentHash(sha256: Data(digest))
    }
}
