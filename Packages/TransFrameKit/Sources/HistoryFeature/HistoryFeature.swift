import AppKit
import Observation
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization
import TFWorkspaceUI
import UniformTypeIdentifiers

@MainActor
public protocol HistoryCoordinating: AnyObject {
    func showHistory(_ query: HistoryQuery?)
    func showColorHistory()
}

/// Translation history (HIS-*, N-05…N-07, AI-05) and color history (COL-*) windows.
@MainActor
public final class HistoryCoordinator: HistoryCoordinating {
    private let workflow: any HistoryWorkflow
    private let colors: any ColorPickWorkflow
    private let settings: any SettingsProviding
    private let localizer: Localizer
    private let errors: any ErrorPresenting
    private let pasteboard: any PasteboardAccessing
    private var historyWindow: NSWindow?
    private var colorWindow: NSWindow?

    public init(workflow: any HistoryWorkflow, colors: any ColorPickWorkflow, settings: any SettingsProviding, localizer: Localizer,
                errors: any ErrorPresenting, pasteboard: any PasteboardAccessing) {
        self.workflow = workflow
        self.colors = colors
        self.settings = settings
        self.localizer = localizer
        self.errors = errors
        self.pasteboard = pasteboard
    }

    public func showHistory(_ query: HistoryQuery?) {
        if let historyWindow { WindowFactory.present(historyWindow); return }
        let model = HistoryModel(workflow: workflow, settings: settings, errors: errors, pasteboard: pasteboard, localizer: localizer)
        if let query { model.query = query }
        let window = WindowFactory.makeWindow(title: localizer[.menuHistory], content: HistoryView(model: model).localized(localizer),
                                              size: NSSize(width: 720, height: 560), minSize: NSSize(width: 520, height: 360), autosaveName: "TF2.HistoryWindow")
        historyWindow = window
        WindowFactory.present(window)
    }

    public func showColorHistory() {
        if let colorWindow { WindowFactory.present(colorWindow); return }
        let model = ColorHistoryModel(workflow: workflow, colors: colors, settings: settings, errors: errors, localizer: localizer)
        let window = WindowFactory.makeWindow(title: localizer[.menuColorHistory], content: ColorHistoryView(model: model).localized(localizer),
                                              size: NSSize(width: 560, height: 440), minSize: NSSize(width: 420, height: 320), autosaveName: "TF2.ColorHistoryWindow")
        colorWindow = window
        WindowFactory.present(window)
    }
}

// MARK: - Translation history

@MainActor
@Observable
final class HistoryModel {
    var query = HistoryQuery()
    var entries: [HistoryEntry] = []
    var hasMore = false
    var semantic = false
    var semanticFallback = false
    var confirmingClear = false
    var notice: HistoryStoreNotice?
    @ObservationIgnored let workflow: any HistoryWorkflow
    @ObservationIgnored let settings: any SettingsProviding
    @ObservationIgnored let errors: any ErrorPresenting
    @ObservationIgnored let pasteboard: any PasteboardAccessing
    @ObservationIgnored let l10n: Localizer
    @ObservationIgnored private var task: Task<Void, Never>?

    init(workflow: any HistoryWorkflow, settings: any SettingsProviding, errors: any ErrorPresenting, pasteboard: any PasteboardAccessing, localizer: Localizer) {
        self.workflow = workflow
        self.settings = settings
        self.errors = errors
        self.pasteboard = pasteboard
        l10n = localizer
    }

    func reload() {
        task?.cancel()
        var q = query
        q.offset = 0
        task = Task {
            do {
                let page = semantic && !q.text.isEmpty ? try await workflow.search(semantic: q.text, query: q, limit: 100) : try await workflow.page(q)
                entries = page.entries
                hasMore = page.hasMore
                semanticFallback = page.semanticFallback
                notice = await workflow.notice()
            } catch { errors.present(error, near: nil) }
        }
    }

    /// Infinite scroll (HIS-08).
    func loadMore() {
        guard hasMore, !semantic else { return }
        var q = query
        q.offset = entries.count
        Task {
            guard let page = try? await workflow.page(q) else { return }
            entries += page.entries
            hasMore = page.hasMore
        }
    }

    func toggleFavorite(_ entry: HistoryEntry) {
        Task {
            try? await workflow.setFavorite(entry.id, !entry.isFavorite)
            reload()
        }
    }

    func delete(_ entry: HistoryEntry) {
        Task {
            try? await workflow.remove([entry.id])
            reload()
        }
    }

    func clearAll() {
        Task {
            try? await workflow.clear(.kinds(Set(HistoryKind.translationKinds)))
            reload()
        }
    }

    func copy(_ text: String) {
        let message = l10n[.feedbackCopied]
        Task {
            try? await pasteboard.write(.string(text))
            errors.toast(ToastModel(message: message), near: nil)
        }
    }

