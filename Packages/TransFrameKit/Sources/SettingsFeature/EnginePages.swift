import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization
import TFWorkspaceUI

// MARK: - Engines (SET-05, SET-09, TRN-03…TRN-12, OCR-06/07/14, N-11)

struct EnginesPage: View {
    @Bindable var model: EnginesModel
    @Environment(Localizer.self) private var l10n

    var body: some View {
        let s = model.bindings
        let current = model.settings
        Form {
            if model.locked {
                Section {
                    HStack {
                        Label(l10n[.enginesLocked], systemImage: "lock.fill")
                        Spacer()
                        Button(l10n[.enginesUnlock]) { Task { await model.unlock() } }
                    }
                }
            }
            Section(l10n[.enginesRouting]) {
                Picker(l10n[.enginesMode], selection: s.engines.mode) {
                    Text(l10n[.enginesModeOrdered]).tag(TranslationMode.ordered)
                    Text(l10n[.enginesModeCompare]).tag(TranslationMode.compare)
                }
                .pickerStyle(.segmented)
                if current.engines.mode == .ordered {
                    ForEach(Array(current.engines.orderedChain.enumerated()), id: \.element) { index, id in
                        HStack {
                            Text(verbatim: "\(index + 1).").font(DS.Typography.mono).foregroundStyle(.secondary)
                            Text(EngineNames.name(id, localizer: l10n, instances: current.engines.compatibleInstances))
                            Spacer()
                            IconButton(l10n[.enginesMoveUp], systemImage: "chevron.up") { model.moveInChain(id, by: -1) }.disabled(index == 0)
                            IconButton(l10n[.enginesMoveDown], systemImage: "chevron.down") { model.moveInChain(id, by: 1) }
                                .disabled(index == current.engines.orderedChain.count - 1)
                            IconButton(l10n[.enginesRemove], systemImage: "minus.circle") { model.toggleInChain(id) }
                                .disabled(current.engines.orderedChain.count == 1)
                        }
                    }
                    Menu(l10n[.enginesAddToChain]) {
                        ForEach(model.descriptors.filter { !current.engines.orderedChain.contains($0.id) }) { d in
                            Button(EngineNames.name(d, localizer: l10n)) { model.toggleInChain(d.id) }
                        }
                    }
                    .disabled(current.engines.orderedChain.count >= EngineRouting.maxOrdered)
                } else {
                    ForEach(model.descriptors) { d in
                        Toggle(EngineNames.name(d, localizer: l10n), isOn: Binding(
                            get: { current.engines.compareGroup.contains(d.id) }, set: { _ in model.toggleInCompare(d.id) }
                        ))
                    }
                    Text(l10n[.enginesCompareHint]).font(DS.Typography.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(model.descriptors) { descriptor in EngineCard(model: model, descriptor: descriptor) }
                Button(l10n[.enginesAddInstance], systemImage: "plus") { model.addInstance() }
                    .disabled(current.engines.compatibleInstances.count >= CompatibleInstance.maximumCount)
            } header: {
                HStack {
                    Text(l10n[.enginesTranslation])
                    Spacer()
                    Button(l10n[.enginesRefresh]) { Task { await model.refreshHealth(force: true) } }.controlSize(.small)
                }
            }
            RecognitionSection(model: model)
        }
        .formStyle(.grouped)
        .task { await model.load() }
    }
}

private struct EngineCard: View {
    @Bindable var model: EnginesModel
    let descriptor: EngineDescriptor
    @Environment(Localizer.self) private var l10n
    @State private var expanded = false

    var body: some View {
        let id = descriptor.id
        let config = model.config(id)
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                Toggle(l10n[.enginesEnabled], isOn: Binding(get: { config.isEnabled }, set: { v in model.update(id) { $0.isEnabled = v } }))
                if let uuid = id.compatibleInstanceID, let instance = model.settings.engines.compatibleInstances.first(where: { $0.id == uuid }) {
                    TextField(l10n[.enginesInstanceNameLabel], text: Binding(get: { instance.name }, set: { name in
                        if let index = model.settings.engines.compatibleInstances.firstIndex(where: { $0.id == uuid }) {
                            model.settings.engines.compatibleInstances[index].name = name
                        }
                    }))
                }
                if id == .openAICompatible {
                    Picker(l10n[.enginesPreset], selection: Binding(get: { config.preset ?? .custom }, set: { preset in
                        model.update(id) { $0.preset = preset; if preset != .custom { $0.endpoint = preset.defaultEndpoint } }
                    })) {
                        Text(verbatim: "OpenAI").tag(OpenAIPreset.openAI)
                        Text(verbatim: "Ollama").tag(OpenAIPreset.ollama)
                        Text(l10n[.enginesPresetCustom]).tag(OpenAIPreset.custom)
                    }
                }
                if descriptor.requirements.needsEndpoint || id == .deepl || id == .google || id == .baidu {
                    TextField(l10n[.enginesEndpoint], text: Binding(get: { config.endpoint }, set: { v in model.update(id) { $0.endpoint = v } }))
                        .textFieldStyle(.roundedBorder).font(DS.Typography.mono)
                }
                if descriptor.isLanguageModel {
                    HStack {
                        TextField(l10n[.enginesModel], text: Binding(get: { config.model }, set: { v in model.update(id) { $0.model = v } }))
                            .textFieldStyle(.roundedBorder).font(DS.Typography.mono)
                        if model.fetchingModels.contains(id) {
                            ProgressView().controlSize(.small)
                        } else {
                            IconButton(l10n[.enginesFetchModelsAction], systemImage: "arrow.clockwise") {
                                model.fetchModels(id, endpoint: config.endpoint, credential: .engine(id))
                            }
                        }
                        if let names = model.models[id], !names.isEmpty {
                            Menu(l10n[.enginesModelsChoose]) {
                                ForEach(names, id: \.self) { name in Button(name) { model.useModel(name, for: id) } }
                            }
                            .fixedSize()
                        }
                    }
                    if let status = model.testResult["models-" + id.raw] {
                        Text(status).font(DS.Typography.caption).foregroundStyle(.secondary)
                    }
                    if id != .claude, id != .gemini {
                        Picker(l10n[.enginesApiMode], selection: Binding(get: { config.apiMode }, set: { v in model.update(id) { $0.apiMode = v } })) {
                            Text(verbatim: "Chat Completions").tag(OpenAIAPIMode.chat)
                            Text(verbatim: "Responses").tag(OpenAIAPIMode.responses)
                        }
                    }
                }
                if id == .baidu {
                    TextField(
                        l10n[.enginesAppId],
                        text: Binding(get: { config.options["appID"] ?? "" }, set: { v in model.update(id) { $0.options["appID"] = v } })
                    )
                        .textFieldStyle(.roundedBorder)
                }
                if descriptor.requirements.needsCredential || id == .mtran || descriptor.isLanguageModel {
                    HStack {
                        SecretField(l10n[.enginesApiKey], text: model.secretBinding(.engine(id)), showLabel: l10n[.actionShow], hideLabel: l10n[.actionHide])
                        Button(l10n[.actionSave]) { model.saveSecret(.engine(id)) }
                    }
                    .onAppear { model.loadSecret(.engine(id)) }
                }
                if descriptor.isLanguageModel, let names = model.models[id], !names.isEmpty {
                    SpeedTestSection(model: model, id: id, names: names, current: config.model)
                }
                HStack {
                    Button(l10n[.enginesTest]) { model.test(id) }
                    if let result = model.testResult[id.raw] { Text(result).font(DS.Typography.caption).foregroundStyle(.secondary).lineLimit(2) }
                    Spacer()
                    if let uuid = id.compatibleInstanceID {
                        Button(l10n[.enginesRemoveInstance], role: .destructive) { model.removeInstance(uuid) }
                    }
                }
            }
            .padding(.vertical, DS.Space.s1)
        } label: {
            HStack {
                Text(EngineNames.name(descriptor, localizer: l10n))
                Spacer()
                HealthDot(health: model.health[id])
            }
        }
        .onChange(of: expanded) { _, isOpen in
            // Load the model list as soon as a language-model card opens (the Menu itself cannot trigger a fetch).
            if isOpen, descriptor.isLanguageModel, model.models[descriptor.id] == nil, !model.config(descriptor.id).endpoint.isEmpty {
                model.fetchModels(descriptor.id, endpoint: model.config(descriptor.id).endpoint, credential: .engine(descriptor.id))
            }
        }
    }
}

