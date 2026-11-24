import AppKit
import Observation
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization
import TFWorkspaceUI

@MainActor
@Observable
final class ToolbarModel {
    var editor: AnnotationEditor?
    var observer: DocumentObserver?
    var beautify = false
    /// Smart mosaic is scanning (its button stays highlighted).
    var scanning = false
    var uploadEnabled = false
    var pipelineEnabled = false
    var scrollEnabled = false
    var scrollMode = false
    var scrollRunning = false
    var scrollHeight = 0
    @ObservationIgnored var onFinishScroll: (() -> Void)?
    /// The toolbar's size changed (the style bar opened or closed): the panel is re-laid out.
    @ObservationIgnored var onResize: ((NSSize) -> Void)?
}

/// Letters the capture overlay keeps for its own actions (T translates, P pins, C copies a color).
let captureReservedKeys: Set<Character> = ["t", "p", "c"]

/// Floating toolbar under the selection (INP-01): tools, undo/redo, beautify, smart mosaic, recognize,
/// translate, pin, upload, save, copy, cancel; the style bar opens under it for a tool or selection. Every control
/// has a hover hint drawn above the overlay.
struct InPlaceToolbarView: View {
    let model: ToolbarModel
    let perform: (CaptureController.Action) -> Void
    @Environment(Localizer.self) private var l10n

    var body: some View {
        VStack(alignment: .trailing, spacing: DS.Space.s1) {
            FloatingToolbar {
                if model.scrollRunning {
                    Label(l10n.string(.scrollCaptureProgress, model.scrollHeight), systemImage: "arrow.down.to.line").font(DS.Typography.secondary)
                    ToolbarDivider()
                    Button(l10n[.scrollCaptureFinish]) { model.onFinishScroll?() }.prominentActionStyle()
                    IconButton(l10n[.actionCancel], systemImage: "xmark", shortcutHint: "Esc", detail: l10n[.actionCancelHint]) { perform(.cancel) }
                } else {
                    tools
                    ToolbarDivider()
                    actions
                }
            }
            if !model.scrollRunning, let editor = model.editor, editor.showsStyleBar {
                FloatingToolbar { AnnotationStyleBar(editor: editor) }
            }
        }
        .padding(DS.Space.s1)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.onResize?($0) }
        .hoverHintScope()
    }

    @ViewBuilder
    private var tools: some View {
        if let editor = model.editor {
            AnnotationToolbar(editor: editor, reservedKeys: captureReservedKeys)
        } else {
            AnnotationToolButtons(active: nil, reservedKeys: captureReservedKeys) { perform(.tool($0)) }
        }
        IconButton(l10n[.actionUndo], systemImage: "arrow.uturn.backward", shortcutHint: "⌘Z", detail: l10n[.actionUndoHint]) {
            model.observer?.undo()
        }
        .disabled(!(model.observer?.canUndo ?? false))
        IconButton(l10n[.actionRedo], systemImage: "arrow.uturn.forward", shortcutHint: "⇧⌘Z", detail: l10n[.actionRedoHint]) {
            model.observer?.redo()
        }
        .disabled(!(model.observer?.canRedo ?? false))
    }

    @ViewBuilder
    private var actions: some View {
        IconButton(l10n[.actionBeautify], systemImage: "sparkles.rectangle.stack", detail: l10n[.actionBeautifyHint], isActive: model.beautify) {
            perform(.beautify)
        }
        if model.pipelineEnabled {
            IconButton(
                l10n[.actionSmartMosaic], systemImage: "eye.trianglebadge.exclamationmark", detail: l10n[.actionSmartMosaicHint],
                isActive: model.scanning
            ) { perform(.smartMosaic) }
            IconButton(l10n[.actionRecognize], systemImage: "text.viewfinder", detail: l10n[.actionRecognizeHint]) { perform(.recognize) }
            IconButton(l10n[.actionTranslate], systemImage: "character.bubble", shortcutHint: "T", detail: l10n[.actionTranslateHint]) {
                perform(.translate)
            }
        }
        if model.scrollEnabled {
            IconButton(l10n[.actionScrollCapture], systemImage: "arrow.down.doc", detail: l10n[.actionScrollCaptureHint]) { perform(.scroll) }
        }
        IconButton(l10n[.actionPin], systemImage: "pin", shortcutHint: "P", detail: l10n[.actionPinHint]) { perform(.pin) }
        if model.uploadEnabled {
            IconButton(l10n[.actionUpload], systemImage: "icloud.and.arrow.up", detail: l10n[.actionUploadHint]) { perform(.upload) }
        }
        IconButton(l10n[.actionSave], systemImage: "square.and.arrow.down", shortcutHint: "⌘S", detail: l10n[.actionSaveHint]) { perform(.save) }
        IconButton(l10n[.actionCancel], systemImage: "xmark", shortcutHint: "Esc", detail: l10n[.actionCancelHint]) { perform(.cancel) }
        Button(l10n[.actionCopy]) { perform(.copy) }
            .prominentActionStyle()
            .hoverHint(l10n[.actionCopy], keys: ["↩", "⌘C"], detail: l10n[.actionCopyHint])
    }
}
