import Foundation

// MARK: - Keyboard shortcuts (SPEC §03 APP-04, SET-06)

/// Carbon-compatible modifier mask (values match `cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
public struct ShortcutModifiers: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let command = ShortcutModifiers(rawValue: 0x0100)
    public static let shift = ShortcutModifiers(rawValue: 0x0200)
    public static let option = ShortcutModifiers(rawValue: 0x0800)
    public static let control = ShortcutModifiers(rawValue: 0x1000)

    /// ⌃⌥⇧⌘ in Apple's canonical order.
    public var symbols: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

public struct GlobalShortcut: Sendable, Codable, Hashable {
    /// Virtual key code (`kVK_*`).
    public let keyCode: UInt32
    public let modifiers: ShortcutModifiers

    public init(keyCode: UInt32, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// A global shortcut needs at least one of ⌘, ⌃ or ⌥.
    public var isValid: Bool { !modifiers.intersection([.command, .control, .option]).isEmpty && Self.keyName(keyCode) != nil }

    public var displayString: String { modifiers.symbols + (Self.keyName(keyCode) ?? "?") }

    /// Key equivalent for menus (lower-case character), when representable.
    public var keyEquivalent: String? {
        guard let name = Self.keyName(keyCode), name.count == 1 else { return nil }
        return name.lowercased()
    }

    // kVK_ANSI_* virtual key codes (layout-independent positions, US names).
    public static let keyNames: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V",
        0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3",
        0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
        0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";",
        0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",
        0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "⎋",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
    ]

    public static func keyName(_ code: UInt32) -> String? { keyNames[code] }
}

public enum HotkeyAction: String, Sendable, Codable, CaseIterable, Hashable {
    case fullScreen, selection, translationMode, textSelectionTranslation, translateAndInsert, pickColor

    /// 1.x defaults: ⌘⇧3, ⌘⇧4, ⌘⇧T, ⌘⇧Y, ⌘⇧I, ⌃⌘C (D24).
    public var defaultShortcut: GlobalShortcut {
        switch self {
        case .fullScreen: GlobalShortcut(keyCode: 0x14, modifiers: [.command, .shift])
        case .selection: GlobalShortcut(keyCode: 0x15, modifiers: [.command, .shift])
        case .translationMode: GlobalShortcut(keyCode: 0x11, modifiers: [.command, .shift])
        case .textSelectionTranslation: GlobalShortcut(keyCode: 0x10, modifiers: [.command, .shift])
        case .translateAndInsert: GlobalShortcut(keyCode: 0x22, modifiers: [.command, .shift])
        case .pickColor: GlobalShortcut(keyCode: 0x08, modifiers: [.command, .control])
        }
    }

    public var route: AppRoute {
        switch self {
        case .fullScreen: .capture(.fullDisplay)
        case .selection: .capture(.region)
        case .translationMode: .capture(.regionThenTranslate)
        case .textSelectionTranslation: .translateSelectedText
        case .translateAndInsert: .translateAndInsert
        case .pickColor: .pickColor
        }
    }
}

public enum ShortcutValidation: Sendable, Equatable {
    case ok
    case missingModifier
    case conflict(HotkeyAction)

    /// Rejects shortcuts without a primary modifier or already used by another action (SPEC §03 SET-06).
    public static func validate(_ shortcut: GlobalShortcut, for action: HotkeyAction, in settings: ShortcutSettings) -> ShortcutValidation {
        guard shortcut.isValid else { return .missingModifier }
        for other in HotkeyAction.allCases where other != action && settings[other] == shortcut {
            return .conflict(other)
        }
        return .ok
    }
}
