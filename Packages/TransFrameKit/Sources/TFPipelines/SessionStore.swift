import CoreGraphics
import Foundation
import TFDomain

// MARK: - Reducer (pure): applies edits and reports revision effects (SPEC §02 §5).

enum SessionReducer {
    struct Effect: Equatable {
        var invalidatesAnalysis = false
        var revisedSegments: [SegmentID] = []
        var changesContent = false
    }

    static func apply(_ edits: [SessionEdit], to session: inout DocumentSession) throws(AppError) -> Effect {
        var effect = Effect()
        for edit in edits {
            switch edit {
            case .insertAnnotation(let annotation, let index):
                guard session.annotationIndex(annotation.id) == nil else { throw .invariant("duplicate annotation") }
                session.annotations.insert(annotation, at: min(max(index, 0), session.annotations.count))
                effect.changesContent = true
                if annotation.affectsAnalysisInput { effect.invalidatesAnalysis = true }
            case .replaceAnnotation(let annotation):
                guard let index = session.annotationIndex(annotation.id) else { throw .invariant("missing annotation") }
                let old = session.annotations[index]
                session.annotations[index] = annotation
                effect.changesContent = true
                if old.affectsAnalysisInput || annotation.affectsAnalysisInput { effect.invalidatesAnalysis = true }
            case .removeAnnotation(let id):
                guard let index = session.annotationIndex(id) else { throw .invariant("missing annotation") }
                let old = session.annotations.remove(at: index)
                effect.changesContent = true
                if old.affectsAnalysisInput { effect.invalidatesAnalysis = true }
            case .moveAnnotation(let id, let target):
                guard let index = session.annotationIndex(id) else { throw .invariant("missing annotation") }
                let annotation = session.annotations.remove(at: index)
                session.annotations.insert(annotation, at: min(max(target, 0), session.annotations.count))
                effect.changesContent = true
            case .setCrop(let crop):
                if let crop {
                    let normalized = crop.standardized.integralOutward
                    guard normalized.width >= 1, normalized.height >= 1, session.imageBounds.contains(normalized) else {
                        throw .recognition(.regionOutOfBounds)
                    }
                    session.crop = normalized == session.imageBounds ? nil : normalized
                } else {
                    session.crop = nil
                }
                effect.changesContent = true
                effect.invalidatesAnalysis = true
            case .setPresentation(let presentation):
                session.presentation = presentation
                effect.changesContent = true
            case .reviseSegment(let id, let text):
                guard var analysis = session.analysis, let index = analysis.segments.firstIndex(where: { $0.id == id }) else {
                    throw .invariant("missing segment")
                }
                analysis.segments[index] = analysis.segments[index].with(revisedText: text)
                session.analysis = analysis
                effect.changesContent = true
                effect.revisedSegments.append(id)
            case .setSuggestedName(let name):
                session.suggestedName = name
            }
        }
        return effect
    }

    /// Applies revision bookkeeping after a successful edit.
    static func commit(_ effect: Effect, to session: inout DocumentSession) {
        if effect.changesContent { session.editRevision += 1 }
        if effect.invalidatesAnalysis {
            session.analysisInputRevision += 1
            session.analysis = nil
            session.translation = nil
        } else if !effect.revisedSegments.isEmpty, let translation = session.translation {
            session.translation = invalidating(effect.revisedSegments, in: translation, analysis: session.analysis)
        }
    }

    /// A revised segment's translations become stale; the rest stay valid (SPEC §02 §5 table).
    private static func invalidating(_ ids: [SegmentID], in outcome: TranslationOutcome, analysis: AnalysisResult?) -> TranslationOutcome {
        let set = Set(ids)
        let results = outcome.results.map { result in
            EngineResult(
                id: result.id,
                segments: result.segments.map { segment in
                    guard set.contains(segment.id) else { return segment }
                    let source = analysis?.segment(segment.id)?.effectiveText ?? segment.source
                    return BilingualSegment(id: segment.id, source: source, translated: nil, status: .cancelled, from: segment.from, to: segment.to)
                },
                error: result.error, skipped: result.skipped, duration: result.duration, fromCache: result.fromCache
            )
        }
        return TranslationOutcome(
            operation: outcome.operation, routing: outcome.routing, results: results, effective: outcome.effective,
            target: outcome.target, privacy: outcome.privacy
        )
    }
}

// MARK: - Store

