import Foundation
import TFDomain

/// Programmable translation engine: a script of outcomes per call, an optional delay, and a call log.
public final class FakeTranslationEngine: TranslationEngine, @unchecked Sendable {
    public enum Behavior: Sendable {
        case translate(@Sendable (String) -> String?)
        case fail(AppError)
        case delay(Duration, @Sendable (String) -> String?)
    }

    public let descriptor: EngineDescriptor
    public let behavior: Behavior
    public let calls = CallLog<TranslationBatch>()

    public init(_ id: EngineID, locality: EngineLocality = .onDevice, capabilities: Set<EngineCapability> = [.batch], behavior: Behavior) {
        descriptor = EngineDescriptor(id: id, roles: [.translation], name: .userDefined(id.raw), locality: locality, capabilities: capabilities,
                                      limits: EngineLimits(timeout: .seconds(5)), configDigest: id.raw)
        self.behavior = behavior
    }

    public func translate(_ batch: TranslationBatch) async throws(AppError) -> [TranslatedUnit] {
        calls.append(batch)
        switch behavior {
        case .fail(let error): throw error
        case .translate(let map):
            return batch.units.map { TranslatedUnit(id: $0.id, text: map($0.text)) }
        case .delay(let duration, let map):
            do { try await Task.sleep(for: duration) } catch { throw .cancelled }
            return batch.units.map { TranslatedUnit(id: $0.id, text: map($0.text)) }
        }
    }
}

public final class FakeTranslationEngines: TranslationEngineProviding, @unchecked Sendable {
    public let engines: [EngineID: FakeTranslationEngine]
    public let skipped: [EngineID: SkipReason]

    public init(_ engines: [FakeTranslationEngine], skipped: [EngineID: SkipReason] = [:]) {
        self.engines = Dictionary(uniqueKeysWithValues: engines.map { ($0.descriptor.id, $0) })
        self.skipped = skipped
    }

    public func descriptors(for settings: SettingsSnapshot) -> [EngineDescriptor] { engines.values.map(\.descriptor) }
    public func engine(_ id: EngineID, settings: SettingsSnapshot) -> (any TranslationEngine)? { engines[id] }
    public func skipReason(_ id: EngineID, settings: SettingsSnapshot) async -> SkipReason? { skipped[id] ?? (engines[id] == nil ? .unconfigured : nil) }
}

public struct FakeTextGenerator: TextGenerating {
    public let descriptor: EngineDescriptor
    public let calls = CallLog<GenerationRequest>()
    private let output: @Sendable (String) -> String

    public init(locality: EngineLocality = .cloud, output: @escaping @Sendable (String) -> String) {
        descriptor = EngineDescriptor(id: .openAICompatible, roles: [.textGeneration], name: .userDefined("Fake"), locality: locality)
        self.output = output
    }

    public func generate(_ request: GenerationRequest) async throws(AppError) -> String {
        calls.append(request)
        return output(request.input)
    }
}

public struct FakeSelectedText: SelectedTextCapturing, TextInserting {
    public let inserted = CallLog<String>()
    public let pasted = CallLog<String>()
    private let selection: CapturedSelection

    public init(text: String, target: TextInsertionTarget? = nil) {
        selection = CapturedSelection(text: text, target: target, anchor: nil, appName: nil)
    }

    public func captureSelection(bindTarget: Bool) async throws(AppError) -> CapturedSelection { selection }

    public func insert(_ text: String, into target: TextInsertionTarget) async throws(AppError) -> InsertionMethod {
        inserted.append(text)
        return .accessibility
    }

    public func pasteAnchored(_ text: String, processID: Int32?) async throws(AppError) { pasted.append(text) }
}

public struct FakeSensitiveDetector: SensitiveContentDetecting {
    public let calls = CallLog<PixelImage>()
    private let findings: [SensitiveFinding]

    public init(_ findings: [SensitiveFinding]) { self.findings = findings }

    public func detect(in image: PixelImage) async throws(AppError) -> [SensitiveFinding] {
        calls.append(image)
        return findings
    }
}

public actor FakeScrollCapturer: ScrollCapturing {
    private var pending: CheckedContinuation<PixelImage, Never>?
    private var started: CheckedContinuation<Void, Never>?

    public init() {}

    public func captureStrip(_ rect: QuartzRect, excluding: Set<WindowID>) async throws(AppError) -> PixelImage {
        await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    public func waitForStripRequest() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    public func deliver(_ image: PixelImage) {
        pending?.resume(returning: image)
        pending = nil
    }
}
