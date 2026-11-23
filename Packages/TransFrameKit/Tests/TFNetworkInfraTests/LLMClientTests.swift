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
        #expect(transport.requests.count == 0)
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
