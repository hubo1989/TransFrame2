import CryptoKit
import Foundation
import NaturalLanguage
import os
import TFDomain
import TFNetworkInfra

/// Reads a secret on demand; nil when absent.
public typealias SecretReader = @Sendable (CredentialRef) async throws(AppError) -> String?

// MARK: - MTranServer (TRN-02)

struct MTranServerEngine: TranslationEngine {
    let descriptor: EngineDescriptor
    let endpoint: String
    let transport: any HTTPTransport
    let token: @Sendable () async throws(AppError) -> String?

    func translate(_ batch: TranslationBatch) async throws(AppError) -> [TranslatedUnit] {
        guard let url = Endpoint.url(endpoint, appending: "/translate") else { throw .engine(.notConfigured(descriptor.id)) }
        var results: [TranslatedUnit] = []
        let key = try await token()
        for unit in batch.units {
            try Task.checkCancellation(engine: descriptor.id)
            var body: [String: Any] = ["text": unit.text, "to": MTranLanguage.code(batch.to)]
            body["from"] = batch.from.map(MTranLanguage.code) ?? "auto"
            var headers = ["Content-Type": "application/json"]
            if let key, !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
            let request = HTTPRequest(url: url, method: .post, headers: headers, body: try? JSONSerialization.data(withJSONObject: body), timeout: descriptor.limits.timeout)
            let response = try await transport.send(request, engine: descriptor.id)
            try HTTPStatusMapping.check(response, engine: descriptor.id)
            let json = try HTTPStatusMapping.json(response, engine: descriptor.id)
            results.append(TranslatedUnit(id: unit.id, text: (json["result"] as? String) ?? (json["translatedText"] as? String)))
        }
        return results
    }
}

enum MTranLanguage {
    static func code(_ language: LanguageCode) -> String {
        switch language.bcp47 {
        case "zh-Hans": "zh-Hans"
        case "zh-Hant": "zh-Hant"
        default: language.primary
        }
    }
}

// MARK: - Google, DeepL, Baidu (TRN-05)

struct GoogleEngine: TranslationEngine {
    let descriptor: EngineDescriptor
    let endpoint: String
    let transport: any HTTPTransport
    let key: @Sendable () async throws(AppError) -> String?

    func translate(_ batch: TranslationBatch) async throws(AppError) -> [TranslatedUnit] {
        guard let key = try await key(), !key.isEmpty else { throw .engine(.notConfigured(descriptor.id)) }
        guard let url = URL(string: endpoint + "?key=\(key)") else { throw .engine(.notConfigured(descriptor.id)) }
        var body: [String: Any] = ["q": batch.units.map(\.text), "target": batch.to.bcp47, "format": "text"]
        if let from = batch.from { body["source"] = from.bcp47 }
        let request = HTTPRequest(url: url, method: .post, headers: ["Content-Type": "application/json"], body: try? JSONSerialization.data(withJSONObject: body), timeout: descriptor.limits.timeout)
        let response = try await transport.send(request, engine: descriptor.id)
        try HTTPStatusMapping.check(response, engine: descriptor.id)
        let json = try HTTPStatusMapping.json(response, engine: descriptor.id)
        let items = ((json["data"] as? [String: Any])?["translations"] as? [[String: Any]]) ?? []
        return zip(batch.units, items).map { unit, item in
            TranslatedUnit(id: unit.id, text: (item["translatedText"] as? String).map(HTMLEntities.decode), detectedSource: (item["detectedSourceLanguage"] as? String).map(LanguageCode.init))
        }
    }
}

struct DeepLEngine: TranslationEngine {
    let descriptor: EngineDescriptor
    let endpoint: String
    let transport: any HTTPTransport
    let key: @Sendable () async throws(AppError) -> String?

