import Foundation

/// Performance sampling for `Scripts/perf.sh` (SPEC §04 §5). Writes raw millisecond samples to `$TF_PERF_OUT/<metric>.json`
/// when that variable is set; otherwise runs a short smoke so the suite stays fast in normal test runs.
public enum PerfProbe {
    public static var enabled: Bool { ProcessInfo.processInfo.environment["TF_PERF_OUT"] != nil }

    @discardableResult
    public static func measure(_ metric: String, warmup: Int = 5, samples: Int = 60, _ body: () async throws -> Void) async rethrows -> [Double] {
        let count = enabled ? samples : 3
        for _ in 0..<(enabled ? warmup : 1) { try await body() }
        var results: [Double] = []
        results.reserveCapacity(count)
        for _ in 0..<count {
            let start = ContinuousClock.now
            try await body()
            let d = ContinuousClock.now - start
            results.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
        if let directory = ProcessInfo.processInfo.environment["TF_PERF_OUT"] {
            let url = URL(fileURLWithPath: directory).appending(path: "\(metric).json")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: results).write(to: url)
        }
        return results
    }

    /// Nearest-rank percentile (SPEC §04 §5.3).
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = max(Int((p / 100 * Double(sorted.count)).rounded(.up)), 1)
        return sorted[min(rank, sorted.count) - 1]
    }
}
