import Foundation
import TFDomain

/// Picks the default on-image mode from the layout (SPEC §03 N-03 default display): tightly stacked lines (terminals, code,
/// dense UI) have no room below each line, so the translation replaces the original; lines with space between them show the
/// translation below the original so both stay readable. A choice made in the results drawer always wins.
public enum OverlayModeAdvisor {
    /// Gap under a line, relative to its height, below which a layout counts as dense.
    public static let denseGapRatio = 0.6

    public static func mode(for analysis: AnalysisResult) -> OverlayMode {
        let segments = analysis.segments.filter { $0.translatability.isTranslatable || $0.kind.isCode }
        guard !segments.isEmpty else { return .belowOriginal }
        let monospacedShare = Double(analysis.segments.filter { $0.style?.monospaced == true }.count) / Double(analysis.segments.count)
        if monospacedShare >= 0.5 { return .replaceOriginal }
        let sorted = analysis.segments.sorted { $0.box.minY < $1.box.minY }
        var ratios: [Double] = []
        for (index, line) in sorted.enumerated() where line.box.height > 0 {
            // Nearest line below that overlaps horizontally.
            let next = sorted[(index + 1)...].first { $0.box.minY >= line.box.maxY - 0.5 && $0.box.minX < line.box.maxX && $0.box.maxX > line.box.minX }
            if let next { ratios.append(max(next.box.minY - line.box.maxY, 0) / line.box.height) }
        }
        guard !ratios.isEmpty else { return .belowOriginal }
        let median = ratios.sorted()[ratios.count / 2]
        return median < denseGapRatio ? .replaceOriginal : .belowOriginal
    }
}