    func translate(_ batch: TranslationBatch) async throws(AppError) -> [TranslatedUnit] {
        guard let key = try await key(), !key.isEmpty else { throw .engine(.notConfigured(descriptor.id)) }
        let base = key.hasSuffix(":fx") ? "https://api-free.deepl.com/v2" : (endpoint.contains("deepl.com") ? "https://api.deepl.com/v2" : endpoint)
        guard let url = Endpoint.url(base, appending: "/translate") else { throw .engine(.notConfigured(descriptor.id)) }
        var body: [String: Any] = ["text": batch.units.map(\.text), "target_lang": Self.code(batch.to, target: true)]
        if let from = batch.from { body["source_lang"] = Self.code(from, target: false) }
        let request = HTTPRequest(
            url: url, method: .post, headers: ["Content-Type": "application/json", "Authorization": "DeepL-Auth-Key \(key)"],
            body: try? JSONSerialization.data(withJSONObject: body), timeout: descriptor.limits.timeout
        )
        let response = try await transport.send(request, engine: descriptor.id)
        if response.status == 456 { throw .engine(.quotaExceeded(descriptor.id)) }
        try HTTPStatusMapping.check(response, engine: descriptor.id)
        let items = (try HTTPStatusMapping.json(response, engine: descriptor.id)["translations"] as? [[String: Any]]) ?? []
        return zip(batch.units, items).map { unit, item in
            TranslatedUnit(id: unit.id, text: item["text"] as? String, detectedSource: (item["detected_source_language"] as? String).map { LanguageCode($0.lowercased()) })
        }
    }

    static func code(_ language: LanguageCode, target: Bool) -> String {
        switch language.bcp47 {
        case "zh-Hans": return target ? "ZH-HANS" : "ZH"
        case "zh-Hant": return target ? "ZH-HANT" : "ZH"
        case "en": return target ? "EN-US" : "EN"
        case "pt": return target ? "PT-BR" : "PT"
        case "no": return "NB"
        default: return language.primary.uppercased()
        }
    }
}

struct BaiduEngine: TranslationEngine {
    let descriptor: EngineDescriptor
    let endpoint: String
    let appID: String
    let transport: any HTTPTransport
    let key: @Sendable () async throws(AppError) -> String?

    func translate(_ batch: TranslationBatch) async throws(AppError) -> [TranslatedUnit] {
        guard !appID.isEmpty, let secret = try await key(), !secret.isEmpty else { throw .engine(.notConfigured(descriptor.id)) }
        let query = batch.units.map { $0.text.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
        let salt = String(Int.random(in: 10_000...99_999))
        let sign = Insecure.MD5.hash(data: Data((appID + query + salt + secret).utf8)).map { String(format: "%02x", $0) }.joined()
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "q", value: query), URLQueryItem(name: "from", value: batch.from.map(Self.code) ?? "auto"),
            URLQueryItem(name: "to", value: Self.code(batch.to)), URLQueryItem(name: "appid", value: appID),
            URLQueryItem(name: "salt", value: salt), URLQueryItem(name: "sign", value: sign),
        ]
        guard let url = URL(string: endpoint) else { throw .engine(.notConfigured(descriptor.id)) }
        let body = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let request = HTTPRequest(url: url, method: .post, headers: ["Content-Type": "application/x-www-form-urlencoded"], body: body, timeout: descriptor.limits.timeout)
        let response = try await transport.send(request, engine: descriptor.id)
        try HTTPStatusMapping.check(response, engine: descriptor.id)
        let json = try HTTPStatusMapping.json(response, engine: descriptor.id)
        if let code = json["error_code"] as? String ?? (json["error_code"] as? Int).map(String.init) {
            switch code {
            case "52003", "54001": throw .engine(.authenticationFailed(descriptor.id))
            case "54003", "54005": throw .engine(.rateLimited(descriptor.id, retryAfter: .seconds(1)))
            case "54004": throw .engine(.quotaExceeded(descriptor.id))
            default: throw .engine(.invalidResponse(descriptor.id, detail: "error \(code)"))
            }
        }
        let items = (json["trans_result"] as? [[String: Any]]) ?? []
        // Baidu returns one item per input line; strict count check (no guessing, SPEC §02 §8).
        guard items.count == batch.units.count else {
            return batch.units.enumerated().map { index, unit in TranslatedUnit(id: unit.id, text: index < items.count ? items[index]["dst"] as? String : nil) }
        }
        return zip(batch.units, items).map { TranslatedUnit(id: $0.id, text: $1["dst"] as? String) }
    }

    static func code(_ language: LanguageCode) -> String {
        switch language.bcp47 {
        case "zh-Hans": "zh"
        case "zh-Hant": "cht"
        case "ja": "jp"
        case "ko": "kor"
        case "fr": "fra"
        case "es": "spa"
        case "ar": "ara"
        case "vi": "vie"
        case "da": "dan"
        case "fi": "fin"
        case "sv": "swe"
        case "ro": "rom"
        default: language.primary
        }
    }
}

enum HTMLEntities {
    static func decode(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }
}

extension Task where Success == Never, Failure == Never {
    static func checkCancellation(engine: EngineID) throws(AppError) {
        if Task.isCancelled { throw .cancelled }
    }
}

