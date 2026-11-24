import CoreGraphics
import Foundation
import TFDomain

/// Copy, save and upload of a session's rendered image (EDT-05/06, INP-02/03/09, EXP-01…04, N-10).
public struct ExportService: ExportWorkflow {
    private let sessions: DocumentSessionStore
    private let render: RenderService
    private let pasteboard: any PasteboardAccessing
    private let encoder: any ImageEncoding
    private let files: any FileExporting
    private let sound: any SoundPlaying
    private let uploader: (any ImageUploading)?
    private let guardian: PrivacyGuard
    private let history: (any HistoryWorkflow)?
    private let namer: FileNamer
    private let defaultDirectory: @Sendable () -> URL
    private let now: @Sendable () -> Date

    public init(
        sessions: DocumentSessionStore, render: RenderService, pasteboard: any PasteboardAccessing, encoder: any ImageEncoding,
        files: any FileExporting, sound: any SoundPlaying, uploader: (any ImageUploading)?, history: (any HistoryWorkflow)?,
        namer: FileNamer, guardian: PrivacyGuard,
        defaultDirectory: @escaping @Sendable () -> URL, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessions = sessions
        self.render = render
        self.pasteboard = pasteboard
        self.encoder = encoder
        self.files = files
        self.sound = sound
        self.uploader = uploader
        self.history = history
        self.guardian = guardian
        self.namer = namer
        self.defaultDirectory = defaultDirectory
        self.now = now
    }

    public func copyImage(of id: SessionID, settings: SettingsSnapshot) async throws(AppError) {
        let image = try await render.image(for: id, purpose: .clipboard)
        try await pasteboard.writeImage(image)
        if settings.general.playsSound { await sound.play(.capture) }
    }

    public func save(_ id: SessionID, as format: ExportFormat?, settings: SettingsSnapshot) async throws(AppError) -> SaveReceipt {
        let format = format ?? settings.export.format
        let session = try await sessions.snapshot(of: id)
        let image = try await render.image(of: session, purpose: .file(format))
        let data = try encoder.encode(image, format: format, quality: settings.export.quality(for: format))
        let directory = settings.general.saveLocationPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultDirectory()
        let name = await namer.name(for: session, settings: settings, date: now())
        if name.suggested, session.suggestedName != name.base {
            let base = name.base
            await sessions.update(id) { $0.suggestedName = base }
        }
        let url = try await files.write(data, baseName: name.base, fileExtension: format.fileExtension, to: directory)
        await sessions.markSaved(id, revision: session.editRevision)
        if settings.general.playsSound { await sound.play(.capture) }
        return SaveReceipt(url: url, usedSuggestedName: name.suggested)
    }

    public func upload(_ id: SessionID, settings: SettingsSnapshot) async throws(AppError) -> UploadReceipt {
        guard let uploader, settings.imageHost.provider != nil else { throw .upload(.notConfigured) }
        let session = try await sessions.snapshot(of: id)
        let rendered = try await render.image(of: session, purpose: .upload)
        // The image guard follows the destination like engines do: loopback never, the local network only when asked.
        let guarded = PrivacyGuard.applies(to: settings.imageHost.locality, settings: settings.privacy, overridden: false)
        let image = if guarded { try await guardian.protect(rendered, settings: settings.privacy).0 } else { rendered }
        let data = try encoder.encode(image, format: .png, quality: 1)
        let objectName = "screenshot-\(UUID().uuidString.lowercased()).png"
        let receipt = try await uploader.upload(data, fileName: objectName, contentType: "image/png", settings: settings.imageHost)
        try await pasteboard.write(.string(receipt.url.absoluteString))
        if settings.general.playsSound { await sound.play(.capture) }
        await history?.record(
            HistoryEntry(kind: .upload, source: receipt.markdown, result: receipt.url.absoluteString, engine: receipt.provider),
            settings: settings
        )
        return receipt
    }
}

/// Chooses the saved file name: AI suggestion when enabled, then app + keywords + time, then the default (AI-07, EXP-01).
public struct FileNamer: Sendable {
    public typealias Suggest = @Sendable (DocumentSession, SettingsSnapshot) async -> String?
    private let suggest: Suggest?

    public init(suggest: Suggest? = nil) {
        self.suggest = suggest
    }

    public func name(for session: DocumentSession, settings: SettingsSnapshot, date: Date) async -> (base: String, suggested: Bool) {
        if settings.ai.autoNaming {
            if let existing = session.suggestedName.flatMap({ ScreenshotNaming.sanitize($0) }) { return (existing, true) }
            if let suggest, let raw = await suggest(session, settings), let clean = ScreenshotNaming.sanitize(raw) {
                return (clean, true)
            }
            if let fallback = Self.fallback(for: session, date: date) { return (fallback, true) }
        }
        return (ScreenshotNaming.baseName(for: date), false)
    }

    /// "App – keywords – time" from local data only (AI-07 without a model).
    static func fallback(for session: DocumentSession, date: Date) -> String? {
        let keywords = Keywords.extract(from: session.analysis?.plainText ?? "", limit: 3)
        guard session.context?.appName != nil || !keywords.isEmpty else { return nil }
        var parts: [String] = []
        if let app = session.context?.appName { parts.append(app) }
        if !keywords.isEmpty { parts.append(keywords.joined(separator: " ")) }
        let time = ScreenshotNaming.baseName(for: date).replacingOccurrences(of: "Screenshot ", with: "")
        parts.append(time)
        return ScreenshotNaming.sanitize(parts.joined(separator: " - "), maxLength: 100)
    }
}

enum Keywords {
    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "your", "you", "are", "was", "have", "has", "not", "but",
        "all", "can", "will", "una", "les", "des", "der", "die", "das", "und",
    ]

    /// Most frequent meaningful words (letters only, ≥ 3 characters; CJK runs of ≥ 2 characters).
    static func extract(from text: String, limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .localized]) { word, _, _, _ in
            guard let word else { return }
            let lower = word.lowercased()
            let isCJK = lower.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
            guard isCJK ? lower.count >= 2 : (lower.count >= 3 && lower.allSatisfy(\.isLetter)), !stopwords.contains(lower) else { return }
            if counts[lower] == nil { order.append(lower) }
            counts[lower, default: 0] += 1
        }
        return order.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }.prefix(limit).map { $0 }
    }
}
