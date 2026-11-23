import AppKit
import Observation
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization
import TFWorkspaceUI

/// State for the engine, prompt, AI, glossary and image-host pages (SET-05, SET-09, OCR-06/07/14, TRN-03…13, AI-08, N-08).
@MainActor
@Observable
public final class EnginesModel {
    @ObservationIgnored let deps: SettingsDependencies
    var health: [EngineID: EngineHealth] = [:]
    var secrets: [CredentialRef: String] = [:]
    var analysisModels: [AnalysisProvider: [String]] = [:]
    var models: [EngineID: [String]] = [:]
    var testResult: [String: String] = [:]
    var paddle: PaddleInstallation?
    var glossaryEntries: [GlossaryEntry] = []
    var generators: [EngineDescriptor] = []
    var locked = false

    init(dependencies: SettingsDependencies) { deps = dependencies }

    var settings: any SettingsProviding { deps.settings }
    var l10n: Localizer { deps.localizer }
    var bindings: SettingsBindings { SettingsBindings(settings: deps.settings) }

    var descriptors: [EngineDescriptor] { deps.catalog?.translationEngines(settings: settings.snapshot) ?? [] }

    func load() async {
        locked = !deps.unlocker.isUnlocked
        await refreshHealth(force: false)
        paddle = await deps.catalog?.paddleStatus(settings: settings.snapshot)
        generators = await deps.catalog?.generators(settings: settings.snapshot) ?? []
        glossaryEntries = (try? await deps.glossary?.entries()) ?? []
    }

    func refreshHealth(force: Bool) async {
        guard let catalog = deps.catalog else { return }
        let snapshot = settings.snapshot
        for descriptor in descriptors {
            health[descriptor.id] = .checking
            health[descriptor.id] = await catalog.health(of: descriptor.id, settings: snapshot, forceRefresh: force)
        }
    }

    func unlock() async {
        locked = !(await deps.unlocker.unlock(reason: l10n[.unlockReason]))
    }

    // MARK: Secrets (never stored in settings)

    func secretBinding(_ ref: CredentialRef) -> Binding<String> {
        Binding(get: { self.secrets[ref] ?? "" }, set: { self.secrets[ref] = $0 })
    }

    func saveSecret(_ ref: CredentialRef) {
        let value = secrets[ref] ?? ""
        let credentials = deps.credentials, errors = deps.errors
        Task {
            do { try await credentials.store(value, for: ref); await refreshHealth(force: true) } catch { errors.present(error, near: nil) }
        }
    }

    func loadSecret(_ ref: CredentialRef) {
        guard secrets[ref] == nil else { return }
        let credentials = deps.credentials
        Task { secrets[ref] = (try? await credentials.secret(for: ref)) ?? "" }
    }

    // MARK: Engine configuration

    func config(_ id: EngineID) -> EngineConfig { settings.engines.config(for: id) }

    func update(_ id: EngineID, _ body: (inout EngineConfig) -> Void) {
        if let index = settings.engines.compatibleInstances.firstIndex(where: { $0.engineID == id }) {
            body(&settings.engines.compatibleInstances[index].config)
        } else {
            var config = config(id)
            body(&config)
            settings.engines.builtins[id] = config
        }
    }

    func moveInChain(_ id: EngineID, by offset: Int) {
        guard let index = settings.engines.orderedChain.firstIndex(of: id) else { return }
        let target = index + offset
        guard settings.engines.orderedChain.indices.contains(target) else { return }
        settings.engines.orderedChain.swapAt(index, target)
    }

    func toggleInChain(_ id: EngineID) {
        if let index = settings.engines.orderedChain.firstIndex(of: id) {
            guard settings.engines.orderedChain.count > 1 else { return }
            settings.engines.orderedChain.remove(at: index)
        } else if settings.engines.orderedChain.count < EngineRouting.maxOrdered {
            settings.engines.orderedChain.append(id)
        }
    }

    func toggleInCompare(_ id: EngineID) {
        if let index = settings.engines.compareGroup.firstIndex(of: id) {
            guard settings.engines.compareGroup.count > EngineRouting.compareRange.lowerBound else { return }
            settings.engines.compareGroup.remove(at: index)
        } else if settings.engines.compareGroup.count < EngineRouting.compareRange.upperBound {
            settings.engines.compareGroup.append(id)
        }
    }

    func addInstance() {
        guard settings.engines.compatibleInstances.count < CompatibleInstance.maximumCount else { return }
        settings.engines.compatibleInstances.append(CompatibleInstance(name: l10n.string(.enginesInstanceName, settings.engines.compatibleInstances.count + 1)))
    }