// MARK: - Language models (TRN-03, TRN-04, TRN-06, TRN-13, TRN-16, TRN-17)

/// Batches units into JSON, asks for a JSON array back and checks ids one-to-one (no guessing).
struct LLMTranslationEngine: TranslationEngine {
    let descriptor: EngineDescriptor
    let client: LLMClient

    static let batchCharacters = 6_000

    func translate(_ batch: TranslationBatch) async throws(AppError) -> [TranslatedUnit] {
        var results: [TranslatedUnit] = []
        for chunk in LLMBatching.chunks(batch.units, maxCharacters: Self.batchCharacters) {
            try Task.checkCancellation(engine: descriptor.id)
            results += try await translateChunk(chunk, batch: batch)
        }
        return results
    }

    private func translateChunk(_ units: [TranslationUnit], batch: TranslationBatch) async throws(AppError) -> [TranslatedUnit] {
        let system = LLMPrompt.system(batch: batch)
        let payload = units.enumerated().map { ["id": "\($0.offset + 1)", "text": $0.element.text] }
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        let user = """
        Translate the "text" of every item. Reply with only a JSON array of objects {"id": "...", "translation": "..."} \
        in the same order and with the same ids.
        \(json)
        """
        let output = try await client.completeWithContinuation(system: system, messages: [LLMMessage(role: .user, text: user)], maxTokens: 8192)
        let parsed = LLMResponseParser.translations(from: output)
        guard !parsed.isEmpty || units.isEmpty else { throw .engine(.invalidResponse(descriptor.id, detail: "unparseable translation")) }
        return units.enumerated().map { index, unit in
            TranslatedUnit(id: unit.id, text: parsed["\(index + 1)"])
        }
    }
}

enum LLMBatching {
    static func chunks(_ units: [TranslationUnit], maxCharacters: Int) -> [[TranslationUnit]] {
        var chunks: [[TranslationUnit]] = []
        var current: [TranslationUnit] = []
        var size = 0
        for unit in units {
            if !current.isEmpty, size + unit.text.count > maxCharacters {
                chunks.append(current)
                current = []
                size = 0
            }
            current.append(unit)
            size += unit.text.count
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

enum LLMPrompt {
    static func system(batch: TranslationBatch) -> String {
        let template = batch.prompt?.template ?? PromptSettings.defaultTemplate
        let glossary = batch.glossary.isEmpty ? "" : "Always use these fixed translations:\n" + batch.glossary.map { "- \($0.source) → \($0.target)" }.joined(separator: "\n")
        var context = ""
        if let c = batch.context, c.appName != nil || c.windowTitle != nil {
            context = "Context: the text comes from \([c.appName, c.windowTitle].compactMap { $0 }.joined(separator: " — "))."
        }
        var tone = ""
        if let t = batch.tone {
            tone = switch t {
            case .formal: "Use a formal, polite tone."
            case .casual: "Use a casual, conversational tone."
            case .concise: "Be as concise as possible."
            }
        }
        let source = batch.from.map { Locale(identifier: "en").localizedString(forIdentifier: $0.bcp47) ?? $0.bcp47 } ?? "the detected source language"
        let target = Locale(identifier: "en").localizedString(forIdentifier: batch.to.bcp47) ?? batch.to.bcp47
        return template
            .replacingOccurrences(of: "{source_language}", with: source)
            .replacingOccurrences(of: "{target_language}", with: target)
            .replacingOccurrences(of: "{glossary}", with: glossary)
            .replacingOccurrences(of: "{context}", with: [context, tone].filter { !$0.isEmpty }.joined(separator: "\n"))
            .replacingOccurrences(of: "{text}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Tolerant parser for model output: strips code fences, accepts objects or arrays, returns id → translation.
enum LLMResponseParser {
    static func translations(from output: String) -> [String: String] {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = text.range(of: "```") {
            text = String(text[fence.upperBound...])
            if let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
            if let end = text.range(of: "```", options: .backwards) { text = String(text[..<end.lowerBound]) }
        }
        if let start = text.firstIndex(where: { $0 == "[" || $0 == "{" }) { text = String(text[start...]) }
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        let items: [[String: Any]] = (object as? [[String: Any]]) ?? ((object as? [String: Any])?["translations"] as? [[String: Any]]) ?? []
        var result: [String: String] = [:]
        for item in items {
            let id = (item["id"] as? String) ?? (item["id"] as? Int).map(String.init)
            if let id, let translation = (item["translation"] as? String) ?? (item["text"] as? String) { result[id] = translation }
        }
        return result
    }
}
