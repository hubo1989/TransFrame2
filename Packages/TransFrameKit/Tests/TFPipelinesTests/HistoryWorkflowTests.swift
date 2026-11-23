import Foundation
import Testing
import TFDomain
import TFDomainTestSupport
@testable import TFPipelines

@Suite("History retention, semantic search and export")
struct HistoryWorkflowTests {
    @Test func duplicateKeepsFavoriteAndPaginationRespectsFilters() async throws {
        let favorite = HistoryEntry(kind: .textTranslation, source: "Résumé", result: "CV", isFavorite: true)
        let original = InMemoryHistoryStore([favorite])
        let service = HistoryService(store: original, files: FakeFileExporter(), performance: FakePerformanceRecorder())
        var settings = SettingsSnapshot()
        settings.history.limit = 2
        let repeatEntry = HistoryEntry(kind: .textTranslation, source: "Résumé", result: "CV")
        let discarded = HistoryEntry(kind: .insertTranslation, source: "old", result: "ancien")
        let newest = HistoryEntry(kind: .textTranslation, source: "Latest", result: "Dernier")
        await service.record(repeatEntry, settings: settings)
        await service.record(discarded, settings: settings)
        await service.record(newest, settings: settings)

        let page = try await service.page(HistoryQuery(limit: 1))
        #expect(page.entries == [newest])
        #expect(page.totalCount == 2 && page.hasMore)
        let older = try await service.page(HistoryQuery(offset: 1, limit: 1))
        #expect(older.entries.first?.id == repeatEntry.id)
        #expect(older.entries.first?.isFavorite == true)
        #expect(!older.hasMore)
        let search = try await service.page(HistoryQuery(text: " resume ", favoritesOnly: true))
        #expect(search.entries.map(\.id) == [repeatEntry.id])
        try await service.setFavorite(repeatEntry.id, false)
        #expect(try await service.page(HistoryQuery(favoritesOnly: true)).entries.isEmpty)
        #expect(await service.notice() == nil)
    }

    @Test func semanticResultsMergeWithTextAndRespectThresholdKindAndFavorite() async throws {
        let text = HistoryEntry(kind: .textTranslation, source: "apple", result: "pomme", isFavorite: true)
        let neighbor = HistoryEntry(kind: .textTranslation, source: "pear", result: "poire", isFavorite: true)
        let weak = HistoryEntry(kind: .textTranslation, source: "table", result: "table", isFavorite: true)
        let unfavorited = HistoryEntry(kind: .textTranslation, source: "peach", result: "pêche")
        let color = HistoryEntry(kind: .color, source: "", result: "#FF0000", isFavorite: true)
        let index = FakeEmbeddingIndex(ranking: [(neighbor.id, 0.99), (text.id, 0.9), (unfavorited.id, 0.8), (color.id, 0.7), (weak.id, 0.25)])
        let embedding = FakeTextEmbedding(.success([[0.6, 0.8]]))
        let performance = FakePerformanceRecorder()
        let service = HistoryService(
            store: InMemoryHistoryStore([text, neighbor, weak, unfavorited, color]), files: FakeFileExporter(),
            embedding: embedding, index: index, performance: performance
        )
        let query = HistoryQuery(favoritesOnly: true)
        let page = try await service.search(semantic: "apple", query: query, limit: 5)
        #expect(page.entries == [text, neighbor])
        #expect(page.totalCount == 2 && !page.hasMore && !page.semanticFallback)
        let request = try #require(index.queries.calls.first)
        #expect(request.0 == [0.6, 0.8] && request.1 == 5)
        #expect(embedding.calls.calls.first?.0 == ["apple"])

        embedding.result.current = .success([[]])
        let fallback = try await service.search(semantic: "apple", query: query, limit: 5)
        #expect(fallback.semanticFallback && fallback.entries == [text])
        #expect(index.queries.count == 1)
        #expect(performance.samples(Budget.historySemantic).count == 2)
    }

