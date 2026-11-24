import Foundation
import Testing
import TFDomain
import TFLocalization
@testable import TFWorkspaceUI

/// Every AppError leaf has a title and a suggestion in all ten languages (SPEC §01 §7.2, §05 §7 item 5).
@Suite("Error messages")
@MainActor
struct ErrorMessageTests {
    @Test(arguments: Localizer.supportedLanguages)
    func everyLeafIsLocalized(language: String) {
        let table = LocalizationTable(language: language)
        for error in AppError.allLeafSamples {
            let message = error.userMessage
            #expect(table.contains(message.titleKey), "\(language) missing \(message.titleKey)")
            #expect(table.contains(message.suggestionKey), "\(language) missing \(message.suggestionKey)")
        }
    }

    @Test func allEnginesFailedListsEachEngine() {
        let l10n = Localizer(preference: "en")
        let error = AppError.translation(.allEnginesFailed([
            EngineFailure(engine: .deepl, reason: .engine(.authenticationFailed(.deepl))),
            EngineFailure(engine: .mtran, reason: .engine(.unreachable(.mtran))),
        ]))
        let text = LocalizedErrorText(error, localizer: l10n)
        #expect(text.title == "Translation failed")
        #expect(text.suggestion.contains("DeepL"))
        #expect(text.suggestion.contains("MTranServer"))
        #expect(text.recoveryTitle == "Open Settings")
    }

    @Test func engineNamesResolve() {
        let l10n = Localizer(preference: "zh-Hans")
        #expect(EngineNames.name(.appleTranslation, localizer: l10n) == "Apple 翻译")
        let instance = CompatibleInstance(name: "My LLM")
        #expect(EngineNames.name(instance.engineID, localizer: l10n, instances: [instance]) == "My LLM")
    }
}
