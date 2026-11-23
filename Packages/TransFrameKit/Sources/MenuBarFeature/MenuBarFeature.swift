import AppKit
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization
import TFWorkspaceUI

// MARK: - Menu model (pure; APP-02, APP-03, N-12)

public struct MenuItemModel: Equatable {
    public enum Kind: Equatable {
        case action(AppRoute)
        case submenu([MenuItemModel])
        case separator
        case info
    }

    public let title: String
    public let kind: Kind
    /// Display string of the global shortcut (shown as a key equivalent).
    public let shortcut: GlobalShortcut?
    /// Local key equivalent (for items without a global shortcut, e.g. ⌘O, ⌘,).
    public let keyEquivalent: (key: String, modifiers: ShortcutModifiers)?
    public let isEnabled: Bool

    public init(
        title: String, kind: Kind, shortcut: GlobalShortcut? = nil,
        keyEquivalent: (key: String, modifiers: ShortcutModifiers)? = nil, isEnabled: Bool = true
    ) {
        self.title = title
        self.kind = kind
        self.shortcut = shortcut
        self.keyEquivalent = keyEquivalent
        self.isEnabled = isEnabled
    }

    public static let separator = MenuItemModel(title: "", kind: .separator)

    public static func == (lhs: MenuItemModel, rhs: MenuItemModel) -> Bool {
        lhs.title == rhs.title && lhs.kind == rhs.kind && lhs.shortcut == rhs.shortcut && lhs.isEnabled == rhs.isEnabled
            && lhs.keyEquivalent?.key == rhs.keyEquivalent?.key && lhs.keyEquivalent?.modifiers == rhs.keyEquivalent?.modifiers
    }

    public var route: AppRoute? { if case .action(let route) = kind { route } else { nil } }
}

public enum MenuBuilder {
    /// Builds the native menu model from the current shortcuts, language and pin count.
    @MainActor
    public static func build(shortcuts: ShortcutSettings, pinCount: Int, localizer l: Localizer) -> [MenuItemModel] {
        let pins: [MenuItemModel] = [
            MenuItemModel(title: l[.menuPinsRestoreInteractions], kind: .action(.restorePinInteractions), isEnabled: pinCount > 0),
            MenuItemModel(title: l[.menuPinsShowAll], kind: .action(.showAllPins), isEnabled: pinCount > 0),
        ]
        return [
            MenuItemModel(title: l[.menuCaptureRegion], kind: .action(.capture(.region)), shortcut: shortcuts[.selection]),
            MenuItemModel(title: l[.menuCaptureFullScreen], kind: .action(.capture(.fullDisplay)), shortcut: shortcuts[.fullScreen]),
            MenuItemModel(title: l[.menuCaptureTranslate], kind: .action(.capture(.regionThenTranslate)), shortcut: shortcuts[.translationMode]),
            MenuItemModel(title: l[.menuCaptureScroll], kind: .action(.capture(.scroll))),
            .separator,
            MenuItemModel(title: l[.menuTranslateSelection], kind: .action(.translateSelectedText), shortcut: shortcuts[.textSelectionTranslation]),
            MenuItemModel(title: l[.menuTranslateAndInsert], kind: .action(.translateAndInsert), shortcut: shortcuts[.translateAndInsert]),
            .separator,
            MenuItemModel(title: l[.menuPickColor], kind: .action(.pickColor), shortcut: shortcuts[.pickColor]),
            MenuItemModel(title: l[.menuOpenImage], kind: .action(.openImage(nil)), keyEquivalent: ("o", [.command])),
            .separator,
            MenuItemModel(title: l[.menuHistory], kind: .action(.openHistory(nil)), keyEquivalent: ("h", [.command, .shift])),
            MenuItemModel(title: l[.menuColorHistory], kind: .action(.openColorHistory)),
            MenuItemModel(title: pinCount > 0 ? l.string(.menuPinsCount, pinCount) : l[.menuPins], kind: .submenu(pins)),
            .separator,
            MenuItemModel(title: l[.menuSettings], kind: .action(.openSettings(nil)), keyEquivalent: (",", [.command])),
            MenuItemModel(title: l[.menuAbout], kind: .action(.openAbout)),
            .separator,
            MenuItemModel(title: l[.menuQuit], kind: .action(.quit), keyEquivalent: ("q", [.command])),
        ]
    }
}

// MARK: - Coordinator

@MainActor
public protocol MenuBarCoordinating: AnyObject {
    func install()
    func rebuild()
}

/// Owns the status item and its native menu (D14). The menu is rebuilt every time it opens, so
/// language and shortcut changes always show up immediately (APP-03).
@MainActor
public final class MenuBarCoordinator: NSObject, MenuBarCoordinating, NSMenuDelegate {
    private let settings: any SettingsProviding
    private let localizer: Localizer
    private let router: any AppRouting
    private let pinCount: () -> Int
    private let image: NSImage?
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    public private(set) var currentModel: [MenuItemModel] = []

    public init(settings: any SettingsProviding, localizer: Localizer, router: any AppRouting, image: NSImage?, pinCount: @escaping () -> Int) {
        self.settings = settings
        self.localizer = localizer
        self.router = router
        self.image = image
        self.pinCount = pinCount
    }

    public func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = image
        item.button?.image?.isTemplate = true
        item.button?.imagePosition = .imageOnly
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
        rebuild()
    }

    public func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    public func rebuild() {
        currentModel = MenuBuilder.build(shortcuts: settings.shortcuts, pinCount: pinCount(), localizer: localizer)
        statusItem?.button?.setAccessibilityLabel(localizer[.appName])
        statusItem?.button?.toolTip = localizer[.appName]
        menu.removeAllItems()
        for model in currentModel { menu.addItem(makeItem(model)) }
    }

    private func makeItem(_ model: MenuItemModel) -> NSMenuItem {
        switch model.kind {
        case .separator:
            return .separator()
        case .info:
            let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .submenu(let children):
            let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: model.title)
            submenu.autoenablesItems = false
            for child in children { submenu.addItem(makeItem(child)) }
            item.submenu = submenu
            return item
        case .action(let route):
            let item = NSMenuItem(title: model.title, action: #selector(performRoute(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = RouteBox(route)
            item.isEnabled = model.isEnabled
            if let shortcut = model.shortcut, let key = shortcut.keyEquivalent {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = shortcut.modifiers.eventFlags
            } else if let equivalent = model.keyEquivalent {
                item.keyEquivalent = equivalent.key
                item.keyEquivalentModifierMask = equivalent.modifiers.eventFlags
            }
            return item
        }
    }

    @objc private func performRoute(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? RouteBox else { return }
        router.route(box.route)
    }

    /// Triggers a menu action by route; used by tests and accessibility automation.
    public func activate(_ route: AppRoute) { router.route(route) }
}

private final class RouteBox: NSObject {
    let route: AppRoute
    init(_ route: AppRoute) { self.route = route }
}

extension ShortcutModifiers {
    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}
