import Foundation

// MARK: - History (SPEC §02 §14.1)

public enum HistoryKind: String, Sendable, Codable, CaseIterable, Hashable {
    case screenshotTranslation, textTranslation, insertTranslation, color, upload

    /// Categories shown in the translation history window (colors have their own window).
    public static let translationKinds: [HistoryKind] = [.screenshotTranslation, .textTranslation, .insertTranslation, .upload]
}

public struct HistoryEntry: Sendable, Codable, Identifiable, Equatable, Hashable {
    public static let currentSchemaVersion = 1
    public static let thumbnailMaxEdge = 128
    public static let thumbnailMaxBytes = 10 * 1024

    public let schemaVersion: Int
    public let id: HistoryEntryID
    public let kind: HistoryKind
    public var createdAt: Date
    public let source: String
    public let result: String
    public let from: LanguageCode?
    public let to: LanguageCode?
    public let engine: EngineID?
    public let thumbnail: Data?
    public let tags: [String]
    public var isFavorite: Bool

    public init(
        schemaVersion: Int = HistoryEntry.currentSchemaVersion, id: HistoryEntryID = HistoryEntryID(), kind: HistoryKind,
        createdAt: Date = Date(), source: String, result: String, from: LanguageCode? = nil, to: LanguageCode? = nil,
        engine: EngineID? = nil, thumbnail: Data? = nil, tags: [String] = [], isFavorite: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.source = source
        self.result = result
        self.from = from
        self.to = to
        self.engine = engine
        self.thumbnail = thumbnail
        self.tags = tags
        self.isFavorite = isFavorite
    }

    /// Entries with identical content merge (SPEC §03 HIS-10).
    public var contentKey: String { "\(kind.rawValue)|\(source)|\(result)|\(from?.bcp47 ?? "")|\(to?.bcp47 ?? "")" }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, kind, createdAt, source, result, from, to, engine, thumbnail, tags, isFavorite
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decode(HistoryEntryID.self, forKey: .id)
        kind = try c.decode(HistoryKind.self, forKey: .kind)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        result = try c.decodeIfPresent(String.self, forKey: .result) ?? ""
        from = try c.decodeIfPresent(LanguageCode.self, forKey: .from)
        to = try c.decodeIfPresent(LanguageCode.self, forKey: .to)
        engine = try c.decodeIfPresent(EngineID.self, forKey: .engine)
        thumbnail = try c.decodeIfPresent(Data.self, forKey: .thumbnail)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }
}

public struct HistoryQuery: Sendable, Equatable, Hashable {
    public var text: String
    public var kinds: Set<HistoryKind>
    public var favoritesOnly: Bool
    public var offset: Int
    public var limit: Int

    public init(text: String = "", kinds: Set<HistoryKind> = Set(HistoryKind.translationKinds), favoritesOnly: Bool = false, offset: Int = 0, limit: Int = 50) {
        self.text = text
        self.kinds = kinds
        self.favoritesOnly = favoritesOnly
        self.offset = offset
        self.limit = limit
    }

    public static let colors = HistoryQuery(kinds: [.color], limit: 500)

    /// Pure matching rule shared by every store implementation (SPEC §03 HIS-02, COL-05).
    public func matches(_ entry: HistoryEntry) -> Bool {
        guard kinds.contains(entry.kind), !favoritesOnly || entry.isFavorite else { return false }
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        if entry.kind == .color {
            return entry.result.range(of: needle.hasPrefix("#") ? needle : needle, options: [.caseInsensitive]) != nil
        }
        return entry.source.localizedStandardContains(needle) || entry.result.localizedStandardContains(needle)
            || entry.tags.contains { $0.localizedStandardContains(needle) }
    }
}

public struct HistoryPage: Sendable, Equatable {
    public let entries: [HistoryEntry]
    public let totalCount: Int
    public let hasMore: Bool
    /// Set when semantic search was requested but embeddings were unavailable (SPEC §03 AI-05).
    public let semanticFallback: Bool

    public init(entries: [HistoryEntry], totalCount: Int, hasMore: Bool, semanticFallback: Bool = false) {
        self.entries = entries
        self.totalCount = totalCount
        self.hasMore = hasMore
        self.semanticFallback = semanticFallback
    }
}

public enum HistoryScope: Sendable, Equatable {
    case all
    case kinds(Set<HistoryKind>)
}

public enum HistoryExportFormat: String, Sendable, CaseIterable, Equatable { case json, csv, markdown

    public var fileExtension: String {
        switch self {
        case .json: "json"
        case .csv: "csv"
        case .markdown: "md"
        }
    }
}

/// A store-level notice, e.g. a corrupt store that was moved aside (ADR-0009 §11).
public struct HistoryStoreNotice: Sendable, Equatable {
    public let movedAsidePath: String
    public init(movedAsidePath: String) { self.movedAsidePath = movedAsidePath }
}
