import Foundation

// MARK: - AppError (SPEC §02 §13)

public enum PermissionError: String, Sendable, Equatable, Codable { case screenRecordingDenied, accessibilityDenied }

public enum CaptureError: Sendable, Equatable {
    case noDisplays
    case displayDisconnected(String)
    case timedOut
    case topologyChanged
    case selectionTooSmall
    case selectionOutOfBounds
    case outputTooLarge
    case sessionBusy
}

public enum EngineError: Sendable, Equatable {
    case notConfigured(EngineID)
    case credentialLocked
    case authenticationFailed(EngineID)
    case rateLimited(EngineID, retryAfter: Duration?)
    case timedOut(EngineID)
    case unreachable(EngineID)
    /// `detail` must not contain source text, translations or secrets.
    case invalidResponse(EngineID, detail: String)
    case unavailableOnThisOS(EngineID, minimum: OSVersion)
    case assetsMissing(EngineID)
    case quotaExceeded(EngineID)

    public var engine: EngineID? {
        switch self {
        case .credentialLocked: nil
        case .notConfigured(let e), .authenticationFailed(let e), .rateLimited(let e, _), .timedOut(let e),
             .unreachable(let e), .invalidResponse(let e, _), .unavailableOnThisOS(let e, _), .assetsMissing(let e),
             .quotaExceeded(let e): e
        }
    }
}

public enum RecognitionError: Sendable, Equatable { case regionOutOfBounds, imageUnreadable }

public struct EngineFailure: Sendable, Equatable {
    public let engine: EngineID
    public let reason: AppError
    public init(engine: EngineID, reason: AppError) {
        self.engine = engine
        self.reason = reason
    }
}

public enum TranslationError: Sendable, Equatable {
    case allEnginesFailed([EngineFailure])
    case noTranslatableText
    case unsupportedPair
}

public enum RenderError: Sendable, Equatable { case canvasTooLarge, contextUnavailable }
public enum ExportError: Sendable, Equatable { case invalidLocation, diskFull, encodingFailed, clipboardWriteFailed }
public enum UploadError: Sendable, Equatable { case notConfigured, rejected(status: Int), network }
public enum TextInputError: Sendable, Equatable { case noSelection, targetChanged, targetUnavailable, notVerified }
public enum HotkeyError: Sendable, Equatable { case registrationFailed, conflict(with: String) }
public enum PersistenceError: Sendable, Equatable { case storeUnavailable, migrationFailed, writeFailed }

public enum AppError: Error, Sendable, Equatable {
    case permission(PermissionError)
    case capture(CaptureError)
    case engine(EngineError)
    case recognition(RecognitionError)
    case translation(TranslationError)
    case render(RenderError)
    case export(ExportError)
    case upload(UploadError)
    case textInput(TextInputError)
    case hotkey(HotkeyError)
    case persistence(PersistenceError)
    case cancelled
    /// Should never happen; logged, users see a generic message.
    case invariant(String)

    public var isCancellation: Bool { self == .cancelled }

    /// `rateLimited`, `timedOut` and `unreachable` may be retried once with back-off (SPEC §02 §13).
    public var isRetryable: Bool {
        switch self {
        case .engine(.rateLimited), .engine(.timedOut), .engine(.unreachable): true
        case .engine(.invalidResponse(_, let detail)): detail == PositionalResponseError.mismatch
        default: false
        }
    }

    /// Maps any thrown error to `AppError`; `CancellationError` becomes `.cancelled`.
    public static func from(_ error: any Error) -> AppError {
        if let app = error as? AppError { return app }
        if error is CancellationError { return .cancelled }
        if let url = error as? URLError, url.code == .cancelled { return .cancelled }
        return .invariant(String(describing: type(of: error)))
    }
}

// MARK: - User messages

public enum SystemSettingsPane: String, Sendable, Equatable, Codable {
    case screenRecording, accessibility
}

public enum RecoveryAction: Sendable, Equatable {
    case openSystemSettings(SystemSettingsPane)
    case route(AppRoute)
    case retry
    case none
}

public enum MessagePresentation: String, Sendable, Equatable { case banner, alert, silent }

public struct UserMessage: Sendable, Equatable {
    public let titleKey: String
    public let suggestionKey: String
    public let recovery: RecoveryAction?
    public let presentation: MessagePresentation

    public init(titleKey: String, suggestionKey: String, recovery: RecoveryAction?, presentation: MessagePresentation) {
        self.titleKey = titleKey
        self.suggestionKey = suggestionKey
        self.recovery = recovery
        self.presentation = presentation
    }
}

