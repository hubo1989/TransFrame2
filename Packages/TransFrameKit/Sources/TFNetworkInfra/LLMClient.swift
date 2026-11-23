import Foundation
import TFDomain

/// Wire protocols for language-model engines: OpenAI-compatible (Chat or Responses), Anthropic, Gemini.
public enum LLMWire: String, Sendable {
    case openAIChat, openAIResponses, anthropic, gemini
}

public struct LLMMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public let role: Role
    public let text: String
    /// JPEG or PNG bytes for vision requests (only on user messages).
    public let image: Data?
    public let imageMIME: String

    public init(role: Role, text: String, image: Data? = nil, imageMIME: String = "image/jpeg") {
        self.role = role
        self.text = text
        self.image = image
        self.imageMIME = imageMIME
    }
}

public struct LLMCompletion: Sendable, Equatable {
    public let text: String
    /// The model stopped because of the output limit (OCR-11 continuation).
    public let truncated: Bool
}

/// One configured endpoint. Secrets are fetched per request and never cached here (SPEC §01 §5).
public struct LLMClient: Sendable {
    public let wire: LLMWire
    public let endpoint: String
    public let model: String
    public let engine: EngineID
    private let transport: any HTTPTransport
    private let apiKey: @Sendable () async throws(AppError) -> String?
    private let timeout: Duration

    public init(
        wire: LLMWire, endpoint: String, model: String, engine: EngineID, transport: any HTTPTransport,
        timeout: Duration = .seconds(90), apiKey: @escaping @Sendable () async throws(AppError) -> String?
    ) {
        self.wire = wire
        self.endpoint = endpoint
        self.model = model
        self.engine = engine
        self.transport = transport
        self.timeout = timeout
        self.apiKey = apiKey
    }

    public func complete(system: String, messages: [LLMMessage], maxTokens: Int = 4096, temperature: Double = 0.2) async throws(AppError) -> LLMCompletion {
        let key = try await apiKey()
        if key?.isEmpty ?? true, !Endpoint.isLoopback(endpoint) { throw .engine(.notConfigured(engine)) }
        let request = try buildRequest(system: system, messages: messages, maxTokens: maxTokens, temperature: temperature, key: key)
        let response = try await transport.send(request, engine: engine)
        try HTTPStatusMapping.check(response, engine: engine)
        return try parse(HTTPStatusMapping.json(response, engine: engine))
    }

