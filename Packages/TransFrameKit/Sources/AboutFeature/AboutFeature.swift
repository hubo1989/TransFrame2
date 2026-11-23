import AppKit
import SwiftUI
import TFDesignSystem
import TFDomain
import TFLocalization
import TFWorkspaceUI

@MainActor
public protocol AboutCoordinating: AnyObject {
    func show()
}

public struct AppInfo: Sendable, Equatable {
    public let version: String
    public let build: String
    public let copyright: String
    public let projectURL: URL?

    public init(version: String, build: String, copyright: String, projectURL: URL?) {
        self.version = version
        self.build = build
        self.copyright = copyright
        self.projectURL = projectURL
    }
}

public struct Acknowledgement: Sendable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let license: String
    public let url: URL

    /// Runtime dependencies only (test-only libraries are not shipped).
    public static let shipped: [Acknowledgement] = [
        Acknowledgement(name: "Sparkle", license: "MIT", url: URL(string: "https://github.com/sparkle-project/Sparkle")!),
        Acknowledgement(name: "PermissionFlow", license: "MIT", url: URL(string: "https://github.com/jaywcjlove/PermissionFlow")!),
    ]
}

/// About window: version, copyright, license, project link, acknowledgements, update check (ONB-05, ONB-06).
@MainActor
public final class AboutCoordinator: NSObject, AboutCoordinating, NSWindowDelegate {
    private let info: AppInfo
    private let localizer: Localizer
    private let router: any AppRouting
    private let canCheckForUpdates: () -> Bool
    private var window: NSWindow?

    public init(info: AppInfo, localizer: Localizer, router: any AppRouting, canCheckForUpdates: @escaping () -> Bool) {
        self.info = info
        self.localizer = localizer
        self.router = router
        self.canCheckForUpdates = canCheckForUpdates
    }

    public func show() {
        if let window { WindowFactory.present(window); return }
        let view = AboutView(info: info, canCheckForUpdates: canCheckForUpdates()) { [weak self] in
            self?.router.route(.checkForUpdates)
        }
        let window = WindowFactory.makeWindow(
            title: localizer[.menuAbout], content: view.localized(localizer), size: NSSize(width: 420, height: 440),
            style: [.titled, .closable, .fullSizeContentView]
        )
        window.titlebarAppearsTransparent = true
        window.delegate = self
        self.window = window
        WindowFactory.present(window)
    }

    public func windowWillClose(_ notification: Notification) { window = nil }
}

struct AboutView: View {
    let info: AppInfo
    let canCheckForUpdates: Bool
    let checkForUpdates: () -> Void
    @Environment(Localizer.self) private var l10n
    @State private var showsAcknowledgements = false

    var body: some View {
        VStack(spacing: DS.Space.s3) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96).accessibilityHidden(true)
            Text(l10n[.appName]).font(DS.Typography.title)
            Text(l10n.string(.aboutVersion, info.version, info.build)).font(DS.Typography.secondary).foregroundStyle(.secondary).textSelection(.enabled)
            Text(l10n[.aboutTagline]).font(DS.Typography.body).multilineTextAlignment(.center)
            HStack(spacing: DS.Space.s3) {
                if canCheckForUpdates {
                    Button(l10n[.aboutCheckForUpdates], action: checkForUpdates)
                }
                if let url = info.projectURL {
                    Link(l10n[.aboutProject], destination: url)
                }
            }
            Button(l10n[.aboutAcknowledgements]) { showsAcknowledgements.toggle() }
                .buttonStyle(.link)
            if showsAcknowledgements {
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    ForEach(Acknowledgement.shipped) { item in
                        HStack {
                            Link(item.name, destination: item.url)
                            Spacer()
                            Text(verbatim: item.license).font(DS.Typography.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(DS.Space.s3)
                .background(DS.Palette.surfaceControl, in: .rect(cornerRadius: DS.Radius.m))
            }
            Spacer(minLength: 0)
            Text(verbatim: info.copyright).font(DS.Typography.caption).foregroundStyle(.secondary)
            Text(l10n[.aboutLicense]).font(DS.Typography.micro).foregroundStyle(.secondary)
        }
        .padding(DS.Space.s6)
        .frame(maxWidth: .infinity)
    }
}
