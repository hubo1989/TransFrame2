import Foundation

// MARK: - Transaction factories: compute the inverse from the current snapshot (pure).

extension EditTransaction {
    public static func insert(_ annotation: Annotation, at index: Int? = nil, into session: DocumentSession, label: String) -> EditTransaction {
        let position = min(max(index ?? session.annotations.count, 0), session.annotations.count)
        return EditTransaction(label: label, forward: [.insertAnnotation(annotation, at: position)], inverse: [.removeAnnotation(annotation.id)])
    }

    /// nil when the annotation does not exist or nothing changed.
    public static func replace(_ annotation: Annotation, in session: DocumentSession, label: String) -> EditTransaction? {
        guard let old = session.annotation(annotation.id), old != annotation else { return nil }
        return EditTransaction(label: label, forward: [.replaceAnnotation(annotation)], inverse: [.replaceAnnotation(old)])
    }

    public static func remove(_ ids: [AnnotationID], from session: DocumentSession, label: String) -> EditTransaction? {
        let present = ids.compactMap { id in session.annotationIndex(id).map { (id, $0) } }.sorted { $0.1 < $1.1 }
        guard !present.isEmpty else { return nil }
        let forward = present.map { SessionEdit.removeAnnotation($0.0) }
        let inverse = present.map { SessionEdit.insertAnnotation(session.annotations[$0.1], at: $0.1) }
        return EditTransaction(label: label, forward: forward, inverse: inverse)
    }

    public static func move(_ id: AnnotationID, to index: Int, in session: DocumentSession, label: String) -> EditTransaction? {
        guard let from = session.annotationIndex(id), from != index else { return nil }
        let target = min(max(index, 0), session.annotations.count - 1)
        return EditTransaction(label: label, forward: [.moveAnnotation(id, to: target)], inverse: [.moveAnnotation(id, to: from)])
    }

    public static func setCrop(_ crop: DocumentRect?, in session: DocumentSession, label: String) -> EditTransaction? {
        let normalized = crop == session.imageBounds ? nil : crop
        guard normalized != session.crop else { return nil }
        let crop = normalized
        return EditTransaction(label: label, forward: [.setCrop(crop)], inverse: [.setCrop(session.crop)])
    }

    public static func setPresentation(_ presentation: PresentationOptions, in session: DocumentSession, label: String) -> EditTransaction? {
        guard presentation != session.presentation else { return nil }
        return EditTransaction(label: label, forward: [.setPresentation(presentation)], inverse: [.setPresentation(session.presentation)])
    }

    public static func reviseSegment(_ id: SegmentID, text: String?, in session: DocumentSession, label: String) -> EditTransaction? {
        guard let segment = session.analysis?.segment(id), segment.revisedText != text else { return nil }
        return EditTransaction(label: label, forward: [.reviseSegment(id, text: text)], inverse: [.reviseSegment(id, text: segment.revisedText)])
    }

    /// Several annotations added at once (e.g. smart mosaic, privacy guard).
    public static func insertAll(_ annotations: [Annotation], into session: DocumentSession, label: String) -> EditTransaction? {
        guard !annotations.isEmpty else { return nil }
        let start = session.annotations.count
        let forward = annotations.enumerated().map { SessionEdit.insertAnnotation($0.element, at: start + $0.offset) }
        let inverse = annotations.reversed().map { SessionEdit.removeAnnotation($0.id) }
        return EditTransaction(label: label, forward: forward, inverse: inverse)
    }
}
