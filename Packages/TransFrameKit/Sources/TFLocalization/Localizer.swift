import Foundation
import Observation
import SwiftUI

/// Typed localization key. Static members are generated from the String Catalog
/// (`Scripts/l10n.py gen`), so a misspelled key fails to compile (ADR-0012).
public struct L10nKey: Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral value: String) { raw = value }
    public var description: String { raw }
}

/// Resolves keys against one language's compiled table. Pure and thread-safe.
public struct LocalizationTable: Sendable {
    public let language: String
    private let bundle: Bundle?
    private let fallback: Bundle?

    public init(language: String) {
        self.language = language
        bundle = Self.bundle(for: language)
        fallback = language == Localizer.developmentLanguage ? nil : Self.bundle(for: Localizer.developmentLanguage)
    }

    private static func bundle(for language: String) -> Bundle? {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj") ?? lprojPath(matching: language) else { return nil }
        return Bundle(path: path)
    }

    /// Some toolchains rename localization folders (`zh-hans.lproj`, `zh_Hans.lproj`); match case- and separator-insensitively.
    private static func lprojPath(matching language: String) -> String? {
        func normalized(_ name: String) -> String { name.lowercased().replacingOccurrences(of: "_", with: "-") }
        guard let root = Bundle.module.resourcePath, let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        let wanted = normalized(language)
        return items.first { $0.hasSuffix(".lproj") && normalized(String($0.dropLast(6))) == wanted }.map { root + "/" + $0 }
    }

    private static let missing = "\u{1}missing\u{1}"

    /// Returns the translation, falling back to English, then to the key itself.
    public func string(_ key: String) -> String {
        if let value = bundle?.localizedString(forKey: key, value: Self.missing, table: "Localizable"), value != Self.missing {
            return value
        }
        if let value = fallback?.localizedString(forKey: key, value: Self.missing, table: "Localizable"), value != Self.missing {
            return value
        }
        return key
    }

    public func contains(_ key: String) -> Bool {
        guard let value = bundle?.localizedString(forKey: key, value: Self.missing, table: "Localizable") else { return false }
        return value != Self.missing
    }

    public func format(_ key: String, _ arguments: [any CVarArg]) -> String {
        String(format: string(key), locale: Locale(identifier: language), arguments: arguments)
    }
}

/// The single entry point for UI text (SPEC §05 §7). Observable: views that read text re-render when
/// the language changes; native menus subscribe and rebuild. Never writes the system language keys.
@MainActor
@Observable
public final class Localizer {
    public nonisolated static let developmentLanguage = "en"
    public nonisolated static let supportedLanguages = ["en", "zh-Hans", "de", "es", "fr", "it", "ja", "ko", "pt", "ru"]

    /// nil follows the system.
    public private(set) var preference: String?
    public private(set) var language: String
    public private(set) var table: LocalizationTable
    /// Incremented on every change; menus and AppKit views observe it.
    public private(set) var revision = 0

    @ObservationIgnored private let preferredLanguages: @Sendable () -> [String]

    public init(preference: String?, preferredLanguages: @escaping @Sendable () -> [String] = { Locale.preferredLanguages }) {
        self.preferredLanguages = preferredLanguages
        self.preference = preference
        let resolved = Self.resolve(preference: preference, preferred: preferredLanguages())
        language = resolved
        table = LocalizationTable(language: resolved)
    }

    public func setPreference(_ preference: String?) {
        let resolved = Self.resolve(preference: preference, preferred: preferredLanguages())
        self.preference = preference
        guard resolved != language else { return }
        language = resolved
        table = LocalizationTable(language: resolved)
        revision += 1
    }

    public var locale: Locale { Locale(identifier: language) }

    public subscript(_ key: L10nKey) -> String { table.string(key.raw) }

    public func string(_ key: L10nKey) -> String { table.string(key.raw) }

    public func string(_ key: L10nKey, _ arguments: any CVarArg...) -> String { table.format(key.raw, arguments) }

    /// For keys that come from Domain values (error messages, engine names).
    public func string(rawKey: String) -> String { table.string(rawKey) }

    public func string(rawKey: String, _ arguments: any CVarArg...) -> String { table.format(rawKey, arguments) }

    /// Localized name of a language code via the system, in the current UI language.
    public func languageName(_ bcp47: String) -> String {
        locale.localizedString(forIdentifier: bcp47) ?? bcp47
    }

    /// Native name of an interface language, e.g. "日本語".
    public nonisolated static func nativeName(_ bcp47: String) -> String {
        Locale(identifier: bcp47).localizedString(forIdentifier: bcp47)?.capitalized(with: Locale(identifier: bcp47)) ?? bcp47
    }

    /// First supported language from the preference or the system list; English otherwise (L10N-02).
    public nonisolated static func resolve(preference: String?, preferred: [String]) -> String {
        if let preference, let match = match(preference) { return match }
        for identifier in preferred { if let match = match(identifier) { return match } }
        return developmentLanguage
    }

    private nonisolated static func match(_ identifier: String) -> String? {
        if supportedLanguages.contains(identifier) { return identifier }
        let locale = Locale(identifier: identifier)
        let code = locale.language.languageCode?.identifier ?? identifier
        if code == "zh" {
            let script = locale.language.script?.identifier
            let region = locale.region?.identifier
            // Only Simplified Chinese is shipped; Traditional-script locales fall back to English.
            if script == "Hant" || region == "TW" || region == "HK" || region == "MO" { return nil }
            return "zh-Hans"
        }
        return supportedLanguages.first { $0 == code }
    }
}

public extension View {
    /// Injects the localizer and the matching locale for system formatters.
    func localized(_ localizer: Localizer) -> some View {
        environment(localizer).environment(\.locale, localizer.locale)
    }
}
