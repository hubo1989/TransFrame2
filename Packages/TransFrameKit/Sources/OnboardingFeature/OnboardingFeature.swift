import AppKit
import Observation
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization
import TFWorkspaceUI

@MainActor
public protocol OnboardingCoordinating: AnyObject {
    func show(onFinish: @escaping () -> Void)
}

// MARK: - Model (ONB-01…ONB-04)

@MainActor
@Observable
public final class OnboardingViewModel {
    public enum Step: Int, CaseIterable { case welcome, permissions, complete }

    public private(set) var step: Step = .welcome
    public private(set) var granted: [PermissionKind: Bool] = [:]
    public private(set) var isGuiding: PermissionKind?

    @ObservationIgnored private let permissions: any PermissionChecking & PermissionGuiding
    @ObservationIgnored private let settings: any SettingsProviding
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored var onFinish: (() -> Void)?

    public init(permissions: any PermissionChecking & PermissionGuiding, settings: any SettingsProviding, appVersion: String) {
        self.permissions = permissions
        self.settings = settings
        self.appVersion = appVersion
    }

    public var skippedPermissions: [PermissionKind] { PermissionKind.allCases.filter { granted[$0] != true } }
    public var canGoBack: Bool { step != .welcome }

    public func refresh() async {
        for kind in PermissionKind.allCases { granted[kind] = await permissions.isGranted(kind) }
    }

    public func next() {
        guard let next = Step(rawValue: step.rawValue + 1) else { finish(); return }
        step = next
    }

    public func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    public func grant(_ kind: PermissionKind, from frame: CGRect?) async {
        isGuiding = kind
        _ = await permissions.guide(kind, from: frame)
        isGuiding = nil
        await refresh()
    }

    public func finish() {
        settings.onboarding.completed = true
        settings.onboarding.completedVersion = appVersion
        onFinish?()
    }
}

// MARK: - Coordinator

@MainActor
public final class OnboardingCoordinator: NSObject, OnboardingCoordinating, NSWindowDelegate {
    private let permissions: any PermissionChecking & PermissionGuiding
    private let settings: any SettingsProviding
    private let localizer: Localizer
    private let appVersion: String
    private var window: NSWindow?
    private var finish: (() -> Void)?

    public init(permissions: any PermissionChecking & PermissionGuiding, settings: any SettingsProviding, localizer: Localizer, appVersion: String) {
        self.permissions = permissions
        self.settings = settings
        self.localizer = localizer
        self.appVersion = appVersion
    }

    public func show(onFinish: @escaping () -> Void) {
        if let window { WindowFactory.present(window); return }
        finish = onFinish
        let model = OnboardingViewModel(permissions: permissions, settings: settings, appVersion: appVersion)
        model.onFinish = { [weak self] in self?.complete() }
        let window = WindowFactory.makeWindow(
            title: localizer[.onboardingTitle], content: OnboardingView(model: model).localized(localizer),
            size: NSSize(width: 560, height: 460), style: [.titled, .closable, .fullSizeContentView]
        )
        window.titlebarAppearsTransparent = true
        window.delegate = self
        self.window = window
        WindowFactory.present(window)
    }

    private func complete() {
        let callback = finish
        finish = nil
        window?.close()
        callback?()
    }

    /// Closing the window counts as finishing: the updater still starts afterwards (APP-07).
    public func windowWillClose(_ notification: Notification) {
        window = nil
        if let callback = finish {
            finish = nil
            settings.onboarding.completed = true
            callback()
        }
    }
}

// MARK: - Views

