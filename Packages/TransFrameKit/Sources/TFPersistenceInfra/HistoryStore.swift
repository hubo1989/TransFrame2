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

    private init(container: ModelContainer, movedAside: String? = nil) {
        modelContainer = container
        modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(container))
        self.movedAside = movedAside
    }

    public static func open(directory: URL?) throws(AppError) -> SwiftDataHistoryStore {
        let schema = Schema(versionedSchema: HistorySchemaV1.self)
        do {
            guard let directory else { return try inMemoryStore(schema) }
            let files = FileManager.default
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: "History.store")
            do {
                let container = try ModelContainer(for: schema, migrationPlan: HistoryMigrationPlan.self, configurations: ModelConfiguration(url: url))
                return SwiftDataHistoryStore(container: container)
            } catch {
                guard files.fileExists(atPath: url.path) else { throw error }
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let aside = directory.appending(path: "History-unreadable-\(stamp)-\(UUID().uuidString)")
                try moveStore(url: url, aside: aside, files: files)
                if let container = try? ModelContainer(
                    for: schema, migrationPlan: HistoryMigrationPlan.self, configurations: ModelConfiguration(url: url)
                ) {
                    return SwiftDataHistoryStore(container: container, movedAside: aside.path)
                }
                return try inMemoryStore(schema, movedAside: aside.path)
            }
        } catch {
            throw .persistence(.storeUnavailable)
        }
    }

    private static func inMemoryStore(_ schema: Schema, movedAside: String? = nil) throws -> SwiftDataHistoryStore {
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return SwiftDataHistoryStore(container: container, movedAside: movedAside)
    }

    private static func moveStore(url: URL, aside: URL, files: FileManager) throws {
        try files.createDirectory(at: aside, withIntermediateDirectories: false)
        var moved: [(URL, URL)] = []
        do {
            for suffix in ["", "-shm", "-wal"] {
                let original = URL(fileURLWithPath: url.path + suffix)
                guard files.fileExists(atPath: original.path) else { continue }
                let target = aside.appending(path: original.lastPathComponent)
                try files.moveItem(at: original, to: target)
                moved.append((original, target))
            }
        } catch {
            for (original, target) in moved.reversed() { try files.moveItem(at: target, to: original) }
            throw error
        }
    }

    public func notice() async -> HistoryStoreNotice? { movedAside.map(HistoryStoreNotice.init) }

    private func fetchAll() throws(AppError) -> [HistorySchemaV1.StoredEntry] {
        do {
            return try modelContext.fetch(FetchDescriptor<HistorySchemaV1.StoredEntry>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        } catch {
            throw .persistence(.storeUnavailable)
        }
    }

    private func transaction<T>(_ updates: () throws -> T) throws(AppError) -> T {
        do {
            let value = try updates()
            try modelContext.save()
            return value
        } catch {
            modelContext.rollback()
            throw error as? AppError ?? .persistence(.writeFailed)
        }
    }

    /// Identical content merges keeping the favorite flag (HIS-10); oldest unfavorited entries go first (ADR-0009 §5).
    public func add(_ entry: HistoryEntry, limit: Int) async throws(AppError) -> HistoryEntry {
        try transaction {
            var entry = entry
            let originals = try fetchAll()
            let key = entry.contentKey
            let duplicates = originals.filter { $0.contentKey == key }
            entry.isFavorite = entry.isFavorite || duplicates.contains(where: \.isFavorite)
            let duplicateIDs = Set(duplicates.map(\.id))
            var retained = [entry] + originals.filter { !duplicateIDs.contains($0.id) }.map(\.value)
            HistoryRetentionPolicy.trim(&retained, limit: limit)
            let keep = Set(retained.map { $0.id.raw })
            try delete(originals.filter { duplicateIDs.contains($0.id) || !keep.contains($0.id) })
            if keep.contains(entry.id.raw) { modelContext.insert(HistorySchemaV1.StoredEntry(entry)) }
            return entry
        }
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
        try transaction {
            let raw = id.raw
            for item in try modelContext.fetchSafe(FetchDescriptor<HistorySchemaV1.StoredEntry>(predicate: #Predicate { $0.id == raw })) {
                item.isFavorite = on
            }
        }
    }

    private func delete(_ entries: [HistorySchemaV1.StoredEntry]) throws(AppError) {
        guard !entries.isEmpty else { return }
        let wanted = Set(entries.map(\.id))
        let vectors = try modelContext.fetchSafe(FetchDescriptor<HistorySchemaV1.StoredVector>())
        for item in entries { modelContext.delete(item) }
        for vector in vectors where wanted.contains(vector.entryID) { modelContext.delete(vector) }
    }

    public func remove(_ ids: [HistoryEntryID]) async throws(AppError) {
        let wanted = Set(ids.map(\.raw))
        try transaction { try delete(fetchAll().filter { wanted.contains($0.id) }) }
    }

    public func clear(_ scope: HistoryScope) async throws(AppError) {
        try transaction {
            let doomed = try fetchAll().filter { item in
                switch scope {
                case .all: true
                case .kinds(let kinds): kinds.contains(HistoryKind(rawValue: item.kind) ?? .textTranslation)
                }
            }
            try delete(doomed)
        }
    }

    // MARK: EmbeddingIndexStoring

    public func upsert(_ id: HistoryEntryID, vector: [Float]) async throws(AppError) {
        try transaction {
            let raw = id.raw
            let entries = FetchDescriptor<HistorySchemaV1.StoredEntry>(predicate: #Predicate { $0.id == raw })
            guard !(try modelContext.fetchSafe(entries)).isEmpty else { return }
            let matches = FetchDescriptor<HistorySchemaV1.StoredVector>(predicate: #Predicate { $0.entryID == raw })
            if let existing = try modelContext.fetchSafe(matches).first {
                existing.vector = vector
            } else {
                modelContext.insert(HistorySchemaV1.StoredVector(entryID: raw, vector: vector))
            }
        }
    }

    public func removeAll() async throws(AppError) {
        try transaction {
            for vector in try modelContext.fetchSafe(FetchDescriptor<HistorySchemaV1.StoredVector>()) { modelContext.delete(vector) }
        }
    }

    /// Cosine similarity, best first.
    public func nearest(to vector: [Float], limit: Int) async throws(AppError) -> [(HistoryEntryID, Double)] {
        let norm = sqrt(vector.reduce(0) { $0 + Double($1 * $1) })
        guard norm > 0 else { return [] }
        let validIDs = Set(try fetchAll().map(\.id))
        let scored = try modelContext.fetchSafe(FetchDescriptor<HistorySchemaV1.StoredVector>()).compactMap { stored -> (HistoryEntryID, Double)? in
            guard validIDs.contains(stored.entryID), stored.vector.count == vector.count else { return nil }
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
