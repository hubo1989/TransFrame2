import Foundation
import SwiftData
import TFDomain

/// SwiftData history (ADR-0009). Model objects never leave this file; only `HistoryEntry` values cross the boundary.
enum HistorySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [StoredEntry.self, StoredVector.self] }

    @Model
    final class StoredEntry {
        @Attribute(.unique) var id: UUID
        var kind: String
        var createdAt: Date
        var source: String
        var result: String
        var from: String?
        var to: String?
        var engine: String?
        @Attribute(.externalStorage) var thumbnail: Data?
        var tags: [String]
        var isFavorite: Bool
        var contentKey: String

        init(_ e: HistoryEntry) {
            id = e.id.raw
            kind = e.kind.rawValue
            createdAt = e.createdAt
            source = e.source
            result = e.result
            from = e.from?.bcp47
            to = e.to?.bcp47
            engine = e.engine?.raw
            thumbnail = e.thumbnail
            tags = e.tags
            isFavorite = e.isFavorite
            contentKey = e.contentKey
        }

        var value: HistoryEntry {
            HistoryEntry(
                id: HistoryEntryID(raw: id), kind: HistoryKind(rawValue: kind) ?? .textTranslation, createdAt: createdAt, source: source,
                result: result, from: from.map(LanguageCode.init), to: to.map(LanguageCode.init), engine: engine.map(EngineID.init),
                thumbnail: thumbnail, tags: tags, isFavorite: isFavorite
            )
        }
    }

    /// Embedding side table keyed by entry id (AI-05).
    @Model
    final class StoredVector {
        @Attribute(.unique) var entryID: UUID
        var vector: [Float]
        init(entryID: UUID, vector: [Float]) {
            self.entryID = entryID
            self.vector = vector
        }
    }
}

