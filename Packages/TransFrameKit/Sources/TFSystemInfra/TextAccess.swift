import AppKit
import ApplicationServices
import Foundation
import TFDomain

/// Reads the selection via Accessibility, falling back to synthetic ⌘C with clipboard restore (TXT-01, TXT-16).
@MainActor
public final class AccessibilityTextService: SelectedTextCapturing, TextInserting {
    private let pasteboard: SystemPasteboard
    private var binding: (token: Int, element: AXUIElement, selectedText: String)?
    private var nextToken = 1

    public init(pasteboard: SystemPasteboard) {
        self.pasteboard = pasteboard
    }

    public func captureSelection(bindTarget: Bool) async throws(AppError) -> CapturedSelection {
        guard AXIsProcessTrusted() else { throw .permission(.accessibilityDenied) }
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier
        let element = Self.focusedElement().flatMap { element in
            var owner: pid_t = 0
            return AXUIElementGetPid(element, &owner) == .success && owner == pid ? element : nil
        }
        let selectedText = element.flatMap { Self.string($0, kAXSelectedTextAttribute) } ?? ""
        let range = element.flatMap(Self.selectedRange)
        let anchor = element.flatMap { Self.bounds($0, range: range) }
        let text: String
        if selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let pid {
            text = try await copyViaKeyboard(to: pid, element: element) ?? ""
        } else {
            text = selectedText
        }
        if Task.isCancelled { throw .cancelled }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .textInput(.noSelection) }
        var target: TextInsertionTarget?
        if bindTarget, let app, let pid {
            try Self.verify(pid, element: element, range: range, selectedText: selectedText)
            binding = nil
            var token = 0
            if let element {
                token = nextToken
                nextToken += 1
                binding = (token, element, selectedText)
            }
            target = TextInsertionTarget(
                processID: pid, bundleID: app.bundleIdentifier, elementToken: token, selectedRange: range, canVerify: range != nil
            )
        }
        return CapturedSelection(text: text, target: target, anchor: anchor, appName: app?.localizedName)
    }

    public func insert(_ text: String, into target: TextInsertionTarget) async throws(AppError) -> InsertionMethod {
        let element: AXUIElement?
        let selectedText: String
        if target.elementToken != 0 {
            guard let binding, binding.token == target.elementToken else { throw .textInput(.targetChanged) }
            element = binding.element
            selectedText = binding.selectedText
            self.binding = nil
        } else {
            element = nil
            selectedText = ""
        }
        try Self.verify(target.processID, element: element, range: target.selectedRange, selectedText: selectedText)
        if let element, target.canVerify,
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            return .accessibility
        }
        try await paste(text, to: target.processID, element: element, range: target.selectedRange, selectedText: selectedText)
        return .paste
    }

    public func pasteAnchored(_ text: String, processID: Int32?) async throws(AppError) {
        guard let processID else { throw .textInput(.targetChanged) }
        try await paste(text, to: processID)
    }

    private func paste(
        _ text: String, to pid: Int32, element: AXUIElement? = nil, range: Range<Int>? = nil, selectedText: String = ""
    ) async throws(AppError) {
        let snapshot = await pasteboard.snapshot()
        try Self.verify(pid, element: element, range: range, selectedText: selectedText)
        let generation = try pasteboard.stageString(text, restoring: snapshot)
        defer { pasteboard.restore(snapshot, ifCurrent: generation) }
        try Self.verify(pid, element: element, range: range, selectedText: selectedText)
        try Self.postKey(9, to: pid)
        do { try await Task.sleep(for: .milliseconds(250)) } catch { throw .cancelled }
    }

    private func copyViaKeyboard(to pid: Int32, element: AXUIElement?) async throws(AppError) -> String? {
        let snapshot = await pasteboard.snapshot()
        let before = await pasteboard.changeCount()
        try Self.verify(pid, element: element)
        try Self.postKey(8, to: pid)
        do throws(AppError) {
            for _ in 0..<20 {
                do { try await Task.sleep(for: .milliseconds(25)) } catch { throw AppError.cancelled }
                try Self.verify(pid, element: element)
                if let copy = pasteboard.takeTemporaryCopy(after: before, restoring: snapshot) { return copy }
            }
        } catch {
            // The target may already have copied: the user's clipboard comes back on every early exit too.
            pasteboard.discardTemporaryCopy(after: before, restoring: snapshot)
            throw error
        }
        pasteboard.discardTemporaryCopy(after: before, restoring: snapshot)
        return nil
    }

    private static func verify(
        _ pid: Int32, element: AXUIElement?, range: Range<Int>? = nil, selectedText: String = ""
    ) throws(AppError) {
        if Task.isCancelled { throw .cancelled }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw .textInput(.targetChanged) }
        guard let element else { return }
        guard let focused = focusedElement(), CFEqual(focused, element) else { throw .textInput(.targetChanged) }
        if let range, selectedRange(element) != range { throw .textInput(.targetChanged) }
        if !selectedText.isEmpty, string(element, kAXSelectedTextAttribute) != selectedText { throw .textInput(.targetChanged) }
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func postKey(_ keyCode: CGKeyCode, to pid: Int32) throws(AppError) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw .textInput(.targetChanged)
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
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
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) else { return nil }
        let (end, overflow) = range.location.addingReportingOverflow(range.length)
        guard range.location >= 0, range.length >= 0, !overflow else { return nil }
        return range.location..<end
    }

    private static func bounds(_ element: AXUIElement, range: Range<Int>?) -> QuartzRect? {
        guard let range else { return nil }
        var cfRange = CFRange(location: range.lowerBound, length: max(range.count, 1))
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgRect, &rect) else { return nil }
        return QuartzRect(rect)
    }
}
