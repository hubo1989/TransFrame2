import Foundation
import TFDomain

/// Glossary editing and "correct and remember" (AI-04).
public struct GlossaryService: GlossaryWorkflow {
    private let store: any GlossaryStoring
    private let sessions: DocumentSessionStore

    public init(store: any GlossaryStoring, sessions: DocumentSessionStore) {
        self.store = store
        self.sessions = sessions
    }

    public func entries() async throws(AppError) -> [GlossaryEntry] { try await store.entries() }
    public func save(_ entry: GlossaryEntry) async throws(AppError) { try await store.upsert(entry) }
    public func remove(_ id: GlossaryEntryID) async throws(AppError) { try await store.remove(id) }

    /// Replaces the segment's translation in the session and optionally stores a fixed translation for the source text.
    public func correct(_ segment: SegmentID, in id: SessionID, translation: String, remember: Bool) async throws(AppError) {
        let session = try await sessions.snapshot(of: id)
        guard var outcome = session.translation, let engine = outcome.effective,
              let index = outcome.results.firstIndex(where: { $0.id == engine }) else { throw .invariant("no translation") }
        let result = outcome.results[index]
        let segments = result.segments.map { s in
            s.id == segment ? BilingualSegment(id: s.id, source: s.source, translated: translation, status: .translated, from: s.from, to: s.to, glossaryHits: s.glossaryHits) : s
        }
        var results = outcome.results
        results[index] = EngineResult(id: result.id, segments: segments, error: result.error, skipped: result.skipped, duration: result.duration, fromCache: result.fromCache)
        outcome = TranslationOutcome(operation: outcome.operation, routing: outcome.routing, results: results, effective: engine, target: outcome.target, privacy: outcome.privacy)
        let updated = outcome
        await sessions.update(id) { $0.translation = updated }
        guard remember, let source = session.analysis?.segment(segment)?.effectiveText, let to = outcome.target else { return }
        let scope: GlossaryScope = session.context?.appBundleID.map { .app(bundleID: $0) } ?? .global
        try await store.upsert(GlossaryEntry(source: source, target: translation, from: segments.first { $0.id == segment }?.from, to: to, scope: scope))
    }
}