enum HistoryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [HistorySchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

/// History and embedding index over one SwiftData container. A store that cannot be opened is moved aside and recreated
/// with a notice instead of crashing (ADR-0009 §11).
@ModelActor
public actor SwiftDataHistoryStore: HistoryStoring, EmbeddingIndexStoring {
    private var movedAside: String?

    public static func open(directory: URL?) -> SwiftDataHistoryStore {
        let schema = Schema(versionedSchema: HistorySchemaV1.self)
        guard let directory else {
            let container = try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            return SwiftDataHistoryStore(modelContainer: container)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "History.store")
        do {
            let container = try ModelContainer(for: schema, migrationPlan: HistoryMigrationPlan.self, configurations: ModelConfiguration(url: url))
            return SwiftDataHistoryStore(modelContainer: container)
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = directory.appending(path: "History-unreadable-\(stamp).store")
            try? FileManager.default.moveItem(at: url, to: aside)
            for suffix in ["-shm", "-wal"] {
                try? FileManager.default.moveItem(at: URL(fileURLWithPath: url.path + suffix), to: URL(fileURLWithPath: aside.path + suffix))
            }
            let container = (try? ModelContainer(for: schema, configurations: ModelConfiguration(url: url)))
                ?? (try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
            let store = SwiftDataHistoryStore(modelContainer: container)
            Task { await store.setMovedAside(aside.path) }
            return store
        }
    }

    func setMovedAside(_ path: String) { movedAside = path }

    public func notice() async -> HistoryStoreNotice? { movedAside.map(HistoryStoreNotice.init) }

    private func fetchAll() throws(AppError) -> [HistorySchemaV1.StoredEntry] {
        do {
            return try modelContext.fetch(FetchDescriptor<HistorySchemaV1.StoredEntry>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        } catch {
            throw .persistence(.storeUnavailable)
        }
    }

    private func save() throws(AppError) {
        do { try modelContext.save() } catch { throw .persistence(.writeFailed) }
    }

    /// Identical content merges keeping the favorite flag (HIS-10); oldest unfavorited entries go first (ADR-0009 §5).
    public func add(_ entry: HistoryEntry, limit: Int) async throws(AppError) -> HistoryEntry {
        var entry = entry
        let key = entry.contentKey
        let duplicates = try modelContext.fetchSafe(FetchDescriptor<HistorySchemaV1.StoredEntry>(predicate: #Predicate { $0.contentKey == key }))
        for duplicate in duplicates {
            entry.isFavorite = entry.isFavorite || duplicate.isFavorite
            modelContext.delete(duplicate)
        }
        modelContext.insert(HistorySchemaV1.StoredEntry(entry))
        var all = try fetchAll().map(\.value)
        let before = Set(all.map(\.id))
        HistoryRetentionPolicy.trim(&all, limit: limit)
        let removed = before.subtracting(all.map(\.id))
        if !removed.isEmpty { try await remove(Array(removed)) }
        try save()
        return entry
    }

    public func page(_ query: HistoryQuery) async throws(AppError) -> HistoryPage {
        let matched = try fetchAll().lazy.map(\.value).filter(query.matches)
        let all = Array(matched)
        let slice = all.dropFirst(query.offset).prefix(query.limit)
        return HistoryPage(entries: Array(slice), totalCount: all.count, hasMore: query.offset + slice.count < all.count)
    }

    public func entries(ids: [HistoryEntryID]) async throws(AppError) -> [HistoryEntry] {
        let wanted = Set(ids.map(\.raw))
        let found = try fetchAll().filter { wanted.contains($0.id) }.map(\.value)
        return ids.compactMap { id in found.first { $0.id == id } }
    }

    public func all(matching query: HistoryQuery) async throws(AppError) -> [HistoryEntry] {
        try fetchAll().map(\.value).filter(query.matches)
    }

    public func setFavorite(_ id: HistoryEntryID, _ on: Bool) async throws(AppError) {
        let raw = id.raw
        for item in try modelContext.fetchSafe(FetchDescriptor<HistorySchemaV1.StoredEntry>(predicate: #Predicate { $0.id == raw })) { item.isFavorite = on }
        try save()
    }

    public func remove(_ ids: [HistoryEntryID]) async throws(AppError) {
        let wanted = Set(ids.map(\.raw))
        for item in try fetchAll() where wanted.contains(item.id) { modelContext.delete(item) }
        for vector in try modelContext.fetchSafe(FetchDescriptor<HistorySchemaV1.StoredVector>()) where wanted.contains(vector.entryID) {
            modelContext.delete(vector)
        }
        try save()
    }

    public func clear(_ scope: HistoryScope) async throws(AppError) {
        let items = try fetchAll()
        let doomed: [HistoryEntryID] = items.compactMap { item in
            switch scope {
            case .all: HistoryEntryID(raw: item.id)
            case .kinds(let kinds): kinds.contains(HistoryKind(rawValue: item.kind) ?? .textTranslation) ? HistoryEntryID(raw: item.id) : nil
            }
        }
        try await remove(doomed)
    }

    // MARK: EmbeddingIndexStoring

    public func upsert(_ id: HistoryEntryID, vector: [Float]) async throws(AppError) {
        let raw = id.raw
        for existing in try modelContext.fetchSafe(FetchDescriptor<HistorySchemaV1.StoredVector>(predicate: #Predicate { $0.entryID == raw })) {
            modelContext.delete(existing)
        }
        modelContext.insert(HistorySchemaV1.StoredVector(entryID: raw, vector: vector))
        try save()
    }

    public func removeAll() async throws(AppError) {
        for vector in try modelContext.fetchSafe(FetchDescriptor<HistorySchemaV1.StoredVector>()) { modelContext.delete(vector) }
        try save()
    }

    /// Cosine similarity, best first.
    public func nearest(to vector: [Float], limit: Int) async throws(AppError) -> [(HistoryEntryID, Double)] {
        let norm = sqrt(vector.reduce(0) { $0 + Double($1 * $1) })
        guard norm > 0 else { return [] }
        let scored = try modelContext.fetchSafe(FetchDescriptor<HistorySchemaV1.StoredVector>()).compactMap { stored -> (HistoryEntryID, Double)? in
            guard stored.vector.count == vector.count else { return nil }
            var dot = 0.0, other = 0.0
            for i in vector.indices {
                dot += Double(vector[i] * stored.vector[i])
                other += Double(stored.vector[i] * stored.vector[i])
            }
            return other > 0 ? (HistoryEntryID(raw: stored.entryID), dot / (norm * sqrt(other))) : nil
        }
        return Array(scored.sorted { $0.1 > $1.1 }.prefix(limit))
    }
}

extension ModelContext {
    func fetchSafe<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws(AppError) -> [T] {
        do { return try fetch(descriptor) } catch { throw .persistence(.storeUnavailable) }
    }
}

/// Same retention rule as the pipeline's in-memory store (duplicated to keep infra independent of pipelines).
enum HistoryRetentionPolicy {
    static func trim(_ entries: inout [HistoryEntry], limit: Int) {
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
