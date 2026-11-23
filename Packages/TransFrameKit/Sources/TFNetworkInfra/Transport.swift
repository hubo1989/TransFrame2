import Foundation
import os
import TFDomain

/// URLSession transport (SPEC §01 §3.2). Maps network failures to `AppError`; cancellation propagates to the request.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let logger = Logger(subsystem: "com.transframe.v2", category: "network")

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: OriginBoundRedirects(), delegateQueue: nil)
    }

    public func send(_ request: HTTPRequest, engine: EngineID) async throws(AppError) -> HTTPResponse {
        if Task.isCancelled { throw .cancelled }
        guard Endpoint.origin(request.url) != nil else { throw .engine(.notConfigured(engine)) }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        let seconds = Double(request.timeout.components.seconds) + Double(request.timeout.components.attoseconds) / 1e18
        urlRequest.timeoutInterval = max(seconds, 1)
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let start = ContinuousClock.now
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let http = response as? HTTPURLResponse
            let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { result, pair in
                if let key = pair.key as? String { result[key] = "\(pair.value)" }
            }
            let status = http?.statusCode ?? 0
            logger.info("\(engine.raw, privacy: .public) \(status) \(ContinuousClock.now - start, privacy: .public)")
            return HTTPResponse(status: status, headers: headers, body: data)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw .cancelled
            case .timedOut: throw .engine(.timedOut(engine))
            default: throw .engine(.unreachable(engine))
            }
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .engine(.unreachable(engine))
        }
    }
}

final class OriginBoundRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let allowed = Self.allowsRedirect(from: task.originalRequest?.url, to: request.url)
        completionHandler(allowed ? request : nil)
    }

    static func allowsRedirect(from original: URL?, to destination: URL?) -> Bool {
        guard let origin = original.flatMap(Endpoint.origin) else { return false }
        return origin == destination.flatMap(Endpoint.origin)
    }
}

/// Shared HTTP status mapping (401/403 → auth, 429 → rate limit, 5xx → unreachable, other → invalid response).
public enum HTTPStatusMapping {
    public static func check(_ response: HTTPResponse, engine: EngineID) throws(AppError) {
        guard !response.isSuccess else { return }
        switch response.status {
        case 401, 403: throw .engine(.authenticationFailed(engine))
        case 402: throw .engine(.quotaExceeded(engine))
        case 429:
            let retry = response.header("Retry-After").flatMap(Double.init).map { Duration.seconds($0) }
            if let body = String(data: response.body, encoding: .utf8),
                body.localizedCaseInsensitiveContains("quota") || body.localizedCaseInsensitiveContains("insufficient")
            {
                throw .engine(.quotaExceeded(engine))
            }
            throw .engine(.rateLimited(engine, retryAfter: retry))
        case 404: throw .engine(.invalidResponse(engine, detail: "HTTP 404"))
        case 500...599: throw .engine(.unreachable(engine))
        default: throw .engine(.invalidResponse(engine, detail: "HTTP \(response.status)"))
        }
    }

    public static func json(_ response: HTTPResponse, engine: EngineID) throws(AppError) -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw .engine(.invalidResponse(engine, detail: "not JSON"))
        }
        return object
    }
}

/// Endpoint helpers shared by engines.
public enum Endpoint {
    public static func url(_ base: String, appending path: String) -> URL? {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: base), let url = components.url, origin(url) != nil else { return nil }
        var current = components.path
        while current.hasSuffix("/") { current.removeLast() }
        if !current.hasSuffix(path) { current += path }
        components.path = current
        return components.url
    }

    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }

    /// Loopback endpoints (local models) do not require keys (TRN-17).
    public static func isLoopback(_ base: String) -> Bool {
        EngineLocality.classify(host: URL(string: base)?.host) == .onDevice
    }
}
