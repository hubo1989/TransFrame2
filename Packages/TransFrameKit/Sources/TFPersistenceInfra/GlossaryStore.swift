import Foundation
import TFDomain

/// Glossary persisted as a JSON file in the support directory; the version increments on every change (AI-04).
public actor GlossaryFileStore: GlossaryStoring {
    private let url: URL?
    private var items: [GlossaryEntry] = []
    private var revision = 0

    public init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            items = decoded.entries
            revision = decoded.version
        }
    }

    private struct Stored: Codable {
        var version: Int
        var entries: [GlossaryEntry]
    }

    public func entries() async throws(AppError) -> [GlossaryEntry] { items }
    public func version() async -> Int { revision }

    public func upsert(_ entry: GlossaryEntry) async throws(AppError) {
        let updated = items.filter { item in
            guard item.id != entry.id else { return false }
            guard item.from == entry.from, item.to == entry.to, item.scope == entry.scope, item.caseSensitive == entry.caseSensitive else {
                return true
            }
            return entry.caseSensitive ? item.source != entry.source : item.source.caseInsensitiveCompare(entry.source) != .orderedSame
        }
        try persist(updated + [entry])
    }

    public func remove(_ id: GlossaryEntryID) async throws(AppError) {
        try persist(items.filter { $0.id != id })
    }

    private func persist(_ updated: [GlossaryEntry]) throws(AppError) {
        let next = revision + 1
        if let url {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(Stored(version: next, entries: updated)).write(to: url, options: .atomic)
            } catch {
                throw .persistence(.writeFailed)
            }
        }
        items = updated
        revision = next
    }
}
