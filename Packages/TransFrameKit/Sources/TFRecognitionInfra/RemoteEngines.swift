import CoreGraphics
import Foundation
import ImageIO
import os
import TFDomain
import TFNetworkInfra

public typealias SecretReader = @Sendable (CredentialRef) async throws(AppError) -> String?

// MARK: - Vision language models (OCR-07, OCR-08, OCR-11, AI-01)

struct VLMRecognitionEngine: RecognitionEngine {
    let descriptor: EngineDescriptor
    let client: LLMClient

    func recognize(_ image: PixelImage, hints: [LanguageCode], detail: AnalysisDetail) async throws(AppError) -> RawRecognition {
        guard let jpeg = UploadImage.jpeg(image.cgImage, maxEdge: descriptor.limits.maxImageEdge ?? 2000) else { throw .recognition(.imageUnreadable) }
        let system = detail == .structured ? VLMPrompt.structured : VLMPrompt.lines
        let hint = hints.isEmpty ? "" : " The main language is likely \(hints.map(\.bcp47).joined(separator: ", "))."
        let output = try await client.completeWithContinuation(
            system: system, messages: [LLMMessage(role: .user, text: "Extract the text from this image.\(hint)", image: jpeg)], maxTokens: 8192
        )
        var raw = VLMResponseParser.parse(output, width: Double(image.cgImage.width), height: Double(image.cgImage.height))
        raw.sent = .image
        return raw
    }
}

enum VLMPrompt {
    static let lines = """
    You are an OCR engine. Return only JSON: {"items":[{"text":"...","bbox":[x0,y0,x1,y1]}]} with one item per visual text line \
    in reading order. bbox uses a 0–1000 scale relative to the image width and height, origin at the top-left. \
    Copy text exactly; do not translate, summarize or add commentary.
    """

    static let structured = """
    You are a document structure OCR engine. Return only JSON: {"items":[{"text":"...","bbox":[x0,y0,x1,y1],"kind":"text|heading|list_item|table_cell|code|formula|handwriting|caption","table":0,"row":0,"col":0,"rowspan":1,"colspan":1,"header":false,"latex":"...","level":1}]} \
    in reading order. Use one item per paragraph, list item, table cell, code block or formula. bbox is on a 0–1000 scale, origin \
    top-left. For tables give each cell its table index, row and column. For formulas put LaTeX in "latex". Keep code whitespace. \
    Copy text exactly; never translate.
    """
}

/// Parses VLM JSON (tolerating fences) into raw observations in input-image pixels; empty when unparseable.
enum VLMResponseParser {
    static func parse(_ output: String, width: Double, height: Double) -> RawRecognition {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = text.range(of: "```") {
            text = String(text[fence.upperBound...])
            if let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
            if let end = text.range(of: "```", options: .backwards) { text = String(text[..<end.lowerBound]) }
        }
        if let start = text.firstIndex(of: "{") { text = String(text[start...]) }
        guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            // Plain-text fallback: lines without geometry spread over the image.
            let lines = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let step = height / Double(max(lines.count, 1))
            return RawRecognition(observations: lines.enumerated().map { index, line in
                RawObservation(text: line, box: FrameRect(x: 0, y: Double(index) * step, width: width, height: step))
            })
        }
        var blocks: [RawBlock] = []
        var tableBlocks: [Int: Int] = [:]
        var observations: [RawObservation] = []
        for item in items {
            guard let value = item["text"] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let bbox = (item["bbox"] as? [Double]) ?? (item["bbox"] as? [Int])?.map(Double.init) ?? [0, 0, 1000, 1000]
            guard bbox.count == 4 else { continue }
            let box = FrameRect(
                x: min(bbox[0], bbox[2]) / 1000 * width, y: min(bbox[1], bbox[3]) / 1000 * height,
                width: abs(bbox[2] - bbox[0]) / 1000 * width, height: abs(bbox[3] - bbox[1]) / 1000 * height
            )
            var kind = SegmentKind.text
            var blockIndex: Int?
            switch item["kind"] as? String {
            case "heading": kind = .heading(level: item["level"] as? Int ?? 1)
            case "list_item": kind = .listItem(level: item["level"] as? Int ?? 1, marker: nil)
            case "code": kind = .code(language: nil)
            case "formula": kind = .formula(latex: item["latex"] as? String)
            case "handwriting": kind = .handwriting
            case "caption": kind = .caption
            case "table_cell":
                let table = item["table"] as? Int ?? 0
                if tableBlocks[table] == nil {
                    tableBlocks[table] = blocks.count
                    blocks.append(RawBlock(kind: .table(rows: 0, columns: 0), box: box))
                }
                let index = tableBlocks[table]!
                blocks[index].box = blocks[index].box.union(box)
                blockIndex = index
                kind = .tableCell(TableCellRef(
                    table: BlockID(), row: item["row"] as? Int ?? 0, column: item["col"] as? Int ?? 0,
                    rowSpan: item["rowspan"] as? Int ?? 1, columnSpan: item["colspan"] as? Int ?? 1, isHeader: item["header"] as? Bool ?? false
                ))
            default: break
            }
            observations.append(RawObservation(text: value, box: box, kind: kind, blockIndex: blockIndex, style: SegmentStyleHint(fontSize: box.height * 0.8)))
        }
        // Table dimensions from the cells.
        for (_, index) in tableBlocks {
            let cells = observations.filter { $0.blockIndex == index }.compactMap(\.kind.tableCell)
            blocks[index].kind = .table(rows: (cells.map { $0.row + $0.rowSpan }.max() ?? 0), columns: (cells.map { $0.column + $0.columnSpan }.max() ?? 0))
        }
        return RawRecognition(observations: observations, blocks: blocks)
    }
}