    /// JSON / CSV / Markdown export of the current filter (N-06).
    func export(_ format: HistoryExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "TransFrame History.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var q = query
        q.offset = 0
        q.limit = .max
        Task {
            do {
                try await workflow.export(q, as: format, to: url)
                errors.toast(ToastModel(message: l10n.string(.feedbackSaved, url.lastPathComponent)), near: nil)
            } catch { errors.present(error, near: nil) }
        }
    }
}

struct HistoryView: View {
    @Bindable var model: HistoryModel
    @Environment(Localizer.self) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s2) {
                Picker(l10n[.historyFilter], selection: Binding(
                    get: { model.query.kinds.count == 1 ? model.query.kinds.first : nil },
                    set: { model.query.kinds = $0.map { [$0] } ?? Set(HistoryKind.translationKinds); model.reload() }
                )) {
                    Text(l10n[.historyAll]).tag(HistoryKind?.none)
                    ForEach(HistoryKind.translationKinds, id: \.self) { kind in Text(l10n.string(rawKey: "history.kind.\(kind.rawValue)")).tag(HistoryKind?.some(kind)) }
                }
                .frame(maxWidth: 200)
                Toggle(l10n[.historyFavorites], isOn: Binding(get: { model.query.favoritesOnly }, set: { model.query.favoritesOnly = $0; model.reload() }))
                Toggle(l10n[.historySemantic], isOn: Binding(get: { model.semantic }, set: { model.semantic = $0; model.reload() }))
                    .disabled(!model.settings.ai.semanticSearch)
                Spacer()
                Menu(l10n[.historyExport]) {
                    ForEach(HistoryExportFormat.allCases, id: \.self) { format in Button(format.rawValue.uppercased()) { model.export(format) } }
                }
                .fixedSize()
                Button(l10n[.historyClear], role: .destructive) { model.confirmingClear = true }
            }
            .padding(DS.Space.s3)
            if let notice = model.notice {
                BannerView(title: l10n[.errorPersistenceStoreUnavailableTitle], message: notice.movedAsidePath, actionTitle: nil, action: nil,
                           dismissTitle: l10n[.actionClose]) { model.notice = nil }
                    .padding(.horizontal, DS.Space.s3)
            }
            if model.semantic, model.semanticFallback {
                Text(l10n[.historySemanticFallback]).font(DS.Typography.caption).foregroundStyle(.secondary).padding(.horizontal, DS.Space.s3)
            }
            if model.entries.isEmpty {
                EmptyStateView(
                    model.query.text.isEmpty ? l10n[.historyEmptyTitle] : l10n[.historyNoResults],
                    message: l10n[.historyEmptyMessage], systemImage: "clock.arrow.circlepath",
                    actionTitle: model.query.text.isEmpty ? nil : l10n[.historyClearSearch]
                ) { model.query.text = ""; model.reload() }
            } else {
                List {
                    ForEach(model.entries) { entry in
                        HistoryRow(entry: entry, model: model)
                            .onAppear { if entry.id == model.entries.last?.id { model.loadMore() } }
                    }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: Binding(get: { model.query.text }, set: { model.query.text = $0; model.reload() }), prompt: l10n[.historySearch])
        .task { model.reload() }
        .confirmationDialog(l10n[.historyClearConfirm], isPresented: $model.confirmingClear) {
            Button(l10n[.historyClear], role: .destructive) { model.clearAll() }
            Button(l10n[.actionCancel], role: .cancel) {}
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let model: HistoryModel
    @Environment(Localizer.self) private var l10n

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s3) {
            if let data = entry.thumbnail, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: DS.Size.thumbnail, height: DS.Size.thumbnail)
                    .clipShape(.rect(cornerRadius: DS.Radius.s)).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                Text(entry.source).font(DS.Typography.secondary).foregroundStyle(.secondary).lineLimit(2)
                Text(entry.result).font(DS.Typography.body).lineLimit(3)
                HStack(spacing: DS.Space.s2) {
                    Text(l10n.string(rawKey: "history.kind.\(entry.kind.rawValue)"))
                    if let from = entry.from, let to = entry.to { Text(verbatim: "\(from.bcp47) → \(to.bcp47)") }
                    Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute())
                }
                .font(DS.Typography.micro).foregroundStyle(.tertiary)
            }
            Spacer()
            IconButton(entry.isFavorite ? l10n[.historyUnfavorite] : l10n[.historyFavorite], systemImage: entry.isFavorite ? "star.fill" : "star",
                       isActive: entry.isFavorite) { model.toggleFavorite(entry) }
        }
        .contextMenu {
            Button(l10n[.historyCopyResult]) { model.copy(entry.result) }
            Button(l10n[.historyCopySource]) { model.copy(entry.source) }
            Button(l10n[.historyCopyBoth]) { model.copy(entry.source + "\n\n" + entry.result) }
            Divider()
            Button(l10n[.actionDelete], role: .destructive) { model.delete(entry) }
        }
    }
}

// MARK: - Color history (COL-03…COL-12)