struct OnboardingView: View {
    @Bindable var model: OnboardingViewModel
    @Environment(Localizer.self) private var l10n
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: DS.Space.s6) {
            Group {
                switch model.step {
                case .welcome: WelcomeStep()
                case .permissions: PermissionsStep(model: model)
                case .complete: CompleteStep(skipped: model.skippedPermissions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .animation(DS.Motion.animation(DS.Motion.smooth, reduceMotion: reduceMotion), value: model.step)

            HStack {
                StepIndicator(current: model.step.rawValue, count: OnboardingViewModel.Step.allCases.count)
                Spacer()
                if model.canGoBack {
                    Button(l10n[.onboardingBack]) { model.back() }.keyboardShortcut(.cancelAction)
                }
                Button(model.step == .complete ? l10n[.onboardingStart] : l10n[.onboardingContinue]) { model.next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.s7)
        .task { await model.refresh() }
    }
}

private struct StepIndicator: View {
    let current: Int
    let count: Int
    @Environment(Localizer.self) private var l10n

    var body: some View {
        HStack(spacing: DS.Space.s1) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(l10n.string(.onboardingStepOf, current + 1, count))
    }
}

private struct WelcomeStep: View {
    @Environment(Localizer.self) private var l10n

    var body: some View {
        VStack(spacing: DS.Space.s4) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96).accessibilityHidden(true)
            Text(l10n[.onboardingWelcomeTitle]).font(DS.Typography.hero)
            Text(l10n[.onboardingWelcomeMessage]).font(DS.Typography.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                Label(l10n[.onboardingWelcomeCapture], systemImage: "viewfinder")
                Label(l10n[.onboardingWelcomeTranslate], systemImage: "character.bubble")
                Label(l10n[.onboardingWelcomeText], systemImage: "text.cursor")
            }
            .font(DS.Typography.body)
        }
    }
}

private struct PermissionsStep: View {
    @Bindable var model: OnboardingViewModel
    @Environment(Localizer.self) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text(l10n[.onboardingPermissionsTitle]).font(DS.Typography.title)
            Text(l10n[.onboardingPermissionsMessage]).foregroundStyle(.secondary)
            ForEach(PermissionKind.allCases, id: \.self) { kind in
                PermissionCard(kind: kind, granted: model.granted[kind] == true, busy: model.isGuiding == kind) { frame in
                    Task { await model.grant(kind, from: frame) }
                }
            }
            Text(l10n[.onboardingPermissionsSkipHint]).font(DS.Typography.caption).foregroundStyle(.secondary)
        }
    }
}

private struct PermissionCard: View {
    let kind: PermissionKind
    let granted: Bool
    let busy: Bool
    let grant: (CGRect?) -> Void
    @Environment(Localizer.self) private var l10n

    var body: some View {
        Card {
            HStack(spacing: DS.Space.s3) {
                Image(systemName: kind == .screenRecording ? "rectangle.dashed.badge.record" : "accessibility")
                    .font(DS.Typography.title)
                    .foregroundStyle(granted ? DS.Palette.statusOK : DS.Palette.statusWarn)
                    .frame(width: DS.Space.s7)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                    Text(kind == .screenRecording ? l10n[.permissionScreenRecording] : l10n[.permissionAccessibility]).font(DS.Typography.section)
                    Text(kind == .screenRecording ? l10n[.permissionScreenRecordingDetail] : l10n[.permissionAccessibilityDetail])
                        .font(DS.Typography.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if granted {
                    StatusDot(.ok, label: l10n[.permissionGranted])
                } else if busy {
                    StatusDot(.busy, label: l10n[.onboardingWaitingForPermission])
                } else {
                    Button(l10n[.permissionGrant]) { grant(NSApp.keyWindow?.frame) }
                }
            }
        }
    }
}

private struct CompleteStep: View {
    let skipped: [PermissionKind]
    @Environment(Localizer.self) private var l10n

    var body: some View {
        VStack(spacing: DS.Space.s4) {
            Image(systemName: "checkmark.seal.fill").font(DS.Typography.illustration).foregroundStyle(DS.Palette.statusOK).accessibilityHidden(true)
            Text(l10n[.onboardingCompleteTitle]).font(DS.Typography.hero)
            Text(l10n[.onboardingCompleteMessage]).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !skipped.isEmpty {
                Card {
                    Label {
                        VStack(alignment: .leading, spacing: DS.Space.s1) {
                            Text(l10n[.onboardingCompleteSkippedTitle]).font(DS.Typography.section)
                            ForEach(skipped, id: \.self) { kind in
                                Text(kind == .screenRecording ? l10n[.onboardingCompleteSkippedScreen] : l10n[.onboardingCompleteSkippedAccessibility])
                                    .font(DS.Typography.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Palette.statusWarn)
                    }
                }
            }
        }
    }
}
