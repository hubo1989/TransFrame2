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
    var uploadEnabled = false
    var pipelineEnabled = false
    var scrollEnabled = false
    var scrollMode = false
    var scrollRunning = false
    var scrollHeight = 0
    @ObservationIgnored var onFinishScroll: (() -> Void)?
}

/// Floating toolbar under the selection (INP-01): tools, undo/redo, beautify, smart mosaic, recognize,
/// translate, pin, upload, save, copy, cancel.
struct InPlaceToolbarView: View {
    let model: ToolbarModel
    let perform: (CaptureController.Action) -> Void
    @Environment(Localizer.self) private var l10n

    var body: some View {
        FloatingToolbar {
            if model.scrollRunning {
                Label(l10n.string(.scrollCaptureProgress, model.scrollHeight), systemImage: "arrow.down.to.line").font(DS.Typography.secondary)
                ToolbarDivider()
                Button(l10n[.scrollCaptureFinish]) { model.onFinishScroll?() }.prominentActionStyle()
                IconButton(l10n[.actionCancel], systemImage: "xmark") { perform(.cancel) }
            } else {
                tools
                ToolbarDivider()
                actions
            }
        }
        .padding(DS.Space.s1)
        .fixedSize()
    }

    @ViewBuilder
    private var tools: some View {
        if let editor = model.editor {
            AnnotationToolbar(editor: editor)
        } else {
            ForEach(Array(AnnotationTool.allCases.enumerated()), id: \.element) { index, tool in
                IconButton(
                    l10n.string(rawKey: "tool.\(tool.rawValue)"), systemImage: tool.systemImage,
                    shortcutHint: "\(tool.shortcutKey.uppercased())\(index < 9 ? " / \(index + 1)" : "")"
                ) { perform(.tool(tool)) }
            }
        }
        IconButton(l10n[.actionUndo], systemImage: "arrow.uturn.backward", shortcutHint: "⌘Z") { model.observer?.undo() }
            .disabled(!(model.observer?.canUndo ?? false))
        IconButton(l10n[.actionRedo], systemImage: "arrow.uturn.forward", shortcutHint: "⇧⌘Z") { model.observer?.redo() }
            .disabled(!(model.observer?.canRedo ?? false))
    }

    @ViewBuilder
    private var actions: some View {
        IconButton(l10n[.actionBeautify], systemImage: "sparkles.rectangle.stack", isActive: model.beautify) { perform(.beautify) }
        if model.pipelineEnabled {
            IconButton(l10n[.actionSmartMosaic], systemImage: "eye.trianglebadge.exclamationmark") { perform(.smartMosaic) }
            IconButton(l10n[.actionRecognize], systemImage: "text.viewfinder") { perform(.recognize) }
            IconButton(l10n[.actionTranslate], systemImage: "character.bubble", shortcutHint: "T") { perform(.translate) }
        }
        if model.scrollEnabled {
            IconButton(l10n[.actionScrollCapture], systemImage: "arrow.down.doc") { perform(.scroll) }
        }
        IconButton(l10n[.actionPin], systemImage: "pin", shortcutHint: "P") { perform(.pin) }
        if model.uploadEnabled {
            IconButton(l10n[.actionUpload], systemImage: "icloud.and.arrow.up") { perform(.upload) }
        }
        IconButton(l10n[.actionSave], systemImage: "square.and.arrow.down", shortcutHint: "⌘S") { perform(.save) }
        IconButton(l10n[.actionCancel], systemImage: "xmark", shortcutHint: "Esc") { perform(.cancel) }
        Button(l10n[.actionCopy]) { perform(.copy) }
            .prominentActionStyle()
            .help("\(l10n[.actionCopy]) (↩)")
    }
}
