import SwiftUI
import TFDomain
import TFLocalization

@MainActor
@Observable
public final class EnginesModel {
    @ObservationIgnored let deps: SettingsDependencies
    init(dependencies: SettingsDependencies) { deps = dependencies }
}

struct EnginesPage: View { let model: EnginesModel; var body: some View { EmptyView() } }
struct PromptsPage: View { let model: EnginesModel; var body: some View { EmptyView() } }
struct PrivacyPage: View { let model: SettingsViewModel; var body: some View { EmptyView() } }
struct AIPage: View { let model: EnginesModel; var body: some View { EmptyView() } }
struct GlossaryPage: View { let model: EnginesModel; var body: some View { EmptyView() } }
struct ImageHostPage: View { let model: EnginesModel; var body: some View { EmptyView() } }
