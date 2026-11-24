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
    public func correct(
        _ segment: SegmentID, in id: SessionID, expectedOperation: OperationID, translation: String, remember: Bool
    ) async throws(AppError) {
        let entry = try await sessions.correctTranslation(segment, in: id, expectedOperation: expectedOperation, text: translation)
        if remember { try await store.upsert(entry) }
    }
}
