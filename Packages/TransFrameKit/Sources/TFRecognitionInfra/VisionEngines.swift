import CoreGraphics
import Foundation
import ImageIO
import os
import TFDomain
import TFNetworkInfra
@preconcurrency import Vision

// MARK: - Vision text recognition (OCR-01, OCR-02, N-17)

struct VisionTextEngine: RecognitionEngine {
    let descriptor: EngineDescriptor
    var fast = false

    func recognize(_ image: PixelImage, hints: [LanguageCode], detail: AnalysisDetail) async throws(AppError) -> RawRecognition {
        let lines = try await VisionOCR.lines(in: image.cgImage, hints: hints, fast: fast, engine: descriptor.id)
        let observations = lines.map { line in
            RawObservation(
                text: line.text, box: line.box, quad: line.quad, confidence: line.confidence,
                style: SegmentStyleHint(fontSize: line.box.height * 0.82)
            )
        }
        return RawRecognition(observations: observations, languages: hints, sent: .nothing)
    }
}

enum VisionOCR {
    struct Line {
        let text: String
        let box: FrameRect
        let quad: [CGPoint]
        let confidence: Double
        let findings: [SensitiveFinding]
    }

    /// Accurate recognition with language correction; cancelling the task cancels the Vision request.
    static func lines(in image: CGImage, hints: [LanguageCode], fast: Bool, engine: EngineID, detectSensitive: Bool = false) async throws(AppError) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = !fast
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let wanted = hints.map(\.bcp47).compactMap { hint in
            supported.first { $0.lowercased().hasPrefix(hint.lowercased()) || hint.lowercased().hasPrefix($0.lowercased()) }
        }
        if wanted.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = wanted
        }
        let width = Double(image.width), height = Double(image.height)
        do {
            let observations: [VNRecognizedTextObservation] = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                try handler.perform([request])
                try Task.checkCancellation()
                return request.results ?? []
            } onCancel: {
                request.cancel()
            }
            return observations.compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let b = observation.boundingBox
                let box = VisionGeometry.frameRect(b, width: width, height: height)
                let quad = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft].map {
                    VisionGeometry.framePoint($0, width: width, height: height)
                }
                let findings: [SensitiveFinding] = detectSensitive ? SensitiveTextClassifier.matches(in: candidate.string).map { match in
                    let rect = (try? candidate.boundingBox(for: match.range))?.boundingBox
                    let mask = rect.map {
                        VisionGeometry.frameRect($0, width: width, height: height)
                    } ?? box
                    let padded = FrameRect(mask.raw.insetBy(dx: -2, dy: -2).integral)
                    return SensitiveFinding(category: match.category, box: padded, confidence: match.confidence)
                } : []
                return Line(text: candidate.string, box: box, quad: quad, confidence: Double(candidate.confidence), findings: findings)
            }
        } catch is CancellationError {
            throw .cancelled
        } catch {
            if Task.isCancelled { throw .cancelled }
            throw .recognition(.imageUnreadable)
        }
    }
}

// MARK: - Structured document recognition, macOS 26+ (AI-01, ADR-0007)

struct VisionDocumentEngine: RecognitionEngine {
    let descriptor: EngineDescriptor

    func recognize(_ image: PixelImage, hints: [LanguageCode], detail: AnalysisDetail) async throws(AppError) -> RawRecognition {
        guard #available(macOS 26.0, *) else { throw .engine(.unavailableOnThisOS(descriptor.id, minimum: OSVersion(26))) }
        return try await DocumentRecognizer.recognize(image, hints: hints, engine: descriptor.id)
    }
}

@available(macOS 26.0, *)
enum DocumentRecognizer {
    static func recognize(_ image: PixelImage, hints: [LanguageCode], engine: EngineID) async throws(AppError) -> RawRecognition {
        let width = Double(image.cgImage.width), height = Double(image.cgImage.height)
        func rect(_ region: NormalizedRect) -> FrameRect {
            let b = region.cgRect
            return VisionGeometry.frameRect(b, width: width, height: height)
        }
        do {
            var request = RecognizeDocumentsRequest()
            if !hints.isEmpty { request.textRecognitionOptions.recognitionLanguages = hints.map { Locale.Language(identifier: $0.bcp47) } }
            let documents = try await request.perform(on: image.cgImage)
            var observations: [RawObservation] = []
            var blocks: [RawBlock] = []
            for observation in documents {
                let document = observation.document
                for table in document.tables {
                    let tableIndex = blocks.count
                    let rows = table.rows.count
                    let columns = table.rows.map(\.count).max() ?? 0
                    blocks.append(RawBlock(kind: .table(rows: rows, columns: columns), box: rect(table.boundingRegion.boundingBox)))
                    for (r, row) in table.rows.enumerated() {
                        for (c, cell) in row.enumerated() {
                            let text = cell.content.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }
                            let ref = TableCellRef(
                                table: BlockID(), row: r, column: c, rowSpan: cell.rowRange.count, columnSpan: cell.columnRange.count,
                                isHeader: r == 0)
                            observations.append(
                                RawObservation(
                                    text: text, box: rect(cell.content.boundingRegion.boundingBox), kind: .tableCell(ref), blockIndex: tableIndex))
                        }
                    }
                }
                for list in document.lists {
                    let listIndex = blocks.count
                    blocks.append(RawBlock(kind: .list(ordered: false), box: rect(list.boundingRegion.boundingBox)))
                    for item in list.items {
                        observations.append(RawObservation(
                            text: item.itemString, box: rect(item.content.boundingRegion.boundingBox),
                            kind: .listItem(level: 1, marker: item.markerString), blockIndex: listIndex
                        ))
                    }
                }
                let covered = observations.map(\.box)
                for paragraph in document.paragraphs {
                    let box = rect(paragraph.boundingRegion.boundingBox)
                    guard !covered.contains(where: { $0.intersection(box).map { $0.area > box.area * 0.6 } ?? false }) else { continue }
                    let index = blocks.count
                    blocks.append(RawBlock(kind: .paragraph, box: box))
                    observations.append(RawObservation(text: paragraph.transcript, box: box, blockIndex: index, style: SegmentStyleHint(fontSize: nil)))
                }
            }
            return RawRecognition(observations: observations, blocks: blocks, languages: hints, sent: .nothing)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .recognition(.imageUnreadable)
        }
    }
}

