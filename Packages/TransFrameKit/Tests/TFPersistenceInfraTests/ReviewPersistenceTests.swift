import Foundation
import Testing
import TFDomain
@testable import TFPersistenceInfra

@Suite("Review persistence regressions")
struct ReviewPersistenceTests {
    @Test func deduplicationAndLateIndexingCannotLeaveSearchableOrphans() async throws {
        let store = try SwiftDataHistoryStore.open(directory: nil)
        let first = try await store.add(HistoryEntry(kind: .textTranslation, source: "a", result: "b"), limit: 5)
        try await store.upsert(first.id, vector: [1, 0])
        let next = try await store.add(HistoryEntry(kind: .textTranslation, source: "a", result: "b"), limit: 5)
        try await store.upsert(first.id, vector: [1, 0])
        try await store.upsert(next.id, vector: [0, 1])
        let results = try await store.nearest(to: [1, 0], limit: 5)
        #expect(results.map(\.0) == [next.id])
    }

    @Test func glossarySeparatesSourceLanguageAndCasePolicy() async throws {
        let store = GlossaryFileStore(url: nil)
        try await store.upsert(GlossaryEntry(source: "chat", target: "one", from: .english, to: .simplifiedChinese))
        try await store.upsert(GlossaryEntry(source: "chat", target: "two", from: LanguageCode("fr"), to: .simplifiedChinese))
        try await store.upsert(GlossaryEntry(source: "Chat", target: "three", from: .english, to: .simplifiedChinese, caseSensitive: true))
        #expect(try await store.entries().count == 3)
    }
}
