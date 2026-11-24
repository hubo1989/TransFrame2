import AppKit
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization
import TFWorkspaceUI

struct SettingsRootView: View {
    @Bindable var model: SettingsViewModel
    @Environment(Localizer.self) private var l10n

    var body: some View {
        NavigationSplitView {
            List(model.pages, id: \.self, selection: $model.selection) { page in
                Label(l10n.string(rawKey: "settings.page.\(page.rawValue)"), systemImage: page.systemImage)
                    .tag(page)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: DS.Size.settingsSidebar)
        } detail: {
            detail
                .navigationTitle(l10n.string(rawKey: "settings.page.\(model.selection.rawValue)"))
        }
        .task { await model.refreshPermissions() }
        .onReceive(NotificationCenterPublisher.didBecomeActive) { _ in
            Task { await model.refreshPermissions() }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .general: GeneralPage(model: model)
        case .shortcuts: ShortcutsPage(model: model)
        case .annotations: AnnotationsPage(model: model)
        case .languages: LanguagesPage(model: model)
        case .engines: EnginesPage(model: model.engines)
        case .prompts: PromptsPage(model: model.engines)
        case .privacy: PrivacyPage(model: model)
        case .ai: AIPage(model: model.engines)
        case .glossary: GlossaryPage(model: model.engines)
        case .imageHost: ImageHostPage(model: model.engines)
        }
    }
}

enum NotificationCenterPublisher {
    static var didBecomeActive: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    }
}

extension SettingsPage {
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .engines: "cpu"
        case .prompts: "text.bubble"
        case .languages: "globe"
        case .shortcuts: "command"
        case .annotations: "pencil.tip.crop.circle"
        case .privacy: "hand.raised"
        case .ai: "sparkles"
        case .glossary: "character.book.closed"
        case .imageHost: "icloud.and.arrow.up"
        }
    }
}

// MARK: - General (SET-02, SET-03, SET-04, SET-08, N-07, N-10)

struct GeneralPage: View {
    @Bindable var model: SettingsViewModel
    @Environment(Localizer.self) private var l10n

