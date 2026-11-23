import Foundation
import Testing
import TFDomain
import TFDomainTestSupport
@testable import TFNetworkInfra

@Suite("LLM client wire formats")
struct LLMClientTests {
    func client(_ wire: LLMWire, transport: FakeHTTPTransport, endpoint: String = "https://api.example.com/v1", key: String? = "k") -> LLMClient {
        LLMClient(wire: wire, endpoint: endpoint, model: "m", engine: .openAICompatible, transport: transport) { () throws(AppError) in key }
    }

    @Test func chatCompletionRoundTrip() async throws {
        let transport = FakeHTTPTransport()
        transport.on(pathSuffix: "/chat/completions", json: #"{"choices":[{"message":{"content":"hi"},"finish_reason":"length"}]}"#)
        let result = try await client(.openAIChat, transport: transport).complete(system: "s", messages: [LLMMessage(role: .user, text: "u")])
        #expect(result == LLMCompletion(text: "hi", truncated: true))
        let request = try #require(transport.requests.calls.first)
        #expect(request.headers["Authorization"] == "Bearer k")
    }

    @Test func anthropicAndGeminiParse() throws {
        let transport = FakeHTTPTransport()
        let a = client(.anthropic, transport: transport)
        #expect(try a.parse(["content": [["type": "text", "text": "x"]], "stop_reason": "max_tokens"]) == LLMCompletion(text: "x", truncated: true))
        let g = client(.gemini, transport: transport)
        #expect(try g.parse(["candidates": [["content": ["parts": [["text": "y"]]], "finishReason": "STOP"]]]) == LLMCompletion(text: "y", truncated: false))
    }

    @Test func missingKeyForCloudIsNotConfigured() async {
        let transport = FakeHTTPTransport()
        await #expect(throws: AppError.engine(.notConfigured(.openAICompatible))) {
            try await client(.openAIChat, transport: transport, key: nil).complete(system: "", messages: [])
        }
        #expect(transport.requests.calls.isEmpty)
    }

    @Test func loopbackNeedsNoKey() async throws {
        let transport = FakeHTTPTransport()
        transport.onAny(json: #"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#)
        let result = try await client(.openAIChat, transport: transport, endpoint: "http://127.0.0.1:11434/v1", key: nil).complete(system: "", messages: [])
        #expect(result.text == "ok")
    }

    @Test(arguments: [(401, "authenticationFailed"), (429, "rateLimited"), (503, "unreachable")])
    func statusMapping(status: Int, leaf: String) {
        let response = HTTPResponse(status: status, body: Data())
        #expect(throws: AppError.self) { try HTTPStatusMapping.check(response, engine: .mtran) }
        do { try HTTPStatusMapping.check(response, engine: .mtran) } catch { #expect(error.leafKey.contains(leaf)) }
    }

    @Test func continuationMergeDropsOverlap() {
        #expect(ContinuationMerger.merge("The quick brown fox", "brown fox jumps") == "The quick brown fox jumps")
        #expect(ContinuationMerger.merge("line one\nline two", "line two\nline three") == "line one\nline two\nline three")
    }
}

extension LLMClientTests {
    @Test func originsAndLocalityOnlyTrustActualLocalAddresses() throws {
        #expect(EngineLocality.classify(host: "fd-provider.example") == .cloud)
        #expect(EngineLocality.classify(host: "127.service.example") == .cloud)
        #expect(EngineLocality.classify(host: "127.0.0.1") == .onDevice)
        #expect(EngineLocality.classify(host: "[::1]") == .onDevice)
        #expect(EngineLocality.classify(host: "fd12::2") == .localNetwork)
        let base = try #require(URL(string: "https://api.example.com/v1"))
        let same = try #require(URL(string: "https://api.example.com:443/v2"))
        let insecure = try #require(URL(string: "http://api.example.com/v1"))
        let different = try #require(URL(string: "https://other.example.com/v1"))
        #expect(OriginBoundRedirects.allowsRedirect(from: base, to: same))
        #expect(!OriginBoundRedirects.allowsRedirect(from: base, to: insecure))
        #expect(!OriginBoundRedirects.allowsRedirect(from: base, to: different))
    }

    @Test func localClientDoesNotLookUpCredentials() async throws {
        let transport = FakeHTTPTransport()
        transport.onAny(json: #"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#)
        let calls = CallLog<Int>()
        let client = LLMClient(wire: .openAIChat, endpoint: "http://localhost:11434/v1", model: "m", engine: .openAICompatible, transport: transport) {
            () throws(AppError) in
            calls.append(1)
            throw .engine(.credentialLocked)
        }
        #expect(try await client.complete(system: "", messages: []).text == "ok")
        #expect(calls.calls.isEmpty)
    }

    @Test func vendorSamplingAndContinuationRespectModelContracts() throws {
        let transport = FakeHTTPTransport()
        let client = LLMClient(wire: .openAIChat, endpoint: "https://api.example.com/v1", model: "o4-mini", engine: .openAICompatible, transport: transport) {
            () throws(AppError) in "k"
        }
        let request = try client.buildRequest(system: "s", messages: [], maxTokens: 300, temperature: 0.2, key: "k")
        let data = try #require(request.body)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["max_completion_tokens"] as? Int == 300)
        #expect(json["max_tokens"] == nil)
        #expect(json["temperature"] == nil)
        #expect(ContinuationMerger.merge(#"{"text":"ex"#, #"ample"}"#, structured: true) == #"{"text":"example"}"#)
    }
}

extension LLMClientTests {
    @Test func optionalAuthenticationUsesSavedKeyAndAllowsLockedSession() async throws {
        let auth = EndpointAuthentication.modelEndpoint("http://localhost:11434/v1")
        #expect(try await auth.credential(for: .openAICompatible) { () throws(AppError) in "configured" } == "configured")
        #expect(try await auth.credential(for: .openAICompatible) { () throws(AppError) in throw .engine(.credentialLocked) } == nil)
        await #expect(throws: AppError.engine(.credentialLocked)) {
            try await EndpointAuthentication.required.credential(for: .openAICompatible) { () throws(AppError) in
                throw .engine(.credentialLocked)
            }
        }
    }
}