// MARK: - PaddleOCR local (OCR-03, OCR-05, OCR-06, N-17) and cloud (OCR-04)

public struct PaddleInstallationService: PaddleInstallationChecking {
    public static let installCommand = "python3 -m pip install paddlepaddle paddleocr"
    public init() {}

    public func check(executablePath: String?) async -> PaddleInstallation {
        guard let path = PaddleLocator.executable(preferred: executablePath) else {
            return PaddleInstallation(isInstalled: false, version: nil, executablePath: nil, installCommand: Self.installCommand)
        }
        let version = try? await ProcessRunner.run(path, ["--version"], timeout: .seconds(20)).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init)
        return PaddleInstallation(isInstalled: true, version: version, executablePath: path, installCommand: Self.installCommand)
    }
}

enum PaddleLocator {
    static func executable(preferred: String?) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [preferred].compactMap { $0 } + [
            "/opt/homebrew/bin/paddleocr", "/usr/local/bin/paddleocr", "\(home)/.local/bin/paddleocr",
            "\(home)/miniconda3/bin/paddleocr", "\(home)/anaconda3/bin/paddleocr", "\(home)/Library/Python/3.12/bin/paddleocr",
            "\(home)/Library/Python/3.11/bin/paddleocr", "\(home)/Library/Python/3.13/bin/paddleocr",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

struct PaddleLocalEngine: RecognitionEngine {
    let descriptor: EngineDescriptor
    let settings: PaddleSettings

    func recognize(_ image: PixelImage, hints: [LanguageCode], detail: AnalysisDetail) async throws(AppError) -> RawRecognition {
        guard let executable = PaddleLocator.executable(preferred: settings.executablePath) else { throw .engine(.assetsMissing(descriptor.id)) }
        let directory = FileManager.default.temporaryDirectory.appending(path: "tf2-paddle-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.png")
        guard let png = PNG.data(image.cgImage), (try? png.write(to: input)) != nil else { throw .recognition(.imageUnreadable) }
        var arguments = ["ocr", "-i", input.path, "--save_path", directory.path, "--use_doc_orientation_classify", "False", "--use_doc_unwarping", "False"]
        if settings.mode == .fast {
            arguments += ["--text_detection_model_name", "PP-OCRv5_mobile_det", "--text_recognition_model_name", "PP-OCRv5_mobile_rec"]
        } else if let models = settings.modelDirectory, !models.isEmpty {
            arguments += ["--text_detection_model_dir", "\(models)/det", "--text_recognition_model_dir", "\(models)/rec"]
        }
        let result: ProcessRunner.Output
        do {
            result = try await ProcessRunner.run(executable, arguments, timeout: descriptor.limits.timeout)
        } catch let error as AppError {
            throw error
        } catch {
            throw .engine(.invalidResponse(descriptor.id, detail: "paddleocr failed"))
        }
        guard result.status == 0 else { throw .engine(.invalidResponse(descriptor.id, detail: "exit \(result.status)")) }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        guard let json = files.first(where: { $0.pathExtension == "json" }), let data = try? Data(contentsOf: json),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .engine(.invalidResponse(descriptor.id, detail: "no result file"))
        }
        return PaddleResultParser.parse(object["res"] as? [String: Any] ?? object)
    }
}

struct PaddleCloudEngine: RecognitionEngine {
    let descriptor: EngineDescriptor
    let endpoint: String
    let transport: any HTTPTransport
    let token: @Sendable () async throws(AppError) -> String?