    var body: some View {
        let settings = model.bindings
        let current = model.settings
        Form {
            Section(l10n[.settingsGeneralPermissions]) {
                ForEach(PermissionKind.allCases, id: \.self) { kind in
                    PermissionRow(kind: kind, granted: model.permissionStates[kind] ?? false) { model.grant(kind) }
                }
            }
            Section(l10n[.settingsGeneralSaving]) {
                LabeledContent(l10n[.settingsGeneralSaveLocation]) {
                    HStack(spacing: DS.Space.s2) {
                        Text(model.saveLocation.path(percentEncoded: false))
                            .font(DS.Typography.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button(l10n[.settingsGeneralChoose]) { model.chooseSaveLocation() }
                        IconButton(l10n[.settingsGeneralReveal], systemImage: "folder") { model.revealSaveLocation() }
                        IconButton(l10n[.settingsGeneralResetLocation], systemImage: "arrow.counterclockwise") { model.resetSaveLocation() }
                    }
                }
                Picker(l10n[.settingsGeneralFormat], selection: settings.export.format) {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Text(verbatim: format.rawValue.uppercased()).tag(format)
                    }
                }
                if current.export.format.isLossy {
                    QualitySlider(
                        title: l10n[.settingsGeneralQuality],
                        value: current.export.format == .jpeg ? settings.export.jpegQuality : settings.export.heicQuality
                    )
                }
                Toggle(l10n[.settingsGeneralSound], isOn: settings.general.playsSound)
            }
            Section(l10n[.settingsGeneralInterface]) {
                Picker(l10n[.settingsGeneralLanguage], selection: Binding(
                    get: { model.settings.general.interfaceLanguage ?? "" },
                    set: { model.setInterfaceLanguage($0.isEmpty ? nil : $0) }
                )) {
                    Text(l10n[.settingsGeneralLanguageSystem]).tag("")
                    Divider()
                    ForEach(Localizer.supportedLanguages, id: \.self) { code in
                        Text(verbatim: Localizer.nativeName(code)).tag(code)
                    }
                }
                Text(l10n[.settingsGeneralLanguageNote]).font(DS.Typography.caption).foregroundStyle(.secondary)
            }
            Section(l10n[.settingsGeneralOverlay]) {
                Picker(l10n[.settingsGeneralOverlayMode], selection: Binding(
                    get: { current.presentation.automaticOverlay ? OverlayChoice.automatic : OverlayChoice(current.presentation.overlayMode) },
                    set: { choice in
                        current.presentation.automaticOverlay = choice == .automatic
                        if let mode = choice.mode { current.presentation.overlayMode = mode }
                    }
                )) {
                    Text(l10n[.settingsGeneralOverlayAutomatic]).tag(OverlayChoice.automatic)
                    Text(l10n[.overlayBelowOriginal]).tag(OverlayChoice.below)
                    Text(l10n[.overlayReplaceOriginal]).tag(OverlayChoice.replace)
                }
                Text(l10n[.settingsGeneralOverlayNote]).font(DS.Typography.caption).foregroundStyle(.secondary)
            }
            Section(l10n[.settingsGeneralHistory]) {
                Stepper(value: settings.history.limit, in: HistorySettings.limitRange, step: 50) {
                    LabeledContent(l10n[.settingsGeneralHistoryLimit]) {
                        Text(current.history.limit, format: .number).font(DS.Typography.mono)
                    }
                }
            }
            Section {
                Button(l10n[.settingsGeneralResetAll], role: .destructive) { model.confirmingReset = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(l10n[.settingsGeneralResetConfirmTitle], isPresented: $model.confirmingReset) {
            Button(l10n[.settingsGeneralResetAll], role: .destructive) { model.resetAll() }
            Button(l10n[.actionCancel], role: .cancel) {}
        } message: {
            Text(l10n[.settingsGeneralResetConfirmMessage])
        }
    }
}

/// Bindings into settings segments through the existential (`@Bindable` needs a concrete type).
@MainActor
@dynamicMemberLookup
struct SettingsBindings {
    let settings: any SettingsProviding
    subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<any SettingsProviding, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }
}

struct QualitySlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: 0.3...1, step: 0.05).frame(maxWidth: 220)
                Text(value, format: .percent.precision(.fractionLength(0))).font(DS.Typography.mono).frame(width: 48, alignment: .trailing)
            }
        }
    }
}

struct PermissionRow: View {
    let kind: PermissionKind
    let granted: Bool
    let action: () -> Void
    @Environment(Localizer.self) private var l10n

