import Foundation

// MARK: - Routing (SPEC §02 §12)

public enum EditorFocus: String, Sendable, Equatable, Hashable { case ocr, translation }

public enum SettingsPage: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case general, engines, prompts, languages, shortcuts, annotations, privacy, ai, glossary, imageHost
}

public indirect enum AppRoute: Sendable, Equatable {
    case capture(CaptureIntent)
    case pickColor
    case openImage(URL?)
    case translateSelectedText
    case translateAndInsert
    case polishSelection
    case openEditor(SessionID, focus: EditorFocus?)
    case pin(SessionID)
    case restorePinInteractions, showAllPins
    case openHistory(HistoryQuery?)
    case openColorHistory
    case openSettings(SettingsPage?)
    case openOnboarding
    case openAbout
    case checkForUpdates
    case quit
}

@MainActor
public protocol AppRouting: AnyObject {
    func route(_ route: AppRoute)
}
