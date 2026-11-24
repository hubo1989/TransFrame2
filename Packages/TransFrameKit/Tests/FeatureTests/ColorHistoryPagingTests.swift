import Foundation
import Testing
import TFDesignSystem
import TFDomain
import TFDomainTestSupport
import TFLocalization
import TFWorkspaceUI
@testable import HistoryFeature

@MainActor
private final class SilentErrors: ErrorPresenting {
    func present(_ error: AppError, near anchor: CGPoint?, retry: (() -> Void)?) {}
    func toast(_ model: ToastModel, near anchor: CGPoint?, action: (() -> Void)?) {}
}

private struct NoColorPick: ColorPickWorkflow {
    func pickAndCopy(settings: SettingsSnapshot) async throws(AppError) -> RGBA? { nil }
    func pickForAnnotation(settings: SettingsSnapshot) async -> RGBA? { nil }
    func copy(_ color: RGBA, format: ColorCopyFormat) async throws(AppError) {}
}

/// Color history pages like translation history, so colors past the first page stay reachable (COL-05).
@Suite("Color history paging")
@MainActor
struct ColorHistoryPagingTests {
    @Test func olderColorsLoadAsTheGridReachesItsEnd() async throws {
        let workflow = FakeHistoryWorkflow()
        for i in 0..<1_200 {
            await workflow.record(HistoryEntry(kind: .color, source: "", result: String(format: "#%06X", i)), settings: SettingsSnapshot())
        }
        let model = ColorHistoryModel(
            workflow: workflow, colors: NoColorPick(), settings: FakeSettings(), errors: SilentErrors(), localizer: Localizer(preference: "en"))
        model.reload()
        for _ in 0..<100 where model.entries.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.entries.count == HistoryQuery.colors.limit)
        #expect(model.hasMore)
        while model.hasMore {
            let before = model.entries.count
            model.loadMore()
            for _ in 0..<100 where model.entries.count == before { try await Task.sleep(for: .milliseconds(10)) }
            #expect(model.entries.count > before)
        }
        #expect(model.entries.count == 1_200)
        #expect(Set(model.entries.map(\.id)).count == 1_200)
    }
}
