import CoreGraphics
import Foundation

// MARK: - DocumentSession (SPEC §02 §5)

public struct CaptureProvenance: Sendable, Equatable {
    public let intent: CaptureIntent
    public let selection: SelectionGeometry
    public let displays: [DisplayID]
    public let capturedAt: Date

    public init(intent: CaptureIntent, selection: SelectionGeometry, displays: [DisplayID], capturedAt: Date) {
        self.intent = intent
        self.selection = selection
        self.displays = displays
        self.capturedAt = capturedAt
    }
}

public enum SessionOrigin: Sendable, Equatable {
    case capture(CaptureProvenance)
    case importedFile(name: String)
    case scroll
}

public enum OverlayMode: String, Sendable, Codable, Equatable, CaseIterable {
    case belowOriginal, replaceOriginal
}

public enum BeautifyStyle: Sendable, Codable, Equatable, Hashable {
    /// Rounded corners and a soft shadow inside a transparent margin, no backdrop. Padding, corner radius and shadow
    /// are content parameters (36 / 12 / 24).
    case transparent
    /// The same frame on a solid matte, for formats without alpha (JPEG).
    case matte(RGBA)

    public static let `default` = BeautifyStyle.transparent
    public static let padding = 36.0
    public static let cornerRadius = 12.0
    public static let shadowRadius = 24.0
}

public struct PresentationOptions: Sendable, Codable, Equatable, Hashable {
    /// Whether the translation layer is drawn on the image (vs. the text drawer only).
    public var showsTranslationOverlay: Bool
    public var overlayMode: OverlayMode
    public var beautify: Bool
    public var beautifyStyle: BeautifyStyle

    public init(
        showsTranslationOverlay: Bool = false, overlayMode: OverlayMode = .belowOriginal,
        beautify: Bool = false, beautifyStyle: BeautifyStyle = .default
    ) {
        self.showsTranslationOverlay = showsTranslationOverlay
        self.overlayMode = overlayMode
        self.beautify = beautify
        self.beautifyStyle = beautifyStyle
    }
}

public struct DocumentSession: Sendable, Identifiable {
    public let id: SessionID
    public let createdAt: Date
    public let origin: SessionOrigin
    public let baseImage: PixelImage
    public let context: CaptureContext?
    public var crop: DocumentRect?
    /// Bottom-up z-order.
    public var annotations: [Annotation]
    public var analysis: AnalysisResult?
    public var translation: TranslationOutcome?
    public var presentation: PresentationOptions
    public var suggestedName: String?
    public var editRevision: Int
    public var analysisInputRevision: Int
    public var lastSavedRevision: Int?

    public init(
        id: SessionID = SessionID(), createdAt: Date = Date(), origin: SessionOrigin, baseImage: PixelImage,
        context: CaptureContext? = nil, crop: DocumentRect? = nil, annotations: [Annotation] = [],
        analysis: AnalysisResult? = nil, translation: TranslationOutcome? = nil,
        presentation: PresentationOptions = PresentationOptions(), suggestedName: String? = nil,
        editRevision: Int = 0, analysisInputRevision: Int = 0, lastSavedRevision: Int? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.origin = origin
        self.baseImage = baseImage
        self.context = context
        self.crop = crop
        self.annotations = annotations
        self.analysis = analysis
        self.translation = translation
        self.presentation = presentation
        self.suggestedName = suggestedName
        self.editRevision = editRevision
        self.analysisInputRevision = analysisInputRevision
        self.lastSavedRevision = lastSavedRevision
    }

    public var hasUnsavedEdits: Bool { lastSavedRevision != editRevision }

    /// Full image bounds in document pixels.
    public var imageBounds: DocumentRect { DocumentRect(baseImage.pixelSize.bounds) }
    /// The visible region: the crop, or the full image.
    public var visibleRect: DocumentRect { crop ?? imageBounds }

    public func annotation(_ id: AnnotationID) -> Annotation? { annotations.first { $0.id == id } }
    public func annotationIndex(_ id: AnnotationID) -> Int? { annotations.firstIndex { $0.id == id } }

    /// Translation results from the currently effective engine, if any.
    public var effectiveTranslation: [BilingualSegment]? {
        guard let translation, let engine = translation.effective else { return nil }
        return translation.results.first { $0.id == engine }?.segments
    }
}

// MARK: - Transactions

public struct EditTransaction: Sendable {
    public let id: OperationID
    /// Localization key used for "Undo <label>".
    public let label: String
    public let forward: [SessionEdit]
    public let inverse: [SessionEdit]

    public init(id: OperationID = OperationID(), label: String, forward: [SessionEdit], inverse: [SessionEdit]) {
        self.id = id
        self.label = label
        self.forward = forward
        self.inverse = inverse
    }
}

public enum SessionEdit: Sendable, Equatable {
    case insertAnnotation(Annotation, at: Int)
    case replaceAnnotation(Annotation)
    case removeAnnotation(AnnotationID)
    case moveAnnotation(AnnotationID, to: Int)
    case setCrop(DocumentRect?)
    case setPresentation(PresentationOptions)
    case reviseSegment(SegmentID, text: String?)
    case setSuggestedName(String?)
}

/// Who keeps a session alive. A session is released when its last owner releases it.
public enum SessionOwner: Sendable, Hashable {
    case capture(OperationID)
    case editor(UUID)
    case pin(UUID)
    case workflow(OperationID)
}

/// Kind of long-running task registered on a session; a new task of the same kind supersedes the old one.
public enum SessionTaskKind: String, Sendable, Hashable {
    case recognition, translation, privacyScan, naming, export
}