    @Test func indexesTranslationsButNotColorsAndClearsTheConfiguredOwners() async throws {
        let embedding = FakeTextEmbedding(.success([[1, 0]]))
        let index = FakeEmbeddingIndex()
        let storage = InMemoryHistoryStore()
        let files = FakeFileExporter()
        let service = HistoryService(store: storage, files: files, embedding: embedding, index: index, performance: FakePerformanceRecorder())
        let entry = HistoryEntry(kind: .textTranslation, source: "Apple", result: "Pomme", from: .english, tags: ["fruit", "food"])
        let color = HistoryEntry(kind: .color, source: "", result: "#FF0000")
        await service.record(entry, settings: SettingsSnapshot())
        await service.record(color, settings: SettingsSnapshot())
        #expect(await index.vectors == [entry.id: [1, 0]])
        #expect(embedding.calls.calls.first?.0 == ["Apple\nPomme\nfruit food"])
        #expect(embedding.calls.calls.first?.1 == .english)
        try await service.clear(.kinds([.color]))
        #expect(try await service.page(.colors).entries.isEmpty)
        #expect(await index.clearCount == 0)
        let owning = HistoryService(store: storage, files: files, embedding: embedding, index: index, storeOwnsIndex: true,
                                    performance: FakePerformanceRecorder())
        try await owning.remove([entry.id])
        #expect(await index.removed.isEmpty)
        try await service.remove([entry.id])
        #expect(await index.removed == [entry.id])
        try await owning.clear(.all)
        #expect(await index.clearCount == 0)
        try await service.clear(.all)
        #expect(await index.clearCount == 1)
        #expect(try await service.page(HistoryQuery()).entries.isEmpty)
    }

    @Test func exportsMatchingRowsWithStableMetadataAndEscaping() async throws {
        let entry = HistoryEntry(
            kind: .textTranslation, createdAt: Date(timeIntervalSince1970: 0), source: "two, \"quoted\"\nlines", result: "résultat",
            from: .english, to: LanguageCode("fr"), engine: .mtran, thumbnail: Data([0, 1]), tags: ["fixture"], isFavorite: true
        )
        let ignored = HistoryEntry(kind: .color, createdAt: entry.createdAt, source: "", result: "#123456")
        let files = FakeFileExporter()
        let service = HistoryService(store: InMemoryHistoryStore([entry, ignored]), files: files, performance: FakePerformanceRecorder())
        let query = HistoryQuery()
        for (format, name) in [(HistoryExportFormat.json, "json"), (.csv, "csv"), (.markdown, "md")] {
            try await service.export(query, as: format, to: URL(fileURLWithPath: "/fixture/history.\(name)"))
        }
        #expect(files.written.calls.map { $0.1 } == ["json", "csv", "md"])
        let payloads = files.payloads.calls
        try #require(payloads.count == 3)
        let json = try #require(JSONSerialization.jsonObject(with: payloads[0]) as? [[String: Any]])
        #expect(json.count == 1)
        #expect(json.first?["source"] as? String == entry.source)
        #expect(json.first?["tags"] as? [String] == ["fixture"])
        #expect(json.first?["thumbnail"] == nil)
        let csv = try #require(String(bytes: payloads[1], encoding: .utf8))
        #expect(csv.hasSuffix("\"two, \"\"quoted\"\"\nlines\",résultat,1\r\n"))
        let markdown = try #require(String(bytes: payloads[2], encoding: .utf8))
        #expect(markdown.contains("en → fr\n\n> two, \"quoted\"\n> lines\n\nrésultat"))
        #expect(!markdown.contains("#123456"))
    }

    @Test func csvQuotesWindowsLineBreakEvenWithoutCommas() {
        let entry = HistoryEntry(kind: .textTranslation, source: "first\r\nsecond", result: "translation")
        let csv = HistoryExporter.render([entry], as: .csv)
        #expect(csv.contains(",\"first\r\nsecond\",translation,0\r\n"))
    }

    @Test func retentionDropsOldestFavoritesOnlyAfterOrdinaryEntries() {
        let newest = HistoryEntry(kind: .textTranslation, source: "Newest favorite", result: "A", isFavorite: true)
        let old = HistoryEntry(kind: .textTranslation, source: "Old favorite", result: "B", isFavorite: true)
        let ordinary = HistoryEntry(kind: .textTranslation, source: "Ordinary", result: "C")
        var entries = [newest, ordinary, old]
        HistoryRetention.trim(&entries, limit: 1)
        #expect(entries == [newest])
    }
}