    func recognize(_ image: PixelImage, hints: [LanguageCode], detail: AnalysisDetail) async throws(AppError) -> RawRecognition {
        guard let url = URL(string: endpoint), !endpoint.isEmpty, let token = try await token(), !token.isEmpty else { throw .engine(.notConfigured(descriptor.id)) }
        guard let jpeg = UploadImage.jpeg(image.cgImage, maxEdge: 4000) else { throw .recognition(.imageUnreadable) }
        let body: [String: Any] = ["file": jpeg.base64EncodedString(), "fileType": 1, "useDocOrientationClassify": false, "useDocUnwarping": false]
        let request = HTTPRequest(
            url: url, method: .post, headers: ["Content-Type": "application/json", "Authorization": "token \(token)"],
            body: try? JSONSerialization.data(withJSONObject: body), timeout: descriptor.limits.timeout
        )
        let response = try await transport.send(request, engine: descriptor.id)
        try HTTPStatusMapping.check(response, engine: descriptor.id)
        let json = try HTTPStatusMapping.json(response, engine: descriptor.id)
        let results = ((json["result"] as? [String: Any])?["ocrResults"] as? [[String: Any]]) ?? []
        var merged = RawRecognition(observations: [])
        for result in results {
            merged.observations += PaddleResultParser.parse(result["prunedResult"] as? [String: Any] ?? result).observations
        }
        merged.sent = .image
        return merged
    }
}

enum PaddleResultParser {
    static func parse(_ object: [String: Any]) -> RawRecognition {
        let texts = object["rec_texts"] as? [String] ?? []
        let scores = object["rec_scores"] as? [Double] ?? []
        let boxes = (object["rec_boxes"] as? [[Double]]) ?? (object["rec_boxes"] as? [[Int]])?.map { $0.map(Double.init) } ?? []
        let polys = (object["rec_polys"] as? [[[Double]]]) ?? (object["rec_polys"] as? [[[Int]]])?.map { $0.map { $0.map(Double.init) } } ?? []
        var observations: [RawObservation] = []
        for (index, text) in texts.enumerated() where !text.isEmpty {
            var box = FrameRect.zero
            if index < boxes.count, boxes[index].count == 4 {
                let b = boxes[index]
                box = FrameRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1])
            } else if index < polys.count {
                let xs = polys[index].compactMap(\.first), ys = polys[index].compactMap { $0.count > 1 ? $0[1] : nil }
                box = FrameRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
            }
            observations.append(RawObservation(text: text, box: box, confidence: index < scores.count ? scores[index] : nil, style: SegmentStyleHint(fontSize: box.height * 0.8)))
        }
        return RawRecognition(observations: observations)
    }
}

/// Runs a subprocess; cancelling the task terminates it (N-17).
enum ProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
    }

    static func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        environment["PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK"] = "True"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        let box = ProcessBox(process)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Output.self) { group in
                group.addTask {
                    try process.run()
                    let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
                    process.waitUntilExit()
                    return Output(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    box.terminate()
                    throw AppError.engine(.timedOut(.paddleLocal))
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } onCancel: {
            box.terminate()
        }
    }
}

/// Sendable handle to terminate a running process from a cancellation handler.
final class ProcessBox: Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { if process.isRunning { process.terminate() } }
}