    /// Lists models from the free `/models` endpoint (OCR-14, TRN-12); also used for health probes.
    public func listModels() async throws(AppError) -> [String] {
        let key = try await apiKey()
        var headers: [String: String] = [:]
        let url: URL?
        switch wire {
        case .openAIChat, .openAIResponses:
            url = Endpoint.url(endpoint, appending: "/models")
            if let key, !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
        case .anthropic:
            url = Endpoint.url(endpoint, appending: "/models")
            headers["x-api-key"] = key ?? ""
            headers["anthropic-version"] = "2023-06-01"
        case .gemini:
            url = Endpoint.url(endpoint, appending: "/models").flatMap { URL(string: $0.absoluteString + "?key=\(key ?? "")") }
        }
        guard let url else { throw .engine(.notConfigured(engine)) }
        let response = try await transport.send(HTTPRequest(url: url, headers: headers, timeout: EngineHealth.probeTimeout), engine: engine)
        try HTTPStatusMapping.check(response, engine: engine)
        let json = try HTTPStatusMapping.json(response, engine: engine)
        let items = (json["data"] as? [[String: Any]]) ?? (json["models"] as? [[String: Any]]) ?? []
        return items.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String).map { $0.replacingOccurrences(of: "models/", with: "") } }.sorted()
    }

    // MARK: Request building

    func buildRequest(system: String, messages: [LLMMessage], maxTokens: Int, temperature: Double, key: String?) throws(AppError) -> HTTPRequest {
        var headers = ["Content-Type": "application/json"]
        var body: [String: Any]
        let url: URL?
        switch wire {
        case .openAIChat:
            url = Endpoint.url(endpoint, appending: "/chat/completions")
            if let key, !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
            var payload: [[String: Any]] = [["role": "system", "content": system]]
            for message in messages {
                if let image = message.image {
                    payload.append(["role": message.role.rawValue, "content": [
                        ["type": "text", "text": message.text],
                        ["type": "image_url", "image_url": ["url": "data:\(message.imageMIME);base64,\(image.base64EncodedString())"]],
                    ]])
                } else {
                    payload.append(["role": message.role.rawValue, "content": message.text])
                }
            }
            body = ["model": model, "messages": payload, "max_tokens": maxTokens, "temperature": temperature]
        case .openAIResponses:
            url = Endpoint.url(endpoint, appending: "/responses")
            if let key, !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
            let input: [[String: Any]] = messages.map { message in
                var content: [[String: Any]] = [["type": message.role == .user ? "input_text" : "output_text", "text": message.text]]
                if let image = message.image {
                    content.append(["type": "input_image", "image_url": "data:\(message.imageMIME);base64,\(image.base64EncodedString())"])
                }
                return ["role": message.role.rawValue, "content": content]
            }
            body = ["model": model, "instructions": system, "input": input, "max_output_tokens": maxTokens, "temperature": temperature]
        case .anthropic:
            url = Endpoint.url(endpoint, appending: "/messages")
            headers["x-api-key"] = key ?? ""
            headers["anthropic-version"] = "2023-06-01"
            let payload: [[String: Any]] = messages.map { message in
                var content: [[String: Any]] = []
                if let image = message.image {
                    content.append(["type": "image", "source": ["type": "base64", "media_type": message.imageMIME, "data": image.base64EncodedString()]])
                }
                content.append(["type": "text", "text": message.text])
                return ["role": message.role.rawValue, "content": content]
            }
            body = ["model": model, "system": system, "messages": payload, "max_tokens": maxTokens, "temperature": temperature]
        case .gemini:
            url = Endpoint.url(endpoint, appending: "/models/\(model):generateContent").flatMap { URL(string: $0.absoluteString + "?key=\(key ?? "")") }
            let contents: [[String: Any]] = messages.map { message in
                var parts: [[String: Any]] = [["text": message.text]]
                if let image = message.image {
                    parts.append(["inline_data": ["mime_type": message.imageMIME, "data": image.base64EncodedString()]])
                }
                return ["role": message.role == .user ? "user" : "model", "parts": parts]
            }
            body = [
                "system_instruction": ["parts": [["text": system]]], "contents": contents,
                "generationConfig": ["maxOutputTokens": maxTokens, "temperature": temperature],
            ]
        }
        guard let url, let data = try? JSONSerialization.data(withJSONObject: body) else { throw .engine(.notConfigured(engine)) }
        return HTTPRequest(url: url, method: .post, headers: headers, body: data, timeout: timeout)
    }

    func parse(_ json: [String: Any]) throws(AppError) -> LLMCompletion {
        switch wire {
        case .openAIChat:
            guard let choice = (json["choices"] as? [[String: Any]])?.first else { throw .engine(.invalidResponse(engine, detail: "no choices")) }
            let message = choice["message"] as? [String: Any]
            let text = (message?["content"] as? String) ?? ""
            return LLMCompletion(text: text, truncated: (choice["finish_reason"] as? String) == "length")
        case .openAIResponses:
            if let text = json["output_text"] as? String {
                return LLMCompletion(text: text, truncated: (json["status"] as? String) == "incomplete")
            }
            let outputs = (json["output"] as? [[String: Any]]) ?? []
            let text = outputs.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }.compactMap { $0["text"] as? String }.joined()
            return LLMCompletion(text: text, truncated: (json["status"] as? String) == "incomplete")
        case .anthropic:
            let text = ((json["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
            return LLMCompletion(text: text, truncated: (json["stop_reason"] as? String) == "max_tokens")
        case .gemini:
            guard let candidate = (json["candidates"] as? [[String: Any]])?.first else { throw .engine(.invalidResponse(engine, detail: "no candidates")) }
            let parts = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            return LLMCompletion(text: parts.compactMap { $0["text"] as? String }.joined(), truncated: (candidate["finishReason"] as? String) == "MAX_TOKENS")
        }
    }

    /// Continues truncated output up to `maxContinuations` times and removes overlap (OCR-11).
    public func completeWithContinuation(system: String, messages: [LLMMessage], maxTokens: Int = 4096, maxContinuations: Int = 3) async throws(AppError) -> String {
        var transcript = messages
        var output = ""
        for attempt in 0...maxContinuations {
            let completion = try await complete(system: system, messages: transcript, maxTokens: maxTokens)
            output = attempt == 0 ? completion.text : ContinuationMerger.merge(output, completion.text)
            guard completion.truncated else { break }
            transcript.append(LLMMessage(role: .assistant, text: completion.text))
            transcript.append(LLMMessage(role: .user, text: "Continue exactly where you stopped. Do not repeat earlier content."))
        }
        return output
    }
}

public enum ContinuationMerger {
    /// Joins a continuation, dropping the longest suffix/prefix overlap (≥ 8 characters) or duplicated lines.
    public static func merge(_ first: String, _ next: String) -> String {
        let maxOverlap = min(first.count, next.count, 400)
        if maxOverlap >= 8 {
            for length in stride(from: maxOverlap, through: 8, by: -1) where first.hasSuffix(String(next.prefix(length))) {
                return first + next.dropFirst(length)
            }
        }
        let firstLines = Set(first.split(separator: "\n").suffix(5).map { $0.trimmingCharacters(in: .whitespaces) })
        let nextLines = next.split(separator: "\n", omittingEmptySubsequences: false).drop { firstLines.contains($0.trimmingCharacters(in: .whitespaces)) && !$0.isEmpty }
        return first + (first.hasSuffix("\n") ? "" : "\n") + nextLines.joined(separator: "\n")
    }
}
