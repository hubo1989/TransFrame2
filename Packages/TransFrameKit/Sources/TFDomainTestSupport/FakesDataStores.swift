import TFDomain

public actor FakeGlossaryStore: GlossaryStoring {
    private var values: [GlossaryEntry]
    private var revision = 0

    public init(_ entries: [GlossaryEntry] = []) { values = entries }

    public func entries() async throws(AppError) -> [GlossaryEntry] { values }
    public func version() async -> Int { revision }

    public func upsert(_ entry: GlossaryEntry) async throws(AppError) {
        values.removeAll { $0.id == entry.id }
        values.append(entry)
        revision += 1
    }

    public func remove(_ id: GlossaryEntryID) async throws(AppError) {
        values.removeAll { $0.id == id }
        revision += 1
    }
}

public struct FakeTextEmbedding: TextEmbedding {
    public let descriptor = EngineDescriptor(id: .nlEmbedding, roles: [.embedding], name: .userDefined("Fake"), locality: .onDevice)
    public let dimension = 2
    public let calls = CallLog<([String], LanguageCode?)>()
    public let result: Locked<Result<[[Float]], AppError>>

    public init(_ result: Result<[[Float]], AppError>) { self.result = Locked(result) }

    public func embed(_ texts: [String], language: LanguageCode?) async throws(AppError) -> [[Float]] {
        calls.append((texts, language))
        return try result.current.get()
    }
}

public actor FakeEmbeddingIndex: EmbeddingIndexStoring {
    public nonisolated let queries = CallLog<([Float], Int)>()
    public private(set) var vectors: [HistoryEntryID: [Float]] = [:]
    public private(set) var removed: [HistoryEntryID] = []
    public private(set) var clearCount = 0
    private let ranking: [(HistoryEntryID, Double)]

    public init(ranking: [(HistoryEntryID, Double)] = []) { self.ranking = ranking }

    public func upsert(_ id: HistoryEntryID, vector: [Float]) async throws(AppError) { vectors[id] = vector }

    public func remove(_ ids: [HistoryEntryID]) async throws(AppError) {
        removed.append(contentsOf: ids)
        for id in ids { vectors[id] = nil }
    }

    public func removeAll() async throws(AppError) {
        clearCount += 1
        vectors.removeAll()
    }

    public func nearest(to vector: [Float], limit: Int) async throws(AppError) -> [(HistoryEntryID, Double)] {
        queries.append((vector, limit))
        return Array(ranking.prefix(limit))
    }
}