    var body: some View {
        LabeledContent {
            if granted {
                StatusDot(.ok, label: l10n[.permissionGranted])
            } else {
                HStack {
                    StatusDot(.warn, label: l10n[.permissionNotGranted])
                    Button(l10n[.permissionGrant], action: action)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                Text(kind == .screenRecording ? l10n[.permissionScreenRecording] : l10n[.permissionAccessibility])
                Text(kind == .screenRecording ? l10n[.permissionScreenRecordingDetail] : l10n[.permissionAccessibilityDetail])
                    .font(DS.Typography.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Shortcuts (SET-06)

struct ShortcutsPage: View {
    @Bindable var model: SettingsViewModel
    @Environment(Localizer.self) private var l10n

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    VStack(alignment: .trailing, spacing: DS.Space.s1) {
                        LabeledContent(l10n.string(rawKey: "hotkey.\(action.rawValue)")) {
                            ShortcutRecorder(
                                current: model.settings.shortcuts[action].displayString,
                                prompt: l10n[.settingsShortcutsRecording],
                                recordLabel: l10n[.settingsShortcutsRecord],
                                resetLabel: l10n[.settingsShortcutsReset],
                                isRecording: model.recording == action,
                                onStart: { model.startRecording(action) },
                                onRecord: { model.record($0, for: action) },
                                onCancel: { model.cancelRecording() },
                                onReset: { model.resetShortcut(action) }
                            )
                        }
                        if let message = model.shortcutMessage, message.action == action {
                            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                                .font(DS.Typography.caption)
                                .foregroundStyle(.secondary)
                                .symbolRenderingMode(.multicolor)
                        }
                    }
                }
            } footer: {
                Text(l10n[.settingsShortcutsFooter]).font(DS.Typography.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Annotations (SET-07, ANN-15)

struct AnnotationsPage: View {
    @Bindable var model: SettingsViewModel
    @Environment(Localizer.self) private var l10n

    var body: some View {
        let settings = model.bindings
        let current = model.settings
        Form {
            Section(l10n[.settingsAnnotationsDefaults]) {
                LabeledContent(l10n[.settingsAnnotationsColor]) {
                    HStack(spacing: DS.Space.s1) {
                        ForEach(AnnotationPalette.all, id: \.name) { entry in
                            ColorSwatch(
                                color: Color(rgba: entry.color), name: l10n.string(rawKey: "color.\(entry.name)"),
                                isSelected: current.annotationDefaults.strokeColor == entry.color
                            ) { current.annotationDefaults.strokeColor = entry.color }
                        }
                    }
                }
                LabeledSlider(
                    title: l10n[.settingsAnnotationsLineWidth], value: settings.annotationDefaults.lineWidth,
                    range: AnnotationDefaults.lineWidthRange, step: 1
                )
                LabeledSlider(
                    title: l10n[.settingsAnnotationsFontSize], value: settings.annotationDefaults.fontSize,
                    range: AnnotationDefaults.fontSizeRange, step: 1
                )
                LabeledSlider(
                    title: l10n[.settingsAnnotationsMosaic], value: settings.annotationDefaults.mosaicBlockSize,
                    range: AnnotationDefaults.mosaicRange, step: 1
                )
                Toggle(l10n[.settingsAnnotationsFill], isOn: settings.annotationDefaults.isFilled)
            }
        }
        .formStyle(.grouped)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step).frame(maxWidth: 220)
                Text(value, format: .number.precision(.fractionLength(0))).font(DS.Typography.mono).frame(width: 36, alignment: .trailing)
            }
        }
    }
}

// MARK: - Languages (TRN-14, TXT-10)

struct LanguagesPage: View {
    @Bindable var model: SettingsViewModel
    @Environment(Localizer.self) private var l10n

    var body: some View {
        let settings = model.bindings
        Form {
            Section(l10n[.settingsLanguagesCapture]) {
                SourceLanguagePicker(title: l10n[.settingsLanguagesSource], selection: settings.languages.capture.source)
                TargetLanguagePicker(title: l10n[.settingsLanguagesTarget], selection: settings.languages.capture.target)
            }
            Section(l10n[.settingsLanguagesInsert]) {
                SourceLanguagePicker(title: l10n[.settingsLanguagesSource], selection: settings.languages.insert.source)
                TargetLanguagePicker(title: l10n[.settingsLanguagesTarget], selection: settings.languages.insert.target)
            }
        }
        .formStyle(.grouped)
    }
}

struct SourceLanguagePicker: View {
    let title: String
    @Binding var selection: LanguageCode?
    @Environment(Localizer.self) private var l10n

    var body: some View {
        Picker(title, selection: $selection) {
            Text(l10n[.languageAuto]).tag(LanguageCode?.none)
            Divider()
            ForEach(TranslationLanguages.all, id: \.self) { code in
                Text(verbatim: l10n.languageName(code.bcp47)).tag(LanguageCode?.some(code))
            }
        }
    }
}

struct TargetLanguagePicker: View {
    let title: String
    @Binding var selection: TargetLanguage
    @Environment(Localizer.self) private var l10n

    var body: some View {
        Picker(title, selection: $selection) {
            Text(l10n[.languageFollowSystem]).tag(TargetLanguage.followSystem)
            Divider()
            ForEach(TranslationLanguages.all, id: \.self) { code in
                Text(verbatim: l10n.languageName(code.bcp47)).tag(TargetLanguage.specific(code))
            }
        }
    }
}

/// Settings picker values for the default on-image mode.
enum OverlayChoice: Hashable {
    case automatic, below, replace

    init(_ mode: OverlayMode) { self = mode == .replaceOriginal ? .replace : .below }

    var mode: OverlayMode? {
        switch self {
        case .automatic: nil
        case .below: .belowOriginal
        case .replace: .replaceOriginal
        }
    }
}