enum PNG {
    static func data(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

// MARK: - Factory

public struct RecognitionEngineFactory: RecognitionEngineProviding {
    private let transport: any HTTPTransport
    private let secrets: SecretReader
    private let os: OSVersion

    public init(transport: any HTTPTransport, secrets: @escaping SecretReader, os: OSVersion = .current) {
        self.transport = transport
        self.secrets = secrets
        self.os = os
    }

    public func descriptors(for settings: SettingsSnapshot) -> [EngineDescriptor] {
        [EngineID.visionText, .visionDocument, .paddleLocal, .paddleCloud].map { descriptor($0, settings: settings) }
    }

    func descriptor(_ id: EngineID, settings: SettingsSnapshot, provider: AnalysisProvider? = nil) -> EngineDescriptor {
        switch id {
        case .visionText:
            return EngineDescriptor(id: id, roles: [.recognition], name: .localized("engine.name.vision.text"), locality: .onDevice,
                                    capabilities: [.boundingBoxes, .confidence], limits: EngineLimits(timeout: .seconds(30), maxConcurrent: 2), probe: .alwaysAvailable, configDigest: "vision.accurate")
        case .visionDocument:
            return EngineDescriptor(id: id, roles: [.recognition], name: .localized("engine.name.vision.document"), locality: .onDevice,
                                    capabilities: [.boundingBoxes, .structure], requirements: EngineRequirements(minimumOS: OSVersion(26)),
                                    limits: EngineLimits(timeout: .seconds(45), maxConcurrent: 1), probe: .alwaysAvailable, configDigest: "vision.document")
        case .paddleLocal:
            return EngineDescriptor(id: id, roles: [.recognition], name: .localized("engine.name.paddle.local"), locality: .onDevice,
                                    capabilities: [.boundingBoxes, .confidence], requirements: EngineRequirements(needsModelAssets: true),
                                    limits: EngineLimits(timeout: .seconds(120), maxConcurrent: 1), probe: .none, configDigest: "paddle.\(settings.recognition.paddle.mode.rawValue)")
        case .paddleCloud:
            let host = URL(string: settings.recognition.paddle.cloudEndpoint)?.host
            return EngineDescriptor(id: id, roles: [.recognition], name: .localized("engine.name.paddle.cloud"), locality: EngineLocality.classify(host: host),
                                    capabilities: [.boundingBoxes, .confidence], requirements: EngineRequirements(needsCredential: true, needsEndpoint: true),
                                    limits: EngineLimits(timeout: .seconds(60)), billing: .metered, probe: .none, configDigest: "paddle.cloud|\(host ?? "")")
        default:
            let provider = provider ?? .openAI
            let config = settings.recognition.config(for: provider)
            let locality = config?.locality ?? .cloud
            return EngineDescriptor(
                id: id, roles: [.recognition, .textGeneration], name: .localized("engine.name.\(id.raw)"), locality: locality,
                capabilities: [.boundingBoxes, .structure, .imageInput], requirements: EngineRequirements(needsCredential: locality != .onDevice, needsEndpoint: true),
                limits: EngineLimits(timeout: .seconds(120), maxImageEdge: 2000), billing: locality == .onDevice ? .free : .metered, probe: .freeEndpoint,
                configDigest: "vlm|\(provider.rawValue)|\(config?.host ?? "")|\(config?.model ?? "")|\(config?.apiMode.rawValue ?? "")"
            )
        }
    }

    public func engine(_ id: EngineID, settings: SettingsSnapshot) -> (any RecognitionEngine)? {
        let descriptor = descriptor(id, settings: settings)
        guard descriptor.requirements.isSupported(on: os) else { return nil }
        let secrets = secrets
        switch id {
        case .visionText: return VisionTextEngine(descriptor: descriptor)
        case .visionDocument: return VisionDocumentEngine(descriptor: descriptor)
        case .paddleLocal: return PaddleLocalEngine(descriptor: descriptor, settings: settings.recognition.paddle)
        case .paddleCloud:
            let credential = settings.recognition.paddle.cloudCredential
            return PaddleCloudEngine(descriptor: descriptor, endpoint: settings.recognition.paddle.cloudEndpoint, transport: transport) { () throws(AppError) in
                try await secrets(credential)
            }
        default: return nil
        }
    }

    public func analysisEngine(_ provider: AnalysisProvider, settings: SettingsSnapshot) -> (any RecognitionEngine)? {
        switch provider {
        case .vision: return engine(.visionText, settings: settings)
        case .visionDocument: return engine(.visionDocument, settings: settings)
        case .paddle: return engine(.paddleLocal, settings: settings)
        case .openAI, .claude, .gemini, .local:
            guard let config = settings.recognition.config(for: provider) else { return nil }
            let id = provider.engineID
            let wire: LLMWire = provider == .claude ? .anthropic : (provider == .gemini ? .gemini : (config.apiMode == .responses ? .openAIResponses : .openAIChat))
            let secrets = secrets
            let credential = config.credential
            let client = LLMClient(wire: wire, endpoint: config.endpoint, model: config.model, engine: id, transport: transport) { () throws(AppError) in
                try await secrets(credential)
            }
            return VLMRecognitionEngine(descriptor: descriptor(id, settings: settings, provider: provider), client: client)
        }
    }
}
