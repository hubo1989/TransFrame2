import AppKit
import Observation
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization
import TFWorkspaceUI

@MainActor
public protocol TextTranslationCoordinating: AnyObject {
    func translateSelection()
    func translateAndInsert()
}

/// Selected-text popup and translate-and-insert progress (TXT-01…TXT-16).
@MainActor
public final class TextTranslationCoordinator: TextTranslationCoordinating {
    private let workflow: any TextTranslationWorkflow
    private let settings: any SettingsProviding
    private let localizer: Localizer
    private let feedback: FeedbackCenter
    private let errors: any ErrorPresenting
    private let permissions: any PermissionChecking & PermissionGuiding
    private let pasteboard: any PasteboardAccessing
    private var busy = false
    private var lastTrigger = ContinuousClock.now - .seconds(1)
    private var popup: NSPanel?

    public init(
        workflow: any TextTranslationWorkflow, settings: any SettingsProviding, localizer: Localizer, feedback: FeedbackCenter,
        errors: any ErrorPresenting, permissions: any PermissionChecking & PermissionGuiding, pasteboard: any PasteboardAccessing
    ) {
        self.workflow = workflow
        self.settings = settings
        self.localizer = localizer
        self.feedback = feedback
        self.errors = errors
        self.permissions = permissions
        self.pasteboard = pasteboard
    }

    /// Ignores re-triggers while busy and within 0.3 s (TXT-14).
    private func begin() -> Bool {
        guard !busy, ContinuousClock.now - lastTrigger > .milliseconds(300) else { return false }
        lastTrigger = .now
        busy = true
        return true
    }

    private func ensureAccessibility() async -> Bool {
        if await permissions.isGranted(.accessibility) { return true }
        _ = await permissions.guide(.accessibility, from: nil)
        return false
    }

    public func translateSelection() {
        guard begin() else { return }
        feedback.showHUD(localizer[.textTranslating], near: nil)
        Task {
            defer { busy = false; feedback.hideHUD() }
            guard await ensureAccessibility() else { return }
            do {
                let result = try await workflow.translateSelection(settings: settings.snapshot)
                feedback.hideHUD()
                showPopup(result)
            } catch {
                errors.present(error, near: nil)
            }
        }
    }

    public func translateAndInsert() {
        guard begin() else { return }
        feedback.showHUD(localizer[.textCapturing], near: nil)
        let tone = settings.ai.defaultTone
        Task {
            defer { busy = false }
            guard await ensureAccessibility() else { feedback.hideHUD(); return }
            var anchor: CGRect?
            do {
                for try await progress in workflow.translateAndInsert(tone: tone, polishOnly: false, settings: settings.snapshot) {
                    switch progress {
                    case .capturing: feedback.showHUD(localizer[.textCapturing], near: anchor)
                    case .captured(let rect): anchor = rect.map(Self.cocoa)
                    case .translating: feedback.showHUD(localizer[.textTranslating], near: anchor)
                    case .inserting: feedback.showHUD(localizer[.textInserting], near: anchor)
                    case .inserted:
                        feedback.showHUD(localizer[.textInserted], systemImage: "checkmark.circle.fill", near: anchor)
                        try? await Task.sleep(for: .milliseconds(700))
                    case .copiedToClipboard(let error):
                        feedback.hideHUD()
                        let text = LocalizedErrorText(error, localizer: localizer)
                        errors.toast(ToastModel(.warning, message: "\(text.title) — \(localizer[.textCopiedInstead])"), near: nil)
                    }
                }
            } catch {
                errors.present(error, near: nil)
            }
            feedback.hideHUD()
        }
    }

    static func cocoa(_ rect: QuartzRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return QuartzConversion.cocoaRect(fromQuartz: rect, primaryHeight: primaryHeight)
    }

    // MARK: Popup (TXT-02…TXT-05)

    private func showPopup(_ result: TextTranslationResult) {
        popup?.close()
        let model = PopupModel(result: result, settings: settings)
        let panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 280), styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = localizer[.textPopupTitle]
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PopupView(model: model) { [weak self, weak panel] text in
            self?.copy(text)
            _ = panel
        } close: { [weak panel] in panel?.close() }.localized(localizer))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var frame = NSRect(x: mouse.x + 12, y: mouse.y - 300, width: 420, height: 280)
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        panel.setFrame(frame, display: true)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        popup = panel
    }

    private func copy(_ text: String) {
        let pasteboard = pasteboard, errors = errors, message = localizer[.feedbackCopied]
        Task {
            try? await pasteboard.write(.string(text))
            errors.toast(ToastModel(message: message), near: nil)
        }
    }
}

final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
@Observable
final class PopupModel {
    let result: TextTranslationResult
    var selected: EngineID?
    let instances: [CompatibleInstance]

    init(result: TextTranslationResult, settings: any SettingsProviding) {
        self.result = result
        selected = result.outcome.effective
        instances = settings.engines.compatibleInstances
    }

    var translation: String {
        let segments = result.outcome.results.first { $0.id == selected }?.segments ?? []
        return segments.map(\.displayText).joined(separator: "\n\n")
    }
}

struct PopupView: View {
    @Bindable var model: PopupModel
    let copy: (String) -> Void
    let close: () -> Void
    @Environment(Localizer.self) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Text(model.result.source)
                .font(DS.Typography.secondary).foregroundStyle(.secondary)
                .lineLimit(4).textSelection(.enabled)
                .environment(\.layoutDirection, (model.result.from?.isRightToLeft ?? false) ? .rightToLeft : .leftToRight)
            Divider()
            if model.result.outcome.routing.isCompare {
                Picker(l10n[.resultsTranslation], selection: $model.selected) {
                    ForEach(model.result.outcome.results) { result in
                        Text(verbatim: EngineNames.name(result.id, localizer: l10n, instances: model.instances) + " · " + summary(result)).tag(EngineID?.some(result.id))
                    }
                }
                .labelsHidden()
            }
            ScrollView {
                Text(model.translation)
                    .font(DS.Typography.body)
                    .frame(maxWidth: .infinity, alignment: model.result.to.isRightToLeft ? .trailing : .leading)
                    .multilineTextAlignment(model.result.to.isRightToLeft ? .trailing : .leading)
                    .environment(\.layoutDirection, model.result.to.isRightToLeft ? .rightToLeft : .leftToRight)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(l10n[.actionClose], action: close).keyboardShortcut(.cancelAction)
                Button(l10n[.actionCopy]) { copy(model.translation) }.keyboardShortcut("c", modifiers: .command).buttonStyle(.borderedProminent)
            }
        }
        .padding(DS.Space.s4)
        .padding(.top, DS.Space.s4)
    }

    private func summary(_ result: EngineResult) -> String {
        if result.skipped != nil { return l10n[.engineSkipped] }
        if let error = result.error { return LocalizedErrorText(error, localizer: l10n).title }
        let ms = Int(Double(result.duration.components.seconds) * 1000 + Double(result.duration.components.attoseconds) / 1e15)
        return l10n.string(.engineDuration, ms)
    }
}
