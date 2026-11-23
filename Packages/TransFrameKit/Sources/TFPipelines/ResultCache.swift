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
    private struct Flight {
        let task: Task<Void, Never>
        var subscribers: [UUID: CheckedContinuation<Value, any Error>]
    }

    private var latest: [String: UUID] = [:]
    private var flights: [UUID: Flight] = [:]
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
    public var isEmpty: Bool { entries.isEmpty }

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
        try Task.checkCancellation()
        if !force, let cached = value(for: key) { return (cached, true) }
        let subscriber = UUID()
        let generation = (!force ? latest[key] : nil) ?? UUID()
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if flights[generation] != nil {
                    flights[generation]?.subscribers[subscriber] = continuation
                } else {
                    latest[key] = generation
                    let task = Task {
                        let result: Result<Value, any Error>
                        do { result = .success(try await compute()) } catch { result = .failure(error) }
                        complete(result, key: key, generation: generation)
                    }
                    flights[generation] = Flight(task: task, subscribers: [subscriber: continuation])
                }
            }
        } onCancel: {
            Task { await self.unsubscribe(subscriber, key: key, generation: generation) }
        }
        try Task.checkCancellation()
        return (value, false)
    }

    private func unsubscribe(_ id: UUID, key: String, generation: UUID) {
        guard var flight = flights[generation], let waiter = flight.subscribers.removeValue(forKey: id) else { return }
        if flight.subscribers.isEmpty {
            flights[generation] = nil
            if latest[key] == generation { latest[key] = nil }
            flight.task.cancel()
        } else {
            flights[generation] = flight
        }
        waiter.resume(throwing: CancellationError())
    }

    private func complete(_ result: Result<Value, any Error>, key: String, generation: UUID) {
        guard let flight = flights.removeValue(forKey: generation) else { return }
        if latest[key] == generation {
            latest[key] = nil
            if case .success(let value) = result { store(value, for: key) }
        }
        for waiter in flight.subscribers.values { waiter.resume(with: result) }
    }

    public func removeAll() {
        entries.removeAll()
        latest.removeAll()
        totalBytes = 0
    }
}

public enum CacheKey {
    public static func digest(_ parts: [String]) -> String {
        var digest = SHA256()
        for part in parts {
            digest.update(data: Data("\(part.utf8.count):".utf8))
            digest.update(data: Data(part.utf8))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
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
        var digest = SHA256()
        digest.update(data: Data("\(width)x\(height):".utf8))
        digest.update(bufferPointer: UnsafeRawBufferPointer(start: data, count: width * height * 4))
        return ContentHash(sha256: Data(digest.finalize()))
    }
}
