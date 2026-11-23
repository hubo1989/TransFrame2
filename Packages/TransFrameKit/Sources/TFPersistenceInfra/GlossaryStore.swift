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
        items.removeAll { $0.id == entry.id || ($0.source.caseInsensitiveCompare(entry.source) == .orderedSame && $0.to == entry.to && $0.scope == entry.scope) }
        items.append(entry)
        try persist()
    }

    public func remove(_ id: GlossaryEntryID) async throws(AppError) {
        items.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws(AppError) {
        revision += 1
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Stored(version: revision, entries: items)).write(to: url, options: .atomic)
        } catch {
            throw .persistence(.writeFailed)
        }
    }
}