    func removeInstance(_ id: UUID) {
        let engineID = EngineID.compatible(id)
        settings.engines.compatibleInstances.removeAll { $0.id == id }
        settings.engines.orderedChain.removeAll { $0 == engineID }
        if settings.engines.orderedChain.isEmpty { settings.engines.orderedChain = [.appleTranslation] }
        settings.engines.compareGroup.removeAll { $0 == engineID }
        let credentials = deps.credentials
        Task { try? await credentials.remove(.engine(engineID)) }
    }

    func fetchModels(_ id: EngineID, endpoint: String, credential: CredentialRef?) {
        guard let catalog = deps.catalog else { return }
        let errors = deps.errors
        Task {
            do { models[id] = try await catalog.models(for: id, endpoint: endpoint, credential: credential) } catch { errors.present(error, near: nil) }
        }
    }

    func test(_ id: EngineID) {
        guard let catalog = deps.catalog else { return }
        testResult[id.raw] = l10n[.enginesTesting]
        let snapshot = settings.snapshot
        Task {
            do { testResult[id.raw] = "✓ " + (try await catalog.testTranslation(id, settings: snapshot)) } catch {
                testResult[id.raw] = "✗ " + LocalizedErrorText(AppError.from(error), localizer: l10n).title
            }
        }
    }

    func fetchAnalysisModels(_ provider: AnalysisProvider) {
        guard let catalog = deps.catalog, let config = settings.recognition.config(for: provider) else { return }
        let key = "analysisModels-" + provider.rawValue
        testResult[key] = l10n[.enginesTesting]
        Task {
            do {
                let models = try await catalog.models(for: provider.engineID, endpoint: config.endpoint, credential: config.credential)
                guard settings.recognition.config(for: provider)?.endpoint == config.endpoint else { return }
                analysisModels[provider] = models
                testResult[key] = models.isEmpty ? l10n[.errorEngineInvalidResponseTitle] : nil
            } catch {
                guard settings.recognition.config(for: provider)?.endpoint == config.endpoint else { return }
                testResult[key] = LocalizedErrorText(AppError.from(error), localizer: l10n).title
            }
        }
    }

    func updateAnalysis(_ provider: AnalysisProvider, _ update: (inout ModelEndpointConfig) -> Void) {
        guard var config = settings.recognition.config(for: provider) else { return }
        let endpoint = config.endpoint
        update(&config)
        settings.recognition.analysisConfigs[provider] = config
        if config.endpoint != endpoint {
            analysisModels[provider] = nil
            testResult["analysisModels-" + provider.rawValue] = nil
        }
        testResult["analysis"] = nil
    }

    func testAnalysis() {
        guard let catalog = deps.catalog else { return }
        let provider = settings.recognition.analysisProvider, snapshot = settings.snapshot
        testResult["analysis"] = l10n[.enginesTesting]
        Task {
            do {
                let result = try await catalog.testAnalysis(provider, settings: snapshot)
                if settings.recognition == snapshot.recognition { testResult["analysis"] = "✓ " + result }
            } catch {
                if settings.recognition == snapshot.recognition {
                    testResult["analysis"] = "✗ " + LocalizedErrorText(AppError.from(error), localizer: l10n).title
                }
            }
        }
    }

    func testUpload() {
        guard let catalog = deps.catalog else { return }
        let snapshot = settings.snapshot
        testResult["upload"] = l10n[.enginesTesting]
        Task {
            do { testResult["upload"] = "✓ " + (try await catalog.testUpload(settings: snapshot)).url.absoluteString } catch {
                testResult["upload"] = "✗ " + LocalizedErrorText(AppError.from(error), localizer: l10n).title
            }
        }
    }

    func copy(_ text: String) {
        guard let pasteboard = deps.pasteboard else { return }
        Task { try? await pasteboard.write(.string(text)) }
    }

    // MARK: Glossary

    func saveGlossary(_ entry: GlossaryEntry) {
        guard let glossary = deps.glossary else { return }
        Task {
            do {
                try await glossary.save(entry)
                glossaryEntries = try await glossary.entries()
            } catch {
                deps.errors.present(error, near: nil)
            }
        }
    }

    func removeGlossary(_ id: GlossaryEntryID) {
        guard let glossary = deps.glossary else { return }
        Task {
            do {
                try await glossary.remove(id)
                glossaryEntries = try await glossary.entries()
            } catch {
                deps.errors.present(error, near: nil)
            }
        }
    }
}