extension AppError {
    /// Identifier of the leaf case; the base of both localization keys.
    public var leafKey: String {
        switch self {
        case .permission(let e): "permission.\(e.rawValue)"
        case .capture(let e):
            switch e {
            case .noDisplays: "capture.noDisplays"
            case .displayDisconnected: "capture.displayDisconnected"
            case .timedOut: "capture.timedOut"
            case .topologyChanged: "capture.topologyChanged"
            case .selectionTooSmall: "capture.selectionTooSmall"
            case .selectionOutOfBounds: "capture.selectionOutOfBounds"
            case .outputTooLarge: "capture.outputTooLarge"
            case .sessionBusy: "capture.sessionBusy"
            }
        case .engine(let e):
            switch e {
            case .notConfigured: "engine.notConfigured"
            case .credentialLocked: "engine.credentialLocked"
            case .authenticationFailed: "engine.authenticationFailed"
            case .rateLimited: "engine.rateLimited"
            case .timedOut: "engine.timedOut"
            case .unreachable: "engine.unreachable"
            case .invalidResponse: "engine.invalidResponse"
            case .unavailableOnThisOS: "engine.unavailableOnThisOS"
            case .assetsMissing: "engine.assetsMissing"
            case .quotaExceeded: "engine.quotaExceeded"
            }
        case .recognition(let e):
            switch e {
            case .regionOutOfBounds: "recognition.regionOutOfBounds"
            case .imageUnreadable: "recognition.imageUnreadable"
            }
        case .translation(let e):
            switch e {
            case .allEnginesFailed: "translation.allEnginesFailed"
            case .noTranslatableText: "translation.noTranslatableText"
            case .unsupportedPair: "translation.unsupportedPair"
            }
        case .render(let e):
            switch e {
            case .canvasTooLarge: "render.canvasTooLarge"
            case .contextUnavailable: "render.contextUnavailable"
            }
        case .export(let e):
            switch e {
            case .invalidLocation: "export.invalidLocation"
            case .diskFull: "export.diskFull"
            case .encodingFailed: "export.encodingFailed"
            case .clipboardWriteFailed: "export.clipboardWriteFailed"
            }
        case .upload(let e):
            switch e {
            case .notConfigured: "upload.notConfigured"
            case .rejected: "upload.rejected"
            case .network: "upload.network"
            }
        case .textInput(let e):
            switch e {
            case .noSelection: "textInput.noSelection"
            case .targetChanged: "textInput.targetChanged"
            case .targetUnavailable: "textInput.targetUnavailable"
            case .notVerified: "textInput.notVerified"
            }
        case .hotkey(let e):
            switch e {
            case .registrationFailed: "hotkey.registrationFailed"
            case .conflict: "hotkey.conflict"
            }
        case .persistence(let e):
            switch e {
            case .storeUnavailable: "persistence.storeUnavailable"
            case .migrationFailed: "persistence.migrationFailed"
            case .writeFailed: "persistence.writeFailed"
            }
        case .cancelled: "cancelled"
        case .invariant: "invariant"
        }
    }

    /// Exactly one message per leaf case (SPEC §01 §7.2).
    public var userMessage: UserMessage {
        let base = "error.\(leafKey)"
        return UserMessage(
            titleKey: base + ".title", suggestionKey: base + ".suggestion",
            recovery: recovery, presentation: presentation
        )
    }

    private var recovery: RecoveryAction? {
        switch self {
        case .permission(.screenRecordingDenied): .openSystemSettings(.screenRecording)
        case .permission(.accessibilityDenied): .openSystemSettings(.accessibility)
        case .engine(.notConfigured), .engine(.authenticationFailed), .engine(.assetsMissing),
             .engine(.unavailableOnThisOS), .translation(.allEnginesFailed), .translation(.unsupportedPair):
            .route(.openSettings(.engines))
        case .engine(.credentialLocked): .route(.openSettings(.engines))
        case .engine(.rateLimited), .engine(.timedOut), .engine(.unreachable), .engine(.invalidResponse),
             .engine(.quotaExceeded), .capture(.timedOut), .upload(.network):
            .retry
        case .export(.invalidLocation), .export(.diskFull): .route(.openSettings(.general))
        case .upload(.notConfigured), .upload(.rejected): .route(.openSettings(.imageHost))
        case .hotkey: .route(.openSettings(.shortcuts))
        default: nil
        }
    }

    private var presentation: MessagePresentation {
        switch self {
        case .cancelled: .silent
        case .permission, .persistence, .invariant, .hotkey: .alert
        default: .banner
        }
    }

    /// One representative value per leaf case; used by completeness tests and the l10n gate.
    public static let allLeafSamples: [AppError] = [
        .permission(.screenRecordingDenied), .permission(.accessibilityDenied),
        .capture(.noDisplays), .capture(.displayDisconnected("X")), .capture(.timedOut), .capture(.topologyChanged),
        .capture(.selectionTooSmall), .capture(.selectionOutOfBounds), .capture(.outputTooLarge), .capture(.sessionBusy),
        .engine(.notConfigured(.mtran)), .engine(.credentialLocked), .engine(.authenticationFailed(.mtran)),
        .engine(.rateLimited(.mtran, retryAfter: nil)), .engine(.timedOut(.mtran)), .engine(.unreachable(.mtran)),
        .engine(.invalidResponse(.mtran, detail: "")), .engine(.unavailableOnThisOS(.appleTranslation, minimum: OSVersion(26))),
        .engine(.assetsMissing(.paddleLocal)), .engine(.quotaExceeded(.mtran)),
        .recognition(.regionOutOfBounds), .recognition(.imageUnreadable),
        .translation(.allEnginesFailed([])), .translation(.noTranslatableText), .translation(.unsupportedPair),
        .render(.canvasTooLarge), .render(.contextUnavailable),
        .export(.invalidLocation), .export(.diskFull), .export(.encodingFailed), .export(.clipboardWriteFailed),
        .upload(.notConfigured), .upload(.rejected(status: 403)), .upload(.network),
        .textInput(.noSelection), .textInput(.targetChanged), .textInput(.targetUnavailable), .textInput(.notVerified),
        .hotkey(.registrationFailed), .hotkey(.conflict(with: "X")),
        .persistence(.storeUnavailable), .persistence(.migrationFailed), .persistence(.writeFailed),
        .cancelled, .invariant("x"),
    ]
}

/// A malformed positional batch may be retried once before falling back to the next engine.
public enum PositionalResponseError {
    public static let mismatch = "mismatched positional translation response"
}
