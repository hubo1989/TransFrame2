import Foundation
import Testing
@testable import TFLocalization

@Suite("Localizer")
@MainActor
struct LocalizerTests {
    @Test(arguments: [
        (nil as String?, ["ja-JP"], "ja"),
        (nil, ["zh-Hans-CN", "en"], "zh-Hans"),
        (nil, ["zh-Hant-TW", "fr-FR"], "fr"),
        (nil, ["sv-SE"], "en"),
        ("de", ["ja-JP"], "de"),
        ("xx", ["ko-KR"], "ko"),
        (nil, ["pt-BR"], "pt"),
    ])
    func resolution(preference: String?, preferred: [String], expected: String) {
        #expect(Localizer.resolve(preference: preference, preferred: preferred) == expected)
    }

    @Test func switchingLanguageChangesEveryResolvedString() {
        let localizer = Localizer(preference: "en", preferredLanguages: { ["en"] })
        let english = localizer[.menuCaptureRegion]
        let revision = localizer.revision
        localizer.setPreference("zh-Hans")
        #expect(localizer.language == "zh-Hans")
        #expect(localizer.revision == revision + 1)
        #expect(localizer[.menuCaptureRegion] != english)
        #expect(localizer[.menuCaptureRegion] == "区域截图")
        localizer.setPreference(nil)
        #expect(localizer.language == "en")
        #expect(localizer[.menuCaptureRegion] == english)
    }

    @Test func formatsPlaceholdersWithLocale() {
        let localizer = Localizer(preference: "en")
        #expect(localizer.string(.menuPinsCount, 3) == "Pinned Images (3)")
        #expect(localizer.string(.aboutVersion, "2.0.0", "7") == "Version 2.0.0 (7)")
    }

    @Test func unknownKeysFallBackToTheKey() {
        let localizer = Localizer(preference: "en")
        #expect(localizer.string(rawKey: "does.not.exist") == "does.not.exist")
    }

    @Test(arguments: Localizer.supportedLanguages)
    func everyLanguageHasEveryKey(language: String) throws {
        let catalog = try CatalogFile.load()
        let table = LocalizationTable(language: language)
        let missing = catalog.filter { !table.contains($0) }
        #expect(missing.isEmpty, "\(language) is missing \(missing.count) keys, e.g. \(missing.prefix(5))")
    }
}

/// Reads key names from the catalog source so the test covers keys not yet referenced in code.
enum CatalogFile {
    static func load() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/TFLocalization/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((json?["strings"] as? [String: Any]) ?? [:]).keys.sorted()
    }
}
