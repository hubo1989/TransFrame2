import AppKit
import ApplicationServices
import Foundation
import TFDomain

/// Reads the selection via Accessibility, falling back to synthetic ⌘C with clipboard restore (TXT-01, TXT-16).
@MainActor
public final class AccessibilityTextService: SelectedTextCapturing, TextInserting {
    private let pasteboard: SystemPasteboard
    private var elements: [Int: AXUIElement] = [:]
    private var nextToken = 1

    public init(pasteboard: SystemPasteboard) {
        self.pasteboard = pasteboard
    }

    public func captureSelection(bindTarget: Bool) async throws(AppError) -> CapturedSelection {
        guard AXIsProcessTrusted() else { throw .permission(.accessibilityDenied) }
        let app = NSWorkspace.shared.frontmostApplication
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        var element: AXUIElement?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success, let value = focusedValue {
            element = (value as! AXUIElement)
        }
        var text = element.flatMap { Self.string($0, kAXSelectedTextAttribute) } ?? ""
        let range = element.flatMap(Self.selectedRange)
        let anchor = element.flatMap { Self.bounds($0, range: range) }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = await copyViaKeyboard() ?? ""
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .textInput(.noSelection) }
        var target: TextInsertionTarget?
        if bindTarget, let element, let app {
            let token = nextToken
            nextToken += 1
            elements[token] = element
            target = TextInsertionTarget(processID: app.processIdentifier, bundleID: app.bundleIdentifier, elementToken: token, selectedRange: range, canVerify: range != nil)
        } else if bindTarget, let app {
            target = TextInsertionTarget(processID: app.processIdentifier, bundleID: app.bundleIdentifier, elementToken: 0, selectedRange: nil, canVerify: false)
        }
        return CapturedSelection(text: text, target: target, anchor: anchor, appName: app?.localizedName)
    }

    /// Re-verifies focus and selection, then replaces the selection (TXT-06, TXT-07); falls back to anchored paste (TXT-08).
    public func insert(_ text: String, into target: TextInsertionTarget) async throws(AppError) -> InsertionMethod {
        guard let element = elements.removeValue(forKey: target.elementToken), target.canVerify else {
            try await pasteAnchored(text, processID: target.processID)
            return .paste
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID else { throw .textInput(.targetChanged) }
        var focusedValue: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let value = focusedValue, CFEqual(value, element) else { throw .textInput(.targetChanged) }
        if let expected = target.selectedRange, Self.selectedRange(element) != expected { throw .textInput(.targetChanged) }
        if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            return .accessibility
        }
        try await pasteAnchored(text, processID: target.processID)
        return .paste
    }

    public func pasteAnchored(_ text: String, processID: Int32?) async throws(AppError) {
        if let processID, NSWorkspace.shared.frontmostApplication?.processIdentifier != processID {
            throw .textInput(.targetChanged)
        }
        let snapshot = await pasteboard.snapshot()
        try await pasteboard.write(.string(text))
        Self.postKey(9, flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(250))
        await pasteboard.restore(snapshot)
    }

    private func copyViaKeyboard() async -> String? {
        let snapshot = await pasteboard.snapshot()
        let before = await pasteboard.changeCount()
        Self.postKey(8, flags: .maskCommand)
        var copied: String?
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(25))
            if await pasteboard.changeCount() != before {
                copied = await pasteboard.readString()
                break
            }
        }
        await pasteboard.restore(snapshot)
        return copied
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func selectedRange(_ element: AXUIElement) -> Range<Int>? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.location..<(range.location + range.length)
    }

    private static func bounds(_ element: AXUIElement, range: Range<Int>?) -> QuartzRect? {
        guard let range else { return nil }
        var cfRange = CFRange(location: range.lowerBound, length: max(range.count, 1))
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return QuartzRect(rect)
    }
}
