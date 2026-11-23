import Foundation
import os
import TFDomain

/// History orchestration (ADR-0009): writes after successful operations, semantic search with text fallback (AI-05),
/// and export to JSON / CSV / Markdown (N-06).
public struct HistoryService: HistoryWorkflow {
    private let store: any HistoryStoring
    private let files: any FileExporting
    private let embedding: (any TextEmbedding)?
    private let index: (any EmbeddingIndexStoring)?
    private let performance: any PerformanceRecording

    public init(
        store: any HistoryStoring, files: any FileExporting, embedding: (any TextEmbedding)? = nil,
        index: (any EmbeddingIndexStoring)? = nil, performance: any PerformanceRecording
    ) {
        self.store = store
        self.files = files
        self.embedding = embedding
        self.index = index
        self.performance = performance
    }

    public func page(_ query: HistoryQuery) async throws(AppError) -> HistoryPage {
        let start = ContinuousClock.now
        let page = try await store.page(query)
        performance.record(PerformanceSample(budget: query.text.isEmpty ? Budget.historyFirstPage : Budget.historySearch, duration: .now - start))
        return page
    }

    /// Vector search merged with text matches; falls back to text search when embeddings are unavailable.
    public func search(semantic text: String, query: HistoryQuery, limit: Int) async throws(AppError) -> HistoryPage {
        let start = ContinuousClock.now
        defer { performance.record(PerformanceSample(budget: Budget.historySemantic, duration: .now - start)) }
        guard let embedding, let index, !text.trimmingCharacters(in: .whitespaces).isEmpty,
              let vector = try? await embedding.embed([text], language: nil).first, !vector.isEmpty else {
            var textQuery = query
            textQuery.text = text
            let page = try await store.page(textQuery)
            return HistoryPage(entries: page.entries, totalCount: page.totalCount, hasMore: page.hasMore, semanticFallback: true)
        }
        let nearest = try await index.nearest(to: vector, limit: limit)
        var textQuery = query
        textQuery.text = text
        textQuery.limit = limit
        let textMatches = try await store.page(textQuery).entries
        let semantic = try await store.entries(ids: nearest.filter { $0.1 > 0.25 }.map(\.0)).filter {
            query.kinds.contains($0.kind) && (!query.favoritesOnly || $0.isFavorite)
        }
        var seen = Set<HistoryEntryID>()
        let merged = (textMatches + semantic).filter { seen.insert($0.id).inserted }
        return HistoryPage(entries: Array(merged.prefix(limit)), totalCount: merged.count, hasMore: false)
    }

    public func setFavorite(_ id: HistoryEntryID, _ on: Bool) async throws(AppError) { try await store.setFavorite(id, on) }

    public func remove(_ ids: [HistoryEntryID]) async throws(AppError) {
        try await store.remove(ids)
        try? await index?.remove(ids)
    }

    public func clear(_ scope: HistoryScope) async throws(AppError) {
        try await store.clear(scope)
        if case .all = scope { try? await index?.removeAll() }
    }

    public func export(_ query: HistoryQuery, as format: HistoryExportFormat, to url: URL) async throws(AppError) {
        let entries = try await store.all(matching: query)
        try await files.write(Data(HistoryExporter.render(entries, as: format).utf8), to: url)
    }

    /// Records an entry and, when semantic search is on, indexes it with the on-device embedding (AI-05).
    public func record(_ entry: HistoryEntry, settings: SettingsSnapshot) async {
        guard let stored = try? await store.add(entry, limit: settings.history.limit) else { return }
        guard settings.ai.semanticSearch, entry.kind != .color, let embedding, let index else { return }
        let text = [entry.source, entry.result, entry.tags.joined(separator: " ")].joined(separator: "\n")
        if let vector = try? await embedding.embed([text], language: entry.from).first, !vector.isEmpty {
            try? await index.upsert(stored.id, vector: vector)
        }
    }

    public func notice() async -> HistoryStoreNotice? { await store.notice() }
}

/// Pure exporters (N-06). JSON carries every field except the thumbnail.
public enum HistoryExporter {
    private struct Row: Encodable {
        let id: String, kind: String, createdAt: Date, source: String, result: String
        let from: String?, to: String?, engine: String?, tags: [String], isFavorite: Bool
    }

