import CoreGraphics
import Foundation
import TFDomain

/// Pure plan builder (SPEC §02 §9, ADR-0006): same snapshot + purpose → same plan.
public struct RenderPlanner: Sendable {
    private let layout: TranslationLayoutPlanner

    public init(measurer: any TextMeasuring) {
        layout = TranslationLayoutPlanner(measurer: measurer)
    }

    public func plan(for session: DocumentSession, purpose: RenderPurpose, excluding excluded: Set<AnnotationID> = []) throws(AppError) -> RenderPlan {
        let visible = session.visibleRect.integralOutward.intersection(session.imageBounds) ?? session.imageBounds
        let isAnalysis: AnalysisInputPolicy? = {
            switch purpose {
            case .analysisInput(let policy): policy
            case .thumbnail: .safe
            default: nil
            }
        }()
        let beautify = session.presentation.beautify && isAnalysis == nil
        let padding = beautify ? (BeautifyStyle.padding * session.baseImage.scale).rounded() : 0
        let width = Int(visible.width + 2 * padding)
        let height = Int(visible.height + 2 * padding)
        guard width > 0, height > 0, width.multipliedReportingOverflow(by: height).partialValue <= RenderPlan.maximumCanvasPixels else {
            throw .render(.canvasTooLarge)
        }
        let offsetX = padding - visible.minX
        let offsetY = padding - visible.minY
        let content = CanvasRect(x: padding, y: padding, width: visible.width, height: visible.height)

        var layers: [RenderLayer] = [.base(source: visible, destination: content)]

        if isAnalysis == nil, session.presentation.showsTranslationOverlay,
           let analysis = session.analysis, let segments = session.effectiveTranslation {
            let placements = layout.layout(
                analysis: analysis, translations: segments, mode: session.presentation.overlayMode,
                offsetX: offsetX, offsetY: offsetY, canvas: content, scale: session.baseImage.scale
            )
            if !placements.isEmpty {
                layers.append(.translation(TranslationLayer(mode: session.presentation.overlayMode, placements: placements)))
            }
        }

        let annotations = session.annotations.filter { !excluded.contains($0.id) }
        let includeDecorations = isAnalysis == nil || isAnalysis == .asDisplayed
        if includeDecorations {
            let decorations = annotations.filter { $0.role == .decoration }
                .map { PlacedAnnotation(annotation: $0, offsetX: offsetX, offsetY: offsetY) }
            if !decorations.isEmpty { layers.append(.decorations(decorations)) }
        }

        if isAnalysis != .original {
            let solidForUpload = purpose == .upload || isAnalysis == .safe || isAnalysis == .asDisplayed
            let redactions: [PlacedRedaction] = annotations.compactMap { annotation in
                switch annotation {
                case .redaction(let r):
                    return PlacedRedaction(
                        id: r.id, frame: CanvasRect(r.rect.raw.offsetBy(dx: offsetX, dy: offsetY)), source: r.rect,
                        style: .solid(solidForUpload ? r.fill.withAlpha(1) : r.fill))
                case .mosaic(let m) where m.isPrivacy:
                    let frame = CanvasRect(m.rect.raw.offsetBy(dx: offsetX, dy: offsetY))
                    return PlacedRedaction(id: m.id, frame: frame, source: m.rect, style: solidForUpload ? .solid(.black) : .mosaic(blockSize: m.blockSize))
                default:
                    return nil
                }
            }
            if !redactions.isEmpty { layers.append(.redactions(redactions)) }
        }

        let background: CanvasBackground
        switch purpose {
        case .file(.jpeg): background = beautify ? .beautify(.matte(.white)) : .white
        default: background = beautify ? .beautify(session.presentation.beautifyStyle) : .transparent
        }

        return RenderPlan(
            session: session.id, editRevision: session.editRevision, canvas: PixelSize(width: width, height: height),
            scale: session.baseImage.scale, background: background, layers: layers, contentFrame: content
        )
    }
}
