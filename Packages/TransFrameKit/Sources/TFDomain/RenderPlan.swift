import CoreGraphics
import Foundation

// MARK: - RenderPlan (SPEC §02 §9)

public enum CanvasBackground: Sendable, Equatable, Hashable {
    case transparent
    case white
    case beautify(BeautifyStyle)
}

public enum Backdrop: Sendable, Equatable, Hashable {
    case none
    case fill(RGBA)
    /// Color sampled from the surroundings of the original text.
    case sampled(RGBA)
}

public enum FitDecision: String, Sendable, Equatable, Hashable { case fits, shrunk, wrapped, omitted }

public struct TranslationPlacement: Sendable, Equatable, Hashable {
    public let segment: SegmentID
    public let text: String
    public let frame: CanvasRect
    /// Canvas pixels.
    public let fontSize: Double
    public let color: RGBA
    public let backdrop: Backdrop
    /// Area painted with the backdrop before text is drawn (the original text box in replace mode).
    public let backdropFrame: CanvasRect?
    public let alignment: RenderTextAlignment
    public let fit: FitDecision
    public let isRightToLeft: Bool

    public init(
        segment: SegmentID, text: String, frame: CanvasRect, fontSize: Double, color: RGBA, backdrop: Backdrop,
        backdropFrame: CanvasRect? = nil, alignment: RenderTextAlignment = .leading, fit: FitDecision,
        isRightToLeft: Bool = false
    ) {
        self.segment = segment
        self.text = text
        self.frame = frame
        self.fontSize = fontSize
        self.color = color
        self.backdrop = backdrop
        self.backdropFrame = backdropFrame
        self.alignment = alignment
        self.fit = fit
        self.isRightToLeft = isRightToLeft
    }
}

public struct TranslationLayer: Sendable, Equatable, Hashable {
    public let mode: OverlayMode
    public let placements: [TranslationPlacement]
    public init(mode: OverlayMode, placements: [TranslationPlacement]) {
        self.mode = mode
        self.placements = placements
    }
    public var omitted: [TranslationPlacement] { placements.filter { $0.fit == .omitted } }
}

/// An annotation in document coordinates plus the document → canvas translation.
public struct PlacedAnnotation: Sendable, Equatable, Hashable {
    public let annotation: Annotation
    public let offsetX: Double
    public let offsetY: Double
    public init(annotation: Annotation, offsetX: Double, offsetY: Double) {
        self.annotation = annotation
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

public enum RedactionStyle: Sendable, Equatable, Hashable {
    case solid(RGBA)
    /// Visual mosaic of the base pixels; becomes solid for analysis input.
    case mosaic(blockSize: Double)
}

public struct PlacedRedaction: Sendable, Equatable, Hashable {
    public let id: AnnotationID
    public let frame: CanvasRect
    /// Region of the base image (document pixels) the mosaic samples from.
    public let source: DocumentRect
    public let style: RedactionStyle
    public init(id: AnnotationID, frame: CanvasRect, source: DocumentRect, style: RedactionStyle) {
        self.id = id
        self.frame = frame
        self.source = source
        self.style = style
    }
}

public enum RenderLayer: Sendable, Equatable, Hashable {
    case base(source: DocumentRect, destination: CanvasRect)
    case translation(TranslationLayer)
    case decorations([PlacedAnnotation])
    /// Always the last content layer.
    case redactions([PlacedRedaction])
}

public struct RenderPlan: Sendable, Equatable, Hashable {
    public let session: SessionID
    public let editRevision: Int
    public let canvas: PixelSize
    public let scale: Double
    public let background: CanvasBackground
    public let layers: [RenderLayer]
    /// Rect of the content (base image) inside the canvas; differs from the full canvas when beautified.
    public let contentFrame: CanvasRect

    public init(
        session: SessionID, editRevision: Int, canvas: PixelSize, scale: Double, background: CanvasBackground,
        layers: [RenderLayer], contentFrame: CanvasRect
    ) {
        self.session = session
        self.editRevision = editRevision
        self.canvas = canvas
        self.scale = scale
        self.background = background
        self.layers = layers
        self.contentFrame = contentFrame
    }

    public static let maximumCanvasPixels = 400_000_000

    public var translationLayer: TranslationLayer? {
        for case .translation(let layer) in layers { return layer }
        return nil
    }

    /// Validates the fixed layer order: base → translation → decorations → redactions.
    public var hasValidLayerOrder: Bool {
        func rank(_ layer: RenderLayer) -> Int {
            switch layer {
            case .base: 0
            case .translation: 1
            case .decorations: 2
            case .redactions: 3
            }
        }
        let ranks = layers.map(rank)
        return ranks == ranks.sorted() && Set(ranks).count == ranks.count
    }
}

public enum RenderPurpose: Sendable, Equatable, Hashable {
    case screen
    case clipboard
    case file(ExportFormat)
    case pin
    case upload
    case thumbnail
    case analysisInput(AnalysisInputPolicy)
}

public enum ExportFormat: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case png, jpeg, heic

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }
    public var isLossy: Bool { self != .png }
    public var uniformTypeIdentifier: String {
        switch self {
        case .png: "public.png"
        case .jpeg: "public.jpeg"
        case .heic: "public.heic"
        }
    }
}

public struct TextMetrics: Sendable, Equatable {
    public let width: Double
    public let height: Double
    public let lineCount: Int
    public init(width: Double, height: Double, lineCount: Int) {
        self.width = width
        self.height = height
        self.lineCount = lineCount
    }
}