    public static func render(_ entries: [HistoryEntry], as format: HistoryExportFormat) -> String {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let rows = entries.map {
                Row(id: $0.id.description, kind: $0.kind.rawValue, createdAt: $0.createdAt, source: $0.source, result: $0.result,
                    from: $0.from?.bcp47, to: $0.to?.bcp47, engine: $0.engine?.raw, tags: $0.tags, isFavorite: $0.isFavorite)
            }
            return (try? encoder.encode(rows)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        case .csv:
            let header = "createdAt,kind,from,to,engine,source,result,favorite"
            let iso = ISO8601DateFormatter()
            let lines = entries.map { e in
                [iso.string(from: e.createdAt), e.kind.rawValue, e.from?.bcp47 ?? "", e.to?.bcp47 ?? "", e.engine?.raw ?? "", e.source, e.result, e.isFavorite ? "1" : "0"]
                    .map(csvField).joined(separator: ",")
            }
            return ([header] + lines).joined(separator: "\r\n") + "\r\n"
        case .markdown:
            let iso = ISO8601DateFormatter()
            return entries.map { e in
                var block = "## \(iso.string(from: e.createdAt)) · \(e.kind.rawValue)"
                if let from = e.from, let to = e.to { block += " · \(from.bcp47) → \(to.bcp47)" }
                if !e.source.isEmpty { block += "\n\n" + e.source.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n") }
                block += "\n\n" + e.result
                return block
            }.joined(separator: "\n\n---\n\n") + "\n"
        }
    }

    static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Process-local store used until a persistent store is available and by tests.
public actor InMemoryHistoryStore: HistoryStoring {
    private var entries: [HistoryEntry] = []
    public init(_ entries: [HistoryEntry] = []) { self.entries = entries }

    /// Merge identical content keeping favorites (HIS-10); evict oldest non-favorites first (ADR-0009 §5).
    public func add(_ entry: HistoryEntry, limit: Int) async throws(AppError) -> HistoryEntry {
        var entry = entry
        if let index = entries.firstIndex(where: { $0.contentKey == entry.contentKey }) {
            entry.isFavorite = entry.isFavorite || entries[index].isFavorite
            entries.remove(at: index)
        }
        entries.insert(entry, at: 0)
        HistoryRetention.trim(&entries, limit: limit)
        return entry
    }

    public func page(_ query: HistoryQuery) async throws(AppError) -> HistoryPage {
        let matched = entries.filter(query.matches)
        let slice = matched.dropFirst(query.offset).prefix(query.limit)
        return HistoryPage(entries: Array(slice), totalCount: matched.count, hasMore: query.offset + slice.count < matched.count)
    }

    public func entries(ids: [HistoryEntryID]) async throws(AppError) -> [HistoryEntry] {
        ids.compactMap { id in entries.first { $0.id == id } }
    }

    public func all(matching query: HistoryQuery) async throws(AppError) -> [HistoryEntry] { entries.filter(query.matches) }

    public func setFavorite(_ id: HistoryEntryID, _ on: Bool) async throws(AppError) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isFavorite = on
    }

    public func remove(_ ids: [HistoryEntryID]) async throws(AppError) {
        let set = Set(ids)
        entries.removeAll { set.contains($0.id) }
    }

    public func clear(_ scope: HistoryScope) async throws(AppError) {
        switch scope {
        case .all: entries.removeAll()
        case .kinds(let kinds): entries.removeAll { kinds.contains($0.kind) }
        }
    }

    public func notice() async -> HistoryStoreNotice? { nil }
}

public enum HistoryRetention {
    /// Newest first. Removes the oldest unfavorited entries until within the limit, then the oldest favorites.
    public static func trim(_ entries: inout [HistoryEntry], limit: Int) {
        guard limit > 0, entries.count > limit else { return }
        var overflow = entries.count - limit
        for index in entries.indices.reversed() where overflow > 0 && !entries[index].isFavorite {
            entries.remove(at: index)
            overflow -= 1
        }
        while overflow > 0, !entries.isEmpty {
            entries.removeLast()
            overflow -= 1
        }
    }
}