/// Measures every candidate model with the same three-sentence translation and lists them fastest first.
private struct SpeedTestSection: View {
    @Bindable var model: EnginesModel
    let id: EngineID
    let names: [String]
    let current: String
    @Environment(Localizer.self) private var l10n
    @State private var filter = ""

    static let cap = 30

    private var matching: [String] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let candidates = Array(matching.prefix(Self.cap))
        let ranked = ModelSpeedResult.ranked(model.speedResults[id] ?? [])
        let fastest = ranked.first { $0.duration != nil }?.model
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Divider()
            HStack(spacing: DS.Space.s2) {
                Text(l10n[.enginesSpeedTest]).font(DS.Typography.section)
                Spacer()
                TextField(l10n[.enginesSpeedFilter], text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .disabled(model.isSpeedTesting(id))
                if model.isSpeedTesting(id) {
                    ProgressView().controlSize(.small)
                    if let progress = model.speedProgress[id] {
                        Text(l10n.string(.enginesSpeedProgress, progress.done, progress.total)).font(DS.Typography.caption).monospacedDigit()
                    }
                    Button(l10n[.actionCancel]) { model.cancelSpeedTest(id) }
                } else {
                    Button(l10n.string(.enginesSpeedRun, candidates.count)) { model.runSpeedTest(id, models: candidates) }
                        .disabled(candidates.isEmpty)
                }
            }
            Text(l10n[.enginesSpeedHint]).font(DS.Typography.caption).foregroundStyle(.secondary)
            if matching.count > Self.cap {
                Text(l10n.string(.enginesSpeedCapped, Self.cap)).font(DS.Typography.caption).foregroundStyle(.secondary)
            }
            ForEach(ranked) { result in
                SpeedRow(result: result, isFastest: result.model == fastest, isCurrent: result.model == current) {
                    model.useModel(result.model, for: id)
                }
            }
        }
    }
}

