import AppKit
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization

// MARK: - Error presentation (SPEC §01 §7.5): banners for recoverable errors, alerts for blocking ones.

@MainActor
public protocol ErrorPresenting: AnyObject {
    /// Presents an error with its recovery action. `.cancelled` is silent. `retry` reruns the failed operation; without it a
    /// retryable error shows no Retry button (a button that does nothing is worse than none).
    func present(_ error: AppError, near anchor: CGPoint?, retry: (() -> Void)?)
    func toast(_ model: ToastModel, near anchor: CGPoint?, action: (() -> Void)?)
}

public extension ErrorPresenting {
    func present(_ error: AppError, near anchor: CGPoint?) { present(error, near: anchor, retry: nil) }
    func present(_ error: any Error, near anchor: CGPoint?, retry: (() -> Void)?) { present(AppError.from(error), near: anchor, retry: retry) }
    func toast(_ model: ToastModel, near anchor: CGPoint?) { toast(model, near: anchor, action: nil) }
    /// Presents any thrown error, mapping it to `AppError` first.
    func present(_ error: any Error, near anchor: CGPoint?) { present(AppError.from(error), near: anchor) }
}

/// Resolves a Domain error into localized title, suggestion and recovery button title.
public struct LocalizedErrorText: Equatable {
    public let title: String
    public let suggestion: String
    public let recoveryTitle: String?

    @MainActor
    public init(_ error: AppError, localizer: Localizer) {
        let message = error.userMessage
        title = localizer.string(rawKey: message.titleKey)
        var suggestion = localizer.string(rawKey: message.suggestionKey)
        switch error {
        case .translation(.allEnginesFailed(let failures)) where !failures.isEmpty:
            let lines = failures.map { failure in
                "• \(EngineNames.name(failure.engine, localizer: localizer)): \(localizer.string(rawKey: failure.reason.userMessage.titleKey))"
            }
            suggestion += "\n" + lines.joined(separator: "\n")
        case .engine(let engineError):
            if let engine = engineError.engine {
                suggestion = "\(EngineNames.name(engine, localizer: localizer)) — \(suggestion)"
            }
        case .capture(.displayDisconnected(let name)):
            suggestion = "\(name) — \(suggestion)"
        case .upload(.rejected(let status)):
            suggestion = "HTTP \(status) — \(suggestion)"
        default:
            break
        }
        self.suggestion = suggestion
        recoveryTitle = message.recovery.flatMap { Self.title(for: $0, localizer: localizer) }
    }

    private init(title: String, suggestion: String) {
        self.title = title
        self.suggestion = suggestion
        recoveryTitle = nil
    }

    /// The same text without a recovery button.
    var withoutRecovery: LocalizedErrorText { LocalizedErrorText(title: title, suggestion: suggestion) }

    @MainActor
    static func title(for recovery: RecoveryAction, localizer: Localizer) -> String? {
        switch recovery {
        case .openSystemSettings: localizer[.actionOpenSystemSettings]
        case .route(.openSettings): localizer[.actionOpenSettings]
        case .route: localizer[.actionOpen]
        case .retry: localizer[.actionRetry]
        case .none: nil
        }
    }
}

/// Standard presenter used by every feature; recovery actions go through the router.
@MainActor
public final class StandardErrorPresenter: ErrorPresenting {
    private let localizer: Localizer
    private let feedback: FeedbackCenter
    private let permissions: any PermissionGuiding
    private weak var router: (any AppRouting)?

    public init(localizer: Localizer, feedback: FeedbackCenter, permissions: any PermissionGuiding, router: (any AppRouting)?) {
        self.localizer = localizer
        self.feedback = feedback
        self.permissions = permissions
        self.router = router
    }

    public func attach(router: any AppRouting) { self.router = router }

    public func present(_ error: AppError, near anchor: CGPoint?, retry: (() -> Void)?) {
        let message = error.userMessage
        guard message.presentation != .silent else { return }
        let localized = LocalizedErrorText(error, localizer: localizer)
        let text = message.recovery == .retry && retry == nil ? localized.withoutRecovery : localized
        switch message.presentation {
        case .alert:
            var buttons = [AlertButton(localizer[.actionOk], role: .cancel)]
            if let recoveryTitle = text.recoveryTitle { buttons.insert(AlertButton(recoveryTitle), at: 0) }
            let choice = SystemAlert.present(title: text.title, message: text.suggestion, buttons: buttons)
            if text.recoveryTitle != nil, choice == 0 { perform(message.recovery, retry: retry) }
        case .banner:
            let model = ToastModel(.error, message: "\(text.title) — \(text.suggestion)", actionTitle: text.recoveryTitle)
            feedback.toast(model, near: anchor, duration: .seconds(5), action: text.recoveryTitle == nil ? nil : { [weak self] in
                self?.perform(message.recovery, retry: retry)
            })
        case .silent:
            break
        }
    }

    public func toast(_ model: ToastModel, near anchor: CGPoint?, action: (() -> Void)?) {
        feedback.toast(model, near: anchor, action: action)
    }

    private func perform(_ recovery: RecoveryAction?, retry: (() -> Void)?) {
        guard let recovery else { return }
        switch recovery {
        case .openSystemSettings(let pane): permissions.openSystemSettings(pane)
        case .route(let route): router?.route(route)
        case .retry: retry?()
        case .none: break
        }
    }
}

// MARK: - Engine and language names

@MainActor
public enum EngineNames {
    public static func name(_ id: EngineID, localizer: Localizer, instances: [CompatibleInstance] = []) -> String {
        if let uuid = id.compatibleInstanceID {
            return instances.first { $0.id == uuid }?.name ?? localizer[.engineNameCompatible]
        }
        return localizer.string(rawKey: "engine.name.\(id.raw)")
    }

    public static func name(_ descriptor: EngineDescriptor, localizer: Localizer) -> String {
        switch descriptor.name {
        case .localized(let key): localizer.string(rawKey: key)
        case .userDefined(let name): name
        }
    }
}

// MARK: - Window hosting

@MainActor
public enum WindowFactory {
    /// A standard titled window hosting SwiftUI content; remembers its frame when `autosaveName` is set.
    public static func makeWindow<Content: View>(
        title: String, content: Content, size: NSSize, minSize: NSSize? = nil, autosaveName: String? = nil,
        style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable], level: NSWindow.Level = .normal
    ) -> NSWindow {
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = style
        window.setContentSize(size)
        if let minSize { window.contentMinSize = minSize }
        window.level = level
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        if let autosaveName {
            window.setFrameAutosaveName(autosaveName)
            if !window.setFrameUsingName(autosaveName) { window.center() }
        } else {
            window.center()
        }
        return window
    }

    /// Activates the app and brings the window forward (menu-bar apps have no main window).
    public static func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
