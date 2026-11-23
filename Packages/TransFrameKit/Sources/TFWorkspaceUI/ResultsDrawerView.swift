import AppKit
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization

/// The results drawer shared by the capture overlay and the editor.
public struct ResultsDrawerView: View {
    @Bindable var model: ResultsModel
    let onClose: (() -> Void)?
    @Environment(Localizer.self) private var l10n

    public init(model: ResultsModel, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            header
            if let error = model.error {
                let text = LocalizedErrorText(error, localizer: l10n)
                BannerView(title: text.title, message: text.suggestion, actionTitle: l10n[.actionRetry], action: {
                    model.tab == .translation ? model.translate(force: true) : model.recognize(force: true)
                }, dismissTitle: l10n[.actionClose], onDismiss: {})
            }
            if let stage = model.stage {
                HStack(spacing: DS.Space.s2) {
                    ProgressView().controlSize(.small)
                    Text(l10n.string(rawKey: "stage.\(stage.rawValue)")).font(DS.Typography.secondary).foregroundStyle(.secondary)
                    Spacer()
                    Button(l10n[.actionCancel]) { model.cancel() }.controlSize(.small)
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(DS.Palette.surfaceControl, in: .rect(cornerRadius: DS.Radius.m))
            if !model.actions.isEmpty { SmartActionsRow(model: model) }
            ProvenanceFooter(model: model)
        }
        .padding(DS.Space.s3)
        .frame(minWidth: 320, idealWidth: 380, minHeight: 240)
        .chrome(.floating, shape: .rounded(DS.Radius.l))
        .onExitCommand { onClose?() }
    }

    private var header: some View {
        HStack(spacing: DS.Space.s2) {
            Picker(l10n[.resultsTabs], selection: $model.tab) {
                Text(l10n[.resultsRecognition]).tag(ResultsTab.recognition)
                Text(l10n[.resultsTranslation]).tag(ResultsTab.translation)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            Spacer()
            if model.tab == .translation { TargetMenu(model: model) }
            IconButton(l10n[.resultsRerun], systemImage: "arrow.clockwise") {
                model.tab == .translation ? model.translate(force: true) : model.recognize(force: true)
            }
            .disabled(model.isRunning)
            Menu {
                Button(l10n[.resultsCopyAll]) { model.copy(.all) }
                Button(l10n[.resultsCopySource]) { model.copy(.source) }
                Button(l10n[.resultsCopyTranslation]) { model.copy(.translation) }.disabled(model.session?.translation == nil)
            } label: {
                Label(l10n[.resultsCopy], systemImage: "doc.on.doc").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(l10n[.resultsCopy])
            if let onClose { IconButton(l10n[.actionClose], systemImage: "xmark", action: onClose) }
        }
    }

    @ViewBuilder
    private var content: some View {
        let rows = VisualLines.group(model.session)
        if model.session?.analysis == nil, !model.isRunning {
            EmptyStateView(l10n[.resultsEmptyTitle], message: l10n[.resultsEmptyMessage], systemImage: "text.viewfinder")
        } else if let analysis = model.session?.analysis, analysis.segments.isEmpty {
            EmptyStateView(l10n[.resultsNoTextTitle], message: l10n[.resultsNoTextMessage], systemImage: "text.magnifyingglass")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.s2) {
                    if model.tab == .translation { EngineSwitcher(model: model) }
                    ForEach(rows) { row in
                        ResultRow(row: row, showsTranslation: model.tab == .translation, model: model)
                    }
                    ExcludedSection(model: model)
                }
                .padding(DS.Space.s2)
                .textSelection(.enabled)
            }
        }
    }
}

private struct ResultRow: View {
    let row: VisualLines.Row
    let showsTranslation: Bool
    let model: ResultsModel
    @Environment(Localizer.self) private var l10n
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
            Text(row.source).font(showsTranslation ? DS.Typography.secondary : DS.Typography.body)
                .foregroundStyle(showsTranslation ? .secondary : .primary)
            if showsTranslation {
                if let translation = row.translation {
                    Text(translation).font(DS.Typography.body)
                } else if let status = row.status {
                    Text(statusText(status)).font(DS.Typography.caption).foregroundStyle(.secondary).italic()
                }
                if model.correcting == row.id {
                    HStack {
                        TextField(l10n[.resultsCorrectPlaceholder], text: $draft).textFieldStyle(.roundedBorder)
                        Button(l10n[.resultsCorrectRemember]) { model.correct(row.id, translation: draft, remember: true) }
                        Button(l10n[.actionCancel]) { model.correcting = nil }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button(l10n[.resultsCopyLine]) { model.copyText([row.source, showsTranslation ? row.translation : nil].compactMap { $0 }.joined(separator: "\n")) }
            if showsTranslation, model.services.glossary != nil, row.translation != nil {
                Button(l10n[.resultsCorrect]) { draft = row.translation ?? ""; model.correcting = row.id }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func statusText(_ status: SegmentStatus) -> String {
        switch status {
        case .translated: ""
        case .sameLanguageSkipped: l10n[.segmentSameLanguage]
        case .keptOriginal: l10n[.segmentKeptOriginal]
        case .failed(.withheldByPrivacyGuard): l10n[.segmentWithheld]
        case .failed: l10n[.segmentFailed]
        case .cancelled: l10n[.segmentNotTranslated]
        }
    }
}

/// Compare mode: switch engines without re-translating, with durations and failures (EDT-11, TRN-08).
private struct EngineSwitcher: View {
    let model: ResultsModel
    @Environment(Localizer.self) private var l10n

    var body: some View {
        if let outcome = model.session?.translation, outcome.results.count > 1 || outcome.routing.isCompare {
            ScrollView(.horizontal) {
                HStack(spacing: DS.Space.s1) {
                    ForEach(outcome.results) { result in
                        Button { model.selectEngine(result.id) } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(EngineNames.name(result.id, localizer: l10n, instances: model.services.settings.engines.compatibleInstances))
                                    .font(DS.Typography.caption)
                                Text(detail(result)).font(DS.Typography.micro).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(outcome.effective == result.id ? .accentColor : nil)
                        .disabled(!result.succeeded)
                        .help(result.error.map { LocalizedErrorText($0, localizer: l10n).title } ?? detail(result))
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func detail(_ result: EngineResult) -> String {
        if result.skipped != nil { return l10n[.engineSkipped] }
        if let error = result.error { return LocalizedErrorText(error, localizer: l10n).title }
        let ms = Int(Double(result.duration.components.attoseconds) / 1e15 + Double(result.duration.components.seconds) * 1000)
        return result.fromCache ? l10n[.provenanceCached] : l10n.string(.engineDuration, ms)
    }
}

private struct TargetMenu: View {
    let model: ResultsModel
    @Environment(Localizer.self) private var l10n

    var body: some View {
        Menu {
            ForEach(TranslationLanguages.all, id: \.self) { code in
                Button(l10n.languageName(code.bcp47)) { model.translate(target: code) }
            }
        } label: {
            Label(l10n[.resultsTarget], systemImage: "globe").labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(l10n[.resultsTarget])
        Menu {
            Toggle(l10n[.resultsShowOnImage], isOn: Binding(get: { model.showsOverlay }, set: { model.setShowsOverlay($0) }))
            Picker(l10n[.resultsOverlayMode], selection: Binding(get: { model.session?.presentation.overlayMode ?? .belowOriginal }, set: { model.setOverlayMode($0) })) {
                Text(l10n[.overlayBelowOriginal]).tag(OverlayMode.belowOriginal)
                Text(l10n[.overlayReplaceOriginal]).tag(OverlayMode.replaceOriginal)
            }
        } label: {
            Label(l10n[.resultsDisplay], systemImage: "rectangle.on.rectangle").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(l10n[.resultsDisplay])
    }
}

private struct ExcludedSection: View {
    let model: ResultsModel
    @Environment(Localizer.self) private var l10n

    var body: some View {
        if let excluded = model.session?.analysis?.excluded, !excluded.isEmpty {
            DisclosureGroup(l10n.string(.resultsExcluded, excluded.count)) {
                ForEach(excluded, id: \.segment.id) { item in
                    HStack {
                        Text(item.segment.text).font(DS.Typography.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(l10n[.resultsRestore]) { model.restoreExcluded(item.segment.id) }.controlSize(.small)
                    }
                }
            }
            .font(DS.Typography.caption)
        }
    }
}

private struct SmartActionsRow: View {
    let model: ResultsModel
    @Environment(Localizer.self) private var l10n

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DS.Space.s1) {
                ForEach(model.actions) { action in
                    Button(title(action)) { model.perform(action) }.controlSize(.small).buttonStyle(.bordered)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func title(_ action: SmartAction) -> String {
        switch action.kind {
        case .copyTableAsMarkdown: l10n[.smartActionTableMarkdown]
        case .copyTableAsCSV: l10n[.smartActionTableCsv]
        case .copyFormulaAsLaTeX: l10n[.smartActionLatex]
        case .copyCode: l10n[.smartActionCode]
        case .openLink(let url): l10n.string(.smartActionOpenLink, url.host ?? url.absoluteString)
        case .composeEmail(let address): l10n.string(.smartActionEmail, address)
        case .openQRCode: l10n[.smartActionQrCode]
        case .addEvent: l10n[.smartActionEvent]
        }
    }
}

/// Engine, cache and outbound information (N-15, ADR-0010 §11).
private struct ProvenanceFooter: View {
    let model: ResultsModel
    @Environment(Localizer.self) private var l10n

    var body: some View {
        if let provenance = model.tab == .recognition ? model.session?.analysis?.provenance : model.session?.analysis?.provenance {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: provenance.locality == .cloud ? "icloud" : "desktopcomputer").accessibilityHidden(true)
                Text(text(provenance)).lineLimit(2)
                Spacer()
                if let privacy = model.session?.translation?.privacy ?? provenance.privacy, privacy.applied, !privacy.overriddenByUser {
                    Button(l10n[.privacyUndoAndResend]) { model.translate(force: true, overridePrivacy: true) }.controlSize(.small)
                }
            }
            .font(DS.Typography.micro)
            .foregroundStyle(.secondary)
        }
    }

    private func text(_ p: Provenance) -> String {
        var parts = [EngineNames.name(p.engine, localizer: l10n, instances: model.services.settings.engines.compatibleInstances)]
        if p.fromCache { parts.append(l10n[.provenanceCached]) }
        parts.append(l10n.string(rawKey: "provenance.sent.\(p.sent.rawValue)"))
        if let privacy = model.session?.translation?.privacy ?? p.privacy, privacy.applied {
            parts.append(privacy.overriddenByUser ? l10n[.privacyOverridden] : l10n.string(.privacyGuardApplied, privacy.redactedCount))
        }
        if let engine = model.session?.translation?.effective, engine != p.engine {
            parts.append("→ " + EngineNames.name(engine, localizer: l10n, instances: model.services.settings.engines.compatibleInstances))
        }
        return parts.joined(separator: " · ")
    }
}