private struct SpeedRow: View {
    let result: ModelSpeedResult
    let isFastest: Bool
    let isCurrent: Bool
    let use: () -> Void
    @Environment(Localizer.self) private var l10n

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
            Image(systemName: isFastest ? "bolt.fill" : (result.duration == nil ? "xmark.circle" : "circle"))
                .foregroundStyle(isFastest ? DS.Palette.accent : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: result.model).font(DS.Typography.mono).lineLimit(1)
                if case .success(_, let sample) = result.outcome {
                    Text(verbatim: sample).font(DS.Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(detail).font(DS.Typography.caption).monospacedDigit().foregroundStyle(result.duration == nil ? .secondary : .primary)
            if isCurrent {
                Text(l10n[.enginesSpeedCurrent]).font(DS.Typography.caption).foregroundStyle(.secondary)
            } else {
                Button(l10n[.enginesSpeedUse], action: use).controlSize(.small).disabled(result.duration == nil)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch result.outcome {
        case .success(let duration, _):
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            return (isFastest ? l10n[.enginesSpeedFastest] + " · " : "") + l10n.string(.enginesSpeedSeconds, seconds)
        case .failure(let error):
            return LocalizedErrorText(error, localizer: l10n).title
        }
    }
}

struct HealthDot: View {
    let health: EngineHealth?
    @Environment(Localizer.self) private var l10n

    var body: some View {
        switch health {
        case .available?: StatusDot(.ok, label: l10n[.healthAvailable])
        case .failing(let reason)?: StatusDot(.error, label: l10n[.healthFailing], detail: l10n.string(rawKey: "error.\(reason).title"))
        case .unconfigured?: StatusDot(.warn, label: l10n[.healthUnconfigured])
        case .checking?: StatusDot(.busy, label: l10n[.healthChecking])
        case .unverified?, nil: StatusDot(.neutral, label: l10n[.healthUnverified])
        }
    }
}

private struct RecognitionSection: View {
    @Bindable var model: EnginesModel
    @Environment(Localizer.self) private var l10n

    var body: some View {
        let s = model.bindings
        let current = model.settings
        Section(l10n[.enginesRecognition]) {
            Picker(l10n[.enginesOcrEngine], selection: s.recognition.ocrEngine) {
                Text(l10n.string(rawKey: "engine.name.vision.text")).tag(EngineID.visionText)
                Text(l10n.string(rawKey: "engine.name.paddle.local")).tag(EngineID.paddleLocal)
                Text(l10n.string(rawKey: "engine.name.paddle.cloud")).tag(EngineID.paddleCloud)
            }
            Picker(l10n[.enginesAnalysisProvider], selection: s.recognition.analysisProvider) {
                ForEach(AnalysisProvider.allCases, id: \.self) { provider in
                    Text(l10n.string(rawKey: "analysis.\(provider.rawValue)")).tag(provider)
                }
            }
            if let config = current.recognition.config(for: current.recognition.analysisProvider), current.recognition.analysisProvider.isLanguageModel {
                let provider = current.recognition.analysisProvider
                TextField(
                    l10n[.enginesEndpoint],
                    text: Binding(get: { config.endpoint }, set: { value in model.updateAnalysis(provider) { $0.endpoint = value } })
                )
                    .textFieldStyle(.roundedBorder).font(DS.Typography.mono)
                TextField(l10n[.enginesModel], text: Binding(get: { config.model }, set: { value in model.updateAnalysis(provider) { $0.model = value } }))
                    .textFieldStyle(.roundedBorder).font(DS.Typography.mono)
                HStack {
                    Button(l10n[.enginesFetchModels]) { model.fetchAnalysisModels(provider) }
                    if let names = model.analysisModels[provider], !names.isEmpty {
                        Menu(l10n[.enginesModel]) {
                            ForEach(names, id: \.self) { name in Button(name) { model.updateAnalysis(provider) { $0.model = name } } }
                        }
                    }
                    if let message = model.testResult["analysisModels-" + provider.rawValue] {
                        Text(message).font(DS.Typography.caption).foregroundStyle(.secondary)
                    }
                }
                if provider == .openAI || provider == .local {
                    Picker(
                        l10n[.enginesApiMode],
                        selection: Binding(get: { config.apiMode }, set: { value in model.updateAnalysis(provider) { $0.apiMode = value } })
                    ) {
                        Text(verbatim: "Chat Completions").tag(OpenAIAPIMode.chat)
                        Text(verbatim: "Responses").tag(OpenAIAPIMode.responses)
                    }
                }
                HStack {
                    SecretField(l10n[.enginesApiKey], text: model.secretBinding(config.credential), showLabel: l10n[.actionShow], hideLabel: l10n[.actionHide])
                    Button(l10n[.actionSave]) { model.saveSecret(config.credential) }
                }
                .task(id: config.credential) { model.loadSecret(config.credential) }
            }
            HStack {
                Button(l10n[.enginesTest]) { model.testAnalysis() }
                if let result = model.testResult["analysis"] { Text(result).font(DS.Typography.caption).foregroundStyle(.secondary) }
            }
            if let paddle = model.paddle {
                LabeledContent(l10n[.enginesPaddleStatus]) {
                    if paddle.isInstalled {
                        StatusDot(.ok, label: paddle.version ?? l10n[.healthAvailable])
                    } else {
                        HStack {
                            Text(verbatim: paddle.installCommand).font(DS.Typography.monoCaption).textSelection(.enabled)
                            Button(l10n[.actionCopy]) { model.copy(paddle.installCommand) }
                        }
                    }
                }
                Picker(l10n[.enginesPaddleMode], selection: s.recognition.paddle.mode) {
                    Text(l10n[.enginesPaddleFast]).tag(PaddleMode.fast)
                    Text(l10n[.enginesPaddleAccurate]).tag(PaddleMode.accurate)
                }
                TextField(
                    l10n[.enginesPaddleModels],
                    text: Binding(
                        get: { current.recognition.paddle.modelDirectory ?? "" },
                        set: { model.settings.recognition.paddle.modelDirectory = $0.isEmpty ? nil : $0 })
                )
                    .textFieldStyle(.roundedBorder)
                TextField(l10n[.enginesPaddleCloud], text: s.recognition.paddle.cloudEndpoint).textFieldStyle(.roundedBorder)
                HStack {
                    SecretField(
                        l10n[.enginesApiKey], text: model.secretBinding(current.recognition.paddle.cloudCredential), showLabel: l10n[.actionShow],
                        hideLabel: l10n[.actionHide])
                    Button(l10n[.actionSave]) { model.saveSecret(current.recognition.paddle.cloudCredential) }
                }
            }
        }
    }
}

// MARK: - Prompts (TRN-13)

struct PromptsPage: View {
    @Bindable var model: EnginesModel
    @Environment(Localizer.self) private var l10n
    @State private var engine: EngineID = .openAICompatible
    @State private var scene: TranslationScene = .screenshot

    var body: some View {
        let key = PromptKey(engine: engine, scene: scene)
        Form {
            Picker(l10n[.promptsEngine], selection: $engine) {
                ForEach(model.descriptors.filter(\.isLanguageModel)) { d in Text(EngineNames.name(d, localizer: l10n)).tag(d.id) }
            }
            Picker(l10n[.promptsScene], selection: $scene) {
                ForEach(TranslationScene.allCases, id: \.self) { scene in Text(l10n.string(rawKey: "prompts.scene.\(scene.rawValue)")).tag(scene) }
            }
            TextEditor(text: Binding(
                get: { model.settings.prompts.template(for: engine, scene: scene) },
                set: { model.settings.prompts.custom[key] = $0 }
            ))
            .font(DS.Typography.mono)
            .frame(minHeight: 180)
            HStack {
                ForEach(PromptSettings.variables, id: \.self) { variable in
                    Button(variable) { model.settings.prompts.custom[key, default: PromptSettings.defaultTemplate] += " " + variable }.controlSize(.small)
                }
                Spacer()
                Button(l10n[.promptsReset]) { model.settings.prompts.custom[key] = nil }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy (ADR-0010)

struct PrivacyPage: View {
    @Bindable var model: SettingsViewModel
    @Environment(Localizer.self) private var l10n

    var body: some View {
        let s = model.bindings
        let current = model.settings
        Form {
            Section {
                Toggle(l10n[.privacyGuardEnabled], isOn: s.privacy.guardEnabled)
                Text(l10n[.privacyGuardNote]).font(DS.Typography.caption).foregroundStyle(.secondary)
            }
            Section(l10n[.privacyCategories]) {
                ForEach(SensitiveCategory.allCases, id: \.self) { category in
                    Toggle(l10n.string(rawKey: "sensitive.\(category.rawValue)"), isOn: Binding(
                        get: { current.privacy.redactedCategories.contains(category) },
                            set: { on in
                                if on {
                                    current.privacy.redactedCategories.insert(category)
                                } else {
                                    current.privacy.redactedCategories.remove(category)
                                }
                            }
                    ))
                }
                LabeledSlider(
                    title: l10n[.privacyThreshold],
                    value: Binding(get: { current.privacy.confidenceThreshold * 100 }, set: { current.privacy.confidenceThreshold = $0 / 100 }),
                    range: 50...99, step: 1)
                Toggle(l10n[.privacyLocalNetwork], isOn: s.privacy.guardLocalNetwork)
            }
            Section {
                Toggle(l10n[.privacySendContext], isOn: s.privacy.sendContext)
                Toggle(l10n[.privacyCloudDetection], isOn: s.privacy.cloudEnhancedDetection)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI (AI-05…AI-08)

struct AIPage: View {
    @Bindable var model: EnginesModel
    @Environment(Localizer.self) private var l10n

    var body: some View {
        let s = model.bindings
        Form {
            Section {
                Picker(l10n[.aiEngine], selection: s.ai.generationEngine) {
                    Text(l10n[.aiAutomatic]).tag(AIEngineChoice.automatic)
                    ForEach(model.generators) { d in Text(EngineNames.name(d, localizer: l10n)).tag(AIEngineChoice.engine(d.id)) }
                }
                if model.generators.isEmpty {
                    HStack {
                        Label(l10n[.aiUnavailable], systemImage: "exclamationmark.triangle").font(DS.Typography.caption)
                        Spacer()
                        Button(l10n[.actionOpenSettings]) { model.deps.router.route(.openSettings(.engines)) }
                    }
                }
                Picker(l10n[.aiTone], selection: s.ai.defaultTone) {
                    Text(l10n[.aiToneNone]).tag(ToneStyle?.none)
                    ForEach(ToneStyle.allCases, id: \.self) { tone in Text(l10n.string(rawKey: "tone.\(tone.rawValue)")).tag(ToneStyle?.some(tone)) }
                }
                .disabled(model.generators.isEmpty)
            }
            Section {
                Toggle(l10n[.aiAutoNaming], isOn: s.ai.autoNaming)
                Toggle(l10n[.aiAutoNamingCloud], isOn: s.ai.autoNamingAllowsCloud).disabled(!model.settings.ai.autoNaming)
                Toggle(l10n[.aiSemanticSearch], isOn: s.ai.semanticSearch)
                Toggle(l10n[.aiStructured], isOn: s.ai.structuredRecognition)
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
    }
}

// MARK: - Glossary (AI-04)

struct GlossaryPage: View {
    @Bindable var model: EnginesModel
    @Environment(Localizer.self) private var l10n
    @State private var source = ""
    @State private var target = ""
    @State private var language: LanguageCode = .simplifiedChinese

    var body: some View {
        Form {
            Section(l10n[.glossaryAdd]) {
                TextField(l10n[.glossarySource], text: $source)
                TextField(l10n[.glossaryTarget], text: $target)
                Picker(l10n[.settingsLanguagesTarget], selection: $language) {
                    ForEach(TranslationLanguages.all, id: \.self) { Text(l10n.languageName($0.bcp47)).tag($0) }
                }
                Button(l10n[.glossarySave]) {
                    model.saveGlossary(GlossaryEntry(source: source, target: target, to: language))
                    source = ""
                    target = ""
                }
                .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty || target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Section(l10n[.glossaryEntries]) {
                if model.glossaryEntries.isEmpty {
                    Text(l10n[.glossaryEmpty]).foregroundStyle(.secondary)
                }
                ForEach(model.glossaryEntries) { entry in
                    HStack {
                        Text(verbatim: "\(entry.source) → \(entry.target)")
                        Spacer()
                        Text(verbatim: entry.to.bcp47).font(DS.Typography.caption).foregroundStyle(.secondary)
                        IconButton(l10n[.actionDelete], systemImage: "trash", role: .destructive) { model.removeGlossary(entry.id) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
    }
}

// MARK: - Image hosting (N-08)

struct ImageHostPage: View {
    @Bindable var model: EnginesModel
    @Environment(Localizer.self) private var l10n

    private static let fields: [EngineID: [String]] = [
        .hostOSS: ["endpoint", "bucket", "accessKeyID", "domain", "pathPrefix"],
        .hostCOS: ["region", "bucket", "secretID", "domain", "pathPrefix"],
        .hostKodo: ["uploadHost", "bucket", "accessKey", "domain", "pathPrefix"],
    ]

    var body: some View {
        let current = model.settings
        Form {
            Picker(l10n[.imageHostProvider], selection: Binding(get: { current.imageHost.provider }, set: { current.imageHost.provider = $0 })) {
                Text(l10n[.imageHostNone]).tag(EngineID?.none)
                ForEach(ImageHostSettings.providers, id: \.self) { id in Text(l10n.string(rawKey: "engine.name.\(id.raw)")).tag(EngineID?.some(id)) }
            }
            if let provider = current.imageHost.provider {
                if provider == .hostPicGo {
                    TextField(l10n[.enginesEndpoint], text: Binding(get: { current.imageHost.picgoEndpoint }, set: { current.imageHost.picgoEndpoint = $0 }))
                        .textFieldStyle(.roundedBorder).font(DS.Typography.mono)
                } else {
                    ForEach(Self.fields[provider] ?? [], id: \.self) { field in
                        TextField(l10n.string(rawKey: "imageHost.field.\(field)"), text: Binding(
                            get: { current.imageHost.field(field, for: provider) }, set: { current.imageHost.setField(field, $0, for: provider) }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        SecretField(
                            l10n[.imageHostSecret], text: model.secretBinding(.imageHost(provider, "secret")), showLabel: l10n[.actionShow],
                            hideLabel: l10n[.actionHide])
                        Button(l10n[.actionSave]) { model.saveSecret(.imageHost(provider, "secret")) }
                    }
                    .onAppear { model.loadSecret(.imageHost(provider, "secret")) }
                }
                HStack {
                    Button(l10n[.imageHostTest]) { model.testUpload() }
                    if let result = model.testResult["upload"] {
                        Text(result).font(DS.Typography.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
