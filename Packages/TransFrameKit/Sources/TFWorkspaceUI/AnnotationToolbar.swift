import AppKit
import Observation
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization

/// Session snapshots for SwiftUI (reads the store's stream; writes go through transactions).
/// Properties are written only when they change, so toolbars do not re-render on every edit.
@MainActor
@Observable
public final class DocumentObserver {
    public private(set) var session: DocumentSession?
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    public private(set) var beautify = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let sessions: any SessionManaging
    @ObservationIgnored public let sessionID: SessionID
    @ObservationIgnored public var onChange: ((DocumentSession) -> Void)?

    public init(sessions: any SessionManaging, sessionID: SessionID) {
        self.sessions = sessions
        self.sessionID = sessionID
    }

    public func start() {
        guard task == nil else { return }
        let sessions = sessions, id = sessionID
        task = Task { [weak self] in
            for await snapshot in await sessions.snapshots(of: id) {
                guard let self else { return }
                self.session = snapshot
                if self.beautify != snapshot.presentation.beautify { self.beautify = snapshot.presentation.beautify }
                // The canvas hears about the snapshot before the undo state round trips.
                self.onChange?(snapshot)
                let undo = await sessions.canUndo(id), redo = await sessions.canRedo(id)
                if self.canUndo != undo { self.canUndo = undo }
                if self.canRedo != redo { self.canRedo = redo }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func undo() { let s = sessions, id = sessionID; Task { _ = await s.undo(id) } }
    public func redo() { let s = sessions, id = sessionID; Task { _ = await s.redo(id) } }
}

/// The eleven tool buttons in toolbar order (ANN-01, ANN-02) with hover hints: name, shortcut keys and how to use it.
/// `reservedKeys` are letters the host uses for its own actions (the capture overlay's T translates).
public struct AnnotationToolButtons: View {
    let active: AnnotationTool?
    let reservedKeys: Set<Character>
    let select: (AnnotationTool) -> Void
    @Environment(Localizer.self) private var l10n

    public init(active: AnnotationTool?, reservedKeys: Set<Character> = [], select: @escaping (AnnotationTool) -> Void) {
        self.active = active
        self.reservedKeys = reservedKeys
        self.select = select
    }

    public var body: some View {
        ForEach(AnnotationTool.allCases, id: \.self) { tool in
            IconButton(
                l10n.string(rawKey: "tool.\(tool.rawValue)"), systemImage: tool.systemImage, shortcutKeys: tool.shortcutKeys(reserved: reservedKeys),
                detail: l10n.string(rawKey: "tool.\(tool.rawValue).hint"), isActive: active == tool
            ) { select(tool) }
        }
    }
}

/// Tool buttons and the style button shared by the capture overlay and the editor (ANN-01…ANN-03).
public struct AnnotationToolbar: View {
    @Bindable var editor: AnnotationEditor
    let showsTools: Bool
    let reservedKeys: Set<Character>
    @Environment(Localizer.self) private var l10n

    public init(editor: AnnotationEditor, showsTools: Bool = true, reservedKeys: Set<Character> = []) {
        self.editor = editor
        self.showsTools = showsTools
        self.reservedKeys = reservedKeys
    }

    public var body: some View {
        HStack(spacing: DS.Space.s1 / 2) {
            if showsTools {
                AnnotationToolButtons(active: editor.tool, reservedKeys: reservedKeys) { tool in
                    editor.tool = editor.tool == tool ? nil : tool
                }
                ToolbarDivider()
            }
            Button { editor.stylePinned.toggle() } label: {
                Circle().fill(Color(rgba: editor.displayedStyle.color)).frame(width: DS.Size.swatch, height: DS.Size.swatch)
                    .overlay(Circle().strokeBorder(DS.Palette.separator, lineWidth: 1))
                    .frame(minWidth: DS.Size.iconButton - DS.Space.s2, minHeight: DS.Size.iconButton - DS.Space.s2)
                    .contentShape(.rect)
            }
            .buttonStyle(IconButtonStyle(isActive: editor.showsStyleBar))
            .hoverHint(l10n[.toolStyle], detail: l10n[.toolStyleHint])
            .accessibilityLabel(l10n[.toolStyle])
            .accessibilityAddTraits(editor.showsStyleBar ? .isSelected : [])
        }
    }
}

/// The annotation style bar (SPEC §01 TFWorkspaceUI "样式条"): only the controls that apply to the selected annotation
/// or the current tool — palette, screen color picker, system colors, line width, text size, mosaic strength, fill and
/// fill color — and Delete for a selection (ANN-03…ANN-07, ANN-10, ANN-13). Shows the selection's own values.
public struct AnnotationStyleBar: View {
    @Bindable var editor: AnnotationEditor
    @Environment(Localizer.self) private var l10n

    public init(editor: AnnotationEditor) { self.editor = editor }

    public var body: some View {
        let controls = editor.styleControls
        let style = editor.displayedStyle
        HStack(spacing: DS.Space.s2) {
            if controls.contains(.color) {
                HStack(spacing: DS.Space.s1 / 2) {
                    ForEach(AnnotationPalette.all, id: \.name) { entry in
                        ColorSwatch(
                            color: Color(rgba: entry.color), name: l10n.string(rawKey: "color.\(entry.name)"), isSelected: style.color == entry.color
                        ) { editor.setStyle { $0.color = entry.color } }
                    }
                }
                IconButton(l10n[.toolPickScreenColor], systemImage: "eyedropper", detail: l10n[.toolPickScreenColorHint]) { editor.pickColor() }
                SystemColorButton(
                    l10n[.toolSystemColor], systemImage: "paintpalette", detail: l10n[.toolSystemColorHint], color: NSColor(rgba: style.color),
                    supportsOpacity: false
                ) { color in
                    if let rgba = RGBA(nsColor: color) { editor.setStyle { $0.color = rgba.withAlpha(1) } }
                }
            }
            if controls.contains(.lineWidth) {
                StyleSlider(
                    title: l10n[.settingsAnnotationsLineWidth], systemImage: "lineweight", value: binding(\.lineWidth),
                    range: AnnotationDefaults.lineWidthRange)
            }
            if controls.contains(.fontSize) {
                StyleSlider(
                    title: l10n[.settingsAnnotationsFontSize], systemImage: "textformat.size", value: binding(\.fontSize),
                    range: AnnotationDefaults.fontSizeRange)
            }
            if controls.contains(.mosaic) {
                StyleSlider(
                    title: l10n[.settingsAnnotationsMosaic], systemImage: "square.grid.3x3", value: binding(\.mosaicBlockSize),
                    range: AnnotationDefaults.mosaicRange)
            }
            if controls.contains(.fill) {
                IconButton(
                    l10n[.toolFill], systemImage: style.isFilled ? "square.fill" : "square", detail: l10n[.toolFillHint], isActive: style.isFilled
                ) { editor.setStyle { $0.isFilled.toggle() } }
                if style.isFilled {
                    SystemColorButton(
                        l10n[.toolFillColor], systemImage: "drop.halffull", detail: l10n[.toolFillColorHint], color: NSColor(rgba: style.fillColor),
                        supportsOpacity: true
                    ) { color in
                        if let rgba = RGBA(nsColor: color) { editor.setStyle { $0.fillColor = rgba } }
                    }
                }
            }
            if editor.selectedID != nil {
                if !controls.isEmpty { ToolbarDivider() }
                IconButton(l10n[.actionDelete], systemImage: "trash", shortcutKeys: ["⌫"], detail: l10n[.toolDeleteHint], role: .destructive) {
                    editor.deleteSelection()
                }
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<AnnotationStyle, Double>) -> Binding<Double> {
        // Whole points; unchanged values are no-ops, so a drag only writes when the number moves.
        Binding(get: { editor.displayedStyle[keyPath: keyPath] }, set: { value in editor.setStyle { $0[keyPath: keyPath] = value.rounded() } })
    }
}

private struct StyleSlider: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: DS.Space.s1) {
            Image(systemName: systemImage).foregroundStyle(.secondary).accessibilityHidden(true)
            Slider(value: $value, in: range)
                .controlSize(.small)
                .frame(width: 96)
                .accessibilityLabel(title)
            Text(value, format: .number.precision(.fractionLength(0)))
                .font(DS.Typography.monoCaption)
                .frame(minWidth: 22, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .hoverHint(title)
    }
}

public extension Color {
    init(rgba: RGBA) { self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha) }
}

public extension NSColor {
    convenience init(rgba: RGBA) { self.init(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha) }
}

public extension RGBA {
    init?(color: Color) { self.init(nsColor: NSColor(color)) }

    init?(nsColor: NSColor) {
        guard let ns = nsColor.usingColorSpace(.sRGB) else { return nil }
        self.init(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent, alpha: ns.alphaComponent)
    }
}