/// Owns every document session (SPEC §01 §5). Writes only through transactions; results are accepted
/// only when session, input revision and operation all match (ADR-0004 §5).
public actor DocumentSessionStore: SessionManaging {
    public static let undoDepth = 50

    private struct Entry {
        var session: DocumentSession
        var undo: [EditTransaction] = []
        var redo: [EditTransaction] = []
        var owners: Set<SessionOwner> = []
        var observers: [UUID: AsyncStream<DocumentSession>.Continuation] = [:]
        var operations: [SessionTaskKind: OperationID] = [:]
        var tasks: [SessionTaskKind: Task<Void, Never>] = [:]
    }

    private var entries: [SessionID: Entry] = [:]
    private let composer: any FrameComposing
    private let clock: @Sendable () -> Date

    public init(composer: any FrameComposing, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.composer = composer
        self.clock = clock
    }

    public var sessionCount: Int { entries.count }

    // MARK: Creation

    public func create(from frames: FrozenFrameSet, selection: SelectionGeometry) async throws(AppError) -> SessionID {
        let resolved = try selection.resolve(in: frames)
        let image = try await composer.compose(resolved, from: frames)
        let provenance = CaptureProvenance(
            intent: frames.request.intent, selection: selection, displays: resolved.slices.map(\.display), capturedAt: frames.request.triggerDate
        )
        let session = DocumentSession(createdAt: clock(), origin: .capture(provenance), baseImage: image, context: frames.context)
        entries[session.id] = Entry(session: session)
        return session.id
    }

    public func create(importing image: PixelImage, name: String) async -> SessionID {
        insert(DocumentSession(createdAt: clock(), origin: .importedFile(name: name), baseImage: image))
    }

    /// Registers a prepared session (scroll capture, tests).
    @discardableResult
    public func insert(_ session: DocumentSession) -> SessionID {
        entries[session.id] = Entry(session: session)
        return session.id
    }

    // MARK: Reading

    public func snapshot(of id: SessionID) async throws(AppError) -> DocumentSession {
        guard let entry = entries[id] else { throw .cancelled }
        return entry.session
    }

    public func snapshots(of id: SessionID) async -> AsyncStream<DocumentSession> {
        let (stream, continuation) = AsyncStream<DocumentSession>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard let entry = entries[id] else {
            continuation.finish()
            return stream
        }
        let token = UUID()
        entries[id]?.observers[token] = continuation
        continuation.yield(entry.session)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(token, from: id) }
        }
        return stream
    }

    private func removeObserver(_ token: UUID, from id: SessionID) {
        entries[id]?.observers[token] = nil
    }

    private func broadcast(_ id: SessionID) {
        guard let entry = entries[id] else { return }
        for continuation in entry.observers.values { continuation.yield(entry.session) }
    }

    // MARK: Editing

    public func apply(_ transaction: EditTransaction, to id: SessionID) async throws(AppError) {
        guard var entry = entries[id] else { throw .cancelled }
        var session = entry.session
        let effect = try SessionReducer.apply(transaction.forward, to: &session)
        SessionReducer.commit(effect, to: &session)
        entry.session = session
        if effect.invalidatesAnalysis { cancelTasks(&entry, kinds: [.recognition, .translation, .privacyScan]) }
        entry.undo.append(transaction)
        if entry.undo.count > Self.undoDepth { entry.undo.removeFirst(entry.undo.count - Self.undoDepth) }
        entry.redo.removeAll()
        entries[id] = entry
        broadcast(id)
    }

    public func undo(_ id: SessionID) async -> Bool { step(id, undo: true) }
    public func redo(_ id: SessionID) async -> Bool { step(id, undo: false) }
    public func canUndo(_ id: SessionID) async -> Bool { !(entries[id]?.undo.isEmpty ?? true) }
    public func canRedo(_ id: SessionID) async -> Bool { !(entries[id]?.redo.isEmpty ?? true) }

    private func step(_ id: SessionID, undo: Bool) -> Bool {
        guard var entry = entries[id], let transaction = undo ? entry.undo.last : entry.redo.last else { return false }
        var session = entry.session
        do {
            let effect = try SessionReducer.apply(undo ? transaction.inverse : transaction.forward, to: &session)
            var forced = effect
            forced.changesContent = true
            SessionReducer.commit(forced, to: &session)
            if effect.invalidatesAnalysis { cancelTasks(&entry, kinds: [.recognition, .translation, .privacyScan]) }
        } catch {
            return false
        }
        entry.session = session
        if undo {
            entry.undo.removeLast()
            entry.redo.append(transaction)
        } else {
            entry.redo.removeLast()
            entry.undo.append(transaction)
        }
        entries[id] = entry
        broadcast(id)
        return true
    }

    public func markSaved(_ id: SessionID, revision: Int) async {
        guard entries[id] != nil else { return }
        entries[id]?.session.lastSavedRevision = revision
        broadcast(id)
    }

    /// Metadata write without undo (suggested names, presentation set by workflows).
    public func update(_ id: SessionID, _ body: @Sendable (inout DocumentSession) -> Void) {
        guard entries[id] != nil else { return }
        body(&entries[id]!.session)
        broadcast(id)
    }

    // MARK: Ownership

    public func retain(_ id: SessionID, by owner: SessionOwner) async {
        entries[id]?.owners.insert(owner)
    }

    /// The last owner's release cancels every task and frees the session (SPEC §02 §5).
    public func release(_ id: SessionID, by owner: SessionOwner) async {
        guard var entry = entries[id] else { return }
        entry.owners.remove(owner)
        guard entry.owners.isEmpty else {
            entries[id] = entry
            return
        }
        cancelTasks(&entry, kinds: Array(entry.tasks.keys))
        for continuation in entry.observers.values { continuation.finish() }
        entries[id] = nil
    }

    // MARK: Tasks and guarded writes (ADR-0004 §4, §5)

    /// Starts a new operation of `kind`; the previous one of the same kind is cancelled and its writes rejected.
    public func beginOperation(_ kind: SessionTaskKind, on id: SessionID) throws(AppError) -> (OperationID, inputRevision: Int) {
        guard var entry = entries[id] else { throw .cancelled }
        cancelTasks(&entry, kinds: [kind])
        let operation = OperationID()
        entry.operations[kind] = operation
        entries[id] = entry
        return (operation, entry.session.analysisInputRevision)
    }

    public func attach(_ task: Task<Void, Never>, kind: SessionTaskKind, operation: OperationID, on id: SessionID) {
        guard entries[id]?.operations[kind] == operation else {
            task.cancel()
            return
        }
        entries[id]?.tasks[kind] = task
    }

    public func finishOperation(_ kind: SessionTaskKind, operation: OperationID, on id: SessionID) {
        guard entries[id]?.operations[kind] == operation else { return }
        entries[id]?.operations[kind] = nil
        entries[id]?.tasks[kind] = nil
    }

    public func cancelOperations(on id: SessionID, kinds: [SessionTaskKind]) {
        guard var entry = entries[id] else { return }
        cancelTasks(&entry, kinds: kinds)
        entries[id] = entry
    }

    public func isCurrent(_ kind: SessionTaskKind, operation: OperationID, on id: SessionID) -> Bool {
        entries[id]?.operations[kind] == operation
    }

    private func cancelTasks(_ entry: inout Entry, kinds: [SessionTaskKind]) {
        for kind in kinds {
            entry.tasks[kind]?.cancel()
            entry.tasks[kind] = nil
            entry.operations[kind] = nil
        }
    }

    /// Writes a recognition result if it still belongs to the session's current input (triple check).
    public func writeAnalysis(_ result: AnalysisResult, kind: SessionTaskKind, operation: OperationID) throws(AppError) {
        guard var entry = entries[result.session], entry.operations[kind] == operation,
              entry.session.analysisInputRevision == result.inputRevision else { throw .cancelled }
        entry.session.analysis = result
        entry.session.translation = nil
        entries[result.session] = entry
        broadcast(result.session)
    }

    public func writeTranslation(
        _ outcome: TranslationOutcome, to id: SessionID, inputRevision: Int, kind: SessionTaskKind, operation: OperationID
    ) throws(AppError) {
        guard var entry = entries[id], entry.operations[kind] == operation,
              entry.session.analysisInputRevision == inputRevision else { throw .cancelled }
        entry.session.translation = outcome
        entries[id] = entry
        broadcast(id)
    }

    public func setEffectiveEngine(_ engine: EngineID, in id: SessionID) throws(AppError) {
        guard var translation = entries[id]?.session.translation else { throw .cancelled }
        guard translation.results.contains(where: { $0.id == engine && $0.succeeded }) else { throw .invariant("engine has no result") }
        translation.effective = engine
        entries[id]?.session.translation = translation
        broadcast(id)
    }

    /// Restores an excluded segment into the visible list (OCR-13).
    public func restoreExcluded(_ segmentID: SegmentID, in id: SessionID) throws(AppError) {
        guard var analysis = entries[id]?.session.analysis,
              let index = analysis.excluded.firstIndex(where: { $0.segment.id == segmentID }) else { throw .invariant("not excluded") }
        let restored = analysis.excluded.remove(at: index).segment
        let position = analysis.segments.firstIndex { ($0.box.minY, $0.box.minX) > (restored.box.minY, restored.box.minX) } ?? analysis.segments.count
        analysis.segments.insert(restored, at: position)
        entries[id]?.session.analysis = analysis
        broadcast(id)
    }
}