@MainActor
@Observable
final class ColorHistoryModel {
    var search = ""
    var favoritesOnly = false
    var entries: [HistoryEntry] = []
    var format: ColorCopyFormat = .hex
    var confirmingClear = false
    @ObservationIgnored let workflow: any HistoryWorkflow
    @ObservationIgnored let colors: any ColorPickWorkflow
    @ObservationIgnored let settings: any SettingsProviding
    @ObservationIgnored let errors: any ErrorPresenting
    @ObservationIgnored let l10n: Localizer

    init(workflow: any HistoryWorkflow, colors: any ColorPickWorkflow, settings: any SettingsProviding, errors: any ErrorPresenting, localizer: Localizer) {
        self.workflow = workflow
        self.colors = colors
        self.settings = settings
        self.errors = errors
        l10n = localizer
    }

    func reload() {
        var q = HistoryQuery.colors
        q.text = search
        q.favoritesOnly = favoritesOnly
        Task { entries = (try? await workflow.page(q).entries) ?? [] }
    }

    func copy(_ entry: HistoryEntry, as format: ColorCopyFormat? = nil) {
        guard let color = RGBA(hex: entry.result) else { return }
        let format = format ?? self.format
        Task {
            try? await colors.copy(color, format: format)
            errors.toast(ToastModel(message: l10n.string(.feedbackColorCopied, format.string(for: color))), near: nil)
        }
    }

    func toggleFavorite(_ entry: HistoryEntry) { Task { try? await workflow.setFavorite(entry.id, !entry.isFavorite); reload() } }
    func delete(_ entry: HistoryEntry) { Task { try? await workflow.remove([entry.id]); reload() } }
    func clearAll() { Task { try? await workflow.clear(.kinds([.color])); reload() } }
}

struct ColorHistoryView: View {
    @Bindable var model: ColorHistoryModel
    @Environment(Localizer.self) private var l10n
    @AppStorage("TF2.colorCopyFormat") private var storedFormat = ColorCopyFormat.hex.rawValue

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(l10n[.colorFormat], selection: Binding(get: { ColorCopyFormat(rawValue: storedFormat) ?? .hex }, set: { storedFormat = $0.rawValue; model.format = $0 })) {
                    Text(verbatim: "HEX").tag(ColorCopyFormat.hex)
                    Text(verbatim: "RGB").tag(ColorCopyFormat.rgb)
                }
                .pickerStyle(.segmented).frame(maxWidth: 160)
                Toggle(l10n[.historyFavorites], isOn: Binding(get: { model.favoritesOnly }, set: { model.favoritesOnly = $0; model.reload() }))
                Spacer()
                Button(l10n[.colorClear], role: .destructive) { model.confirmingClear = true }.disabled(model.entries.isEmpty)
            }
            .padding(DS.Space.s3)
            if model.entries.isEmpty {
                EmptyStateView(l10n[.colorEmptyTitle], message: l10n[.colorEmptyMessage], systemImage: "eyedropper")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: DS.Size.gridSwatch + DS.Space.s4))], spacing: DS.Space.s3) {
                        ForEach(model.entries) { entry in ColorCell(entry: entry, model: model) }
                    }
                    .padding(DS.Space.s3)
                }
            }
        }
        .searchable(text: Binding(get: { model.search }, set: { model.search = $0; model.reload() }), prompt: l10n[.colorSearch])
        .onExitCommand { model.search = ""; model.reload() }
        .task { model.format = ColorCopyFormat(rawValue: storedFormat) ?? .hex; model.reload() }
        .confirmationDialog(l10n[.colorClearConfirm], isPresented: $model.confirmingClear) {
            Button(l10n[.colorClear], role: .destructive) { model.clearAll() }
            Button(l10n[.actionCancel], role: .cancel) {}
        }
    }
}

private struct ColorCell: View {
    let entry: HistoryEntry
    let model: ColorHistoryModel
    @Environment(Localizer.self) private var l10n

    var body: some View {
        Button { model.copy(entry) } label: {
            VStack(spacing: DS.Space.s1) {
                RoundedRectangle(cornerRadius: DS.Radius.m)
                    .fill(Color(rgba: RGBA(hex: entry.result) ?? .black))
                    .frame(width: DS.Size.gridSwatch, height: DS.Size.gridSwatch)
                    .overlay(alignment: .topTrailing) { if entry.isFavorite { Image(systemName: "star.fill").font(DS.Typography.micro).padding(2) } }
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.m).strokeBorder(DS.Palette.separator))
                Text(verbatim: entry.result).font(DS.Typography.monoCaption)
            }
        }
        .buttonStyle(IconButtonStyle())
        .accessibilityLabel(entry.result)
        .contextMenu {
            Button(l10n[.colorCopyHex]) { model.copy(entry, as: .hex) }
            Button(l10n[.colorCopyRgb]) { model.copy(entry, as: .rgb) }
            Button(entry.isFavorite ? l10n[.historyUnfavorite] : l10n[.historyFavorite]) { model.toggleFavorite(entry) }
            Divider()
            Button(l10n[.actionDelete], role: .destructive) { model.delete(entry) }
        }
    }
}