// MARK: - Barcodes / QR (AI-02)

public struct VisionCodeDetector: CodeDetecting {
    public init() {}
    public func codes(in image: PixelImage) async -> [DetectedCode] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        let w = Double(image.cgImage.width), h = Double(image.cgImage.height)
        return (request.results ?? []).compactMap { observation in
            guard let payload = observation.payloadStringValue else { return nil }
            let b = observation.boundingBox
            return DetectedCode(payload: payload, box: VisionGeometry.frameRect(b, width: w, height: h))
        }
    }
}

// MARK: - Privacy guard detector (ADR-0010 §4): Vision OCR + local rules, nothing leaves the device

public struct LocalSensitiveContentDetector: SensitiveContentDetecting {
    public init() {}

    public func detect(in image: PixelImage) async throws(AppError) -> [SensitiveFinding] {
        let lines = try await VisionOCR.lines(in: image.cgImage, hints: [], fast: false, engine: .visionText, detectSensitive: true)
        let ordered = lines.sorted { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }
        let text = ordered.map(\.text).joined(separator: "\n")
        let keyBlocks = SensitiveTextClassifier.matches(in: text)
            .filter { $0.category == .privateKey && text[$0.range].contains("\n") }
            .map { NSRange($0.range, in: text) }
        var offset = 0
        return ordered.flatMap { line -> [SensitiveFinding] in
            let range = NSRange(location: offset, length: line.text.utf16.count)
            offset += range.length + 1
            if keyBlocks.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                return [SensitiveFinding(category: .privateKey, box: FrameRect(line.box.raw.insetBy(dx: -2, dy: -2).integral), confidence: 0.99)]
            }
            return line.findings
        }
    }
}

// MARK: - Content blocks for smart selection (AI-03): local text-line clustering

public struct LocalContentBlockDetector: ContentBlockDetecting {
    public init() {}

    public func blocks(in frame: CapturedFrame) async throws(AppError) -> [SelectionCandidate] {
        let lines = try await VisionOCR.lines(in: frame.image.cgImage, hints: [], fast: true, engine: .visionText)
        let clusters = TextClustering.cluster(lines.map(\.box.raw))
        let scale = frame.pixelScale
        return clusters.compactMap { cluster in
            guard cluster.rect.width > 24, cluster.rect.height > 12 else { return nil }
            let padded = cluster.rect.insetBy(dx: -6 * scale, dy: -4 * scale)
            let quartz = QuartzRect(
                x: frame.display.frame.minX + padded.minX / scale, y: frame.display.frame.minY + padded.minY / scale,
                width: padded.width / scale, height: padded.height / scale
            )
            let score = min(1, 0.4 + Double(cluster.count) * 0.08)
            return SelectionCandidate(kind: cluster.count > 1 ? .paragraph : .paragraph, rect: quartz, score: score)
        }
    }
}

enum TextClustering {
    struct Cluster {
        var rect: CGRect
        var count: Int
    }

    /// Union of line boxes whose vertical gap is under one line height and that overlap horizontally.
    static func cluster(_ boxes: [CGRect]) -> [Cluster] {
        var clusters: [Cluster] = []
        for box in boxes.sorted(by: { $0.minY < $1.minY }) {
            let gap = box.height * 0.9
            if let index = clusters.firstIndex(where: { c in
                c.rect.insetBy(dx: -box.height, dy: -gap).intersects(box)
            }) {
                clusters[index].rect = clusters[index].rect.union(box)
                clusters[index].count += 1
            } else {
                clusters.append(Cluster(rect: box, count: 1))
            }
        }
        return clusters
    }
}

extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(Swift.max(self, low), high) }
}

/// JPEG for vision models, longest edge capped.
enum UploadImage {
    static func jpeg(_ image: CGImage, maxEdge: Int = 2000, quality: Double = 0.85) -> Data? {
        let longest = max(image.width, image.height)
        let factor = longest > maxEdge ? Double(maxEdge) / Double(longest) : 1
        let w = max(Int(Double(image.width) * factor), 1), h = max(Int(Double(image.height) * factor), 1)
        guard
            let context = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}


/// Vision's normalized, bottom-left coordinates → top-left frame pixels, in explicit Double math
/// (mixed CGFloat/Double operators are ambiguous on the Swift 6.2 compile floor).
enum VisionGeometry {
    static func frameRect(_ normalized: CGRect, width: Double, height: Double) -> FrameRect {
        let x = Double(normalized.minX), maxY = Double(normalized.maxY), w = Double(normalized.width), h = Double(normalized.height)
        return FrameRect(x: x * width, y: (1 - maxY) * height, width: w * width, height: h * height)
    }

    static func framePoint(_ normalized: CGPoint, width: Double, height: Double) -> CGPoint {
        CGPoint(x: Double(normalized.x) * width, y: (1 - Double(normalized.y)) * height)
    }
}
