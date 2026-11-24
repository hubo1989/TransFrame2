import AppKit
import Foundation
import Testing
import TFDomain
@testable import TFSystemInfra

@Suite("Temporary clipboard")
@MainActor
struct TemporaryClipboardTests {
    @Test func discardingAnAbortedCopyRestoresTheUsersClipboard() async {
        let board = NSPasteboard(name: NSPasteboard.Name("tf2-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let pasteboard = SystemPasteboard(pasteboard: board)
        board.clearContents()
        board.setString("user's clipboard", forType: .string)
        let snapshot = await pasteboard.snapshot()
        let before = await pasteboard.changeCount()
        // Nothing copied yet: nothing to undo.
        pasteboard.discardTemporaryCopy(after: before, restoring: snapshot)
        #expect(board.changeCount == before)
        // The target application copied its selection, then the capture was aborted.
        board.clearContents()
        board.setString("selected text", forType: .string)
        pasteboard.discardTemporaryCopy(after: before, restoring: snapshot)
        #expect(board.string(forType: .string) == "user's clipboard")
    }
}
