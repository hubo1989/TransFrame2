import AppKit
import Observation
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization

/// Session snapshots for SwiftUI (reads the store's stream; writes go through transactions).
@MainActor
@Observable
public final class DocumentObserver {
    public private(set) var session: DocumentSession?
    public private(set) var canUndo = false
    public private(set) var canRedo = false
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
                self.canUndo = await sessions.canUndo(id)
                self.canRedo = await sessions.canRedo(id)
                self.onChange?(snapshot)
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

/// Tool buttons and style controls shared by the capture overlay and the editor (ANN-01…ANN-07, ANN-13).
public struct AnnotationToolbar: View {
    @Bindable var editor: AnnotationEditor
    let showsTools: Bool
    @Environment(Localizer.self) private var l10n
    @State private var showsStyle = false

    public init(editor: AnnotationEditor, showsTools: Bool = true) {
        self.editor = editor
        self.showsTools = showsTools
    }

    public var body: some View {
        HStack(spacing: DS.Space.s1 / 2) {
            if showsTools {
                ForEach(Array(AnnotationTool.allCases.enumerated()), id: \.element) { index, tool in
                    IconButton(
                        l10n.string(rawKey: "tool.\(tool.rawValue)"), systemImage: tool.systemImage,
                        shortcutHint: "\(tool.shortcutKey.uppercased())\(index < 9 ? " / \(index + 1)" : "")",
                        isActive: editor.tool == tool
                    ) { editor.tool = editor.tool == tool ? nil : tool }
                }
                ToolbarDivider()
            }
            Button { showsStyle.toggle() } label: {
                Circle().fill(Color(rgba: editor.style.color)).frame(width: DS.Size.swatch, height: DS.Size.swatch)
                    .overlay(Circle().strokeBorder(DS.Palette.separator, lineWidth: 1))
            }
            .buttonStyle(IconButtonStyle())
            .help(l10n[.toolStyle])
            .accessibilityLabel(l10n[.toolStyle])
            .popover(isPresented: $showsStyle, arrowEdge: .bottom) {
                StylePanel(editor: editor).localized(l10n)
            }
        }
    }
}

struct StylePanel: View {
    @Bindable var editor: AnnotationEditor
    @Environment(Localizer.self) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            Text(l10n[.toolStyle]).font(DS.Typography.section)
            HStack(spacing: DS.Space.s1) {
                ForEach(AnnotationPalette.all, id: \.name) { entry in
                    ColorSwatch(color: Color(rgba: entry.color), name: l10n.string(rawKey: "color.\(entry.name)"), isSelected: editor.style.color == entry.color) {
                        editor.style.color = entry.color
                    }
                }
            }
            HStack(spacing: DS.Space.s2) {
                ColorPicker(l10n[.toolSystemColor], selection: Binding(
                    get: { Color(rgba: editor.style.color) },
                    set: { editor.style.color = RGBA(color: $0) ?? editor.style.color }
                ), supportsOpacity: false)
                Button(l10n[.toolPickScreenColor], systemImage: "eyedropper") { editor.pickColor() }
            }
            SliderRow(title: l10n[.settingsAnnotationsLineWidth], value: $editor.style.lineWidth, range: AnnotationDefaults.lineWidthRange)
            SliderRow(title: l10n[.settingsAnnotationsFontSize], value: $editor.style.fontSize, range: AnnotationDefaults.fontSizeRange)
            SliderRow(title: l10n[.settingsAnnotationsMosaic], value: $editor.style.mosaicBlockSize, range: AnnotationDefaults.mosaicRange)
            Toggle(l10n[.settingsAnnotationsFill], isOn: $editor.style.isFilled)
        }
        .padding(DS.Space.s4)
        .frame(width: 300)
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: 1)
                Text(value, format: .number.precision(.fractionLength(0))).font(DS.Typography.monoCaption).frame(width: 28)
            }
        }
    }
}

public extension Color {
    init(rgba: RGBA) { self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha) }
}

public extension RGBA {
    init?(color: Color) {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent, alpha: ns.alphaComponent)
    }
}
