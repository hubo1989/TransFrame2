import CryptoKit
import Foundation
import TFDomain
import TFNetworkInfra

/// Image hosting (INP-09, N-08): PicGo, Alibaba Cloud OSS, Tencent Cloud COS, Qiniu Kodo. Secrets are read per request.
public struct ImageUploader: ImageUploading {
    private let transport: any HTTPTransport
    private let secrets: @Sendable (CredentialRef) async throws(AppError) -> String?
    private let now: @Sendable () -> Date

    public init(transport: any HTTPTransport, secrets: @escaping @Sendable (CredentialRef) async throws(AppError) -> String?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.secrets = secrets
        self.now = now
    }

    public func upload(_ data: Data, fileName: String, contentType: String, settings: ImageHostSettings) async throws(AppError) -> UploadReceipt {
        guard let provider = settings.provider else { throw .upload(.notConfigured) }
        let request: HTTPRequest
        let publicURL: URL?
        switch provider {
        case .hostPicGo:
            return try await picgo(data, fileName: fileName, endpoint: settings.picgoEndpoint)
        case .hostOSS, .hostCOS, .hostKodo:
            guard let secret = try await secrets(.imageHost(provider, "secret")), !secret.isEmpty else { throw .upload(.notConfigured) }
            let built = try UploadSigning.request(provider: provider, data: data, fileName: fileName, contentType: contentType, settings: settings, secret: secret, date: now())
            request = built.0
            publicURL = built.1
        default:
            throw .upload(.notConfigured)
        }
        let response: HTTPResponse
        do { response = try await transport.send(request, engine: provider) } catch let error where error == .cancelled { throw error } catch { throw .upload(.network) }
        guard response.isSuccess else { throw .upload(.rejected(status: response.status)) }
        guard let publicURL else { throw .upload(.rejected(status: response.status)) }
        return UploadReceipt(url: publicURL, provider: provider)
    }

    private func picgo(_ data: Data, fileName: String, endpoint: String) async throws(AppError) -> UploadReceipt {
        guard let url = URL(string: endpoint) else { throw .upload(.notConfigured) }
        let temporary = FileManager.default.temporaryDirectory.appending(path: fileName)
        do { try data.write(to: temporary) } catch { throw .upload(.network) }
        let body = try? JSONSerialization.data(withJSONObject: ["list": [temporary.path]])
        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(url: url, method: .post, headers: ["Content-Type": "application/json"], body: body, timeout: .seconds(60)), engine: .hostPicGo)
        } catch let error where error == .cancelled { throw error } catch { throw .upload(.network) }
        try? FileManager.default.removeItem(at: temporary)
        guard response.isSuccess, let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              (json["success"] as? Bool) == true, let first = (json["result"] as? [String])?.first, let link = URL(string: first)
        else { throw .upload(.rejected(status: response.status)) }
        return UploadReceipt(url: link, provider: .hostPicGo)
    }
}

/// Request signing for the cloud object stores; pure so it can be tested with fixed dates.
public enum UploadSigning {
    public static func request(provider: EngineID, data: Data, fileName: String, contentType: String, settings: ImageHostSettings, secret: String, date: Date) throws(AppError) -> (HTTPRequest, URL?) {
        func field(_ name: String) -> String { settings.field(name, for: provider).trimmingCharacters(in: .whitespacesAndNewlines) }
        let prefix = field("pathPrefix").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = (prefix.isEmpty ? "" : prefix + "/") + fileName
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "+"))) ?? key
        let bucket = field("bucket")
        guard !bucket.isEmpty else { throw .upload(.notConfigured) }
        switch provider {
        case .hostOSS:
            let endpoint = field("endpoint").replacingOccurrences(of: "https://", with: "")
            let accessKey = field("accessKeyID")
            guard !endpoint.isEmpty, !accessKey.isEmpty, let url = URL(string: "https://\(bucket).\(endpoint)/\(encodedKey)") else { throw .upload(.notConfigured) }
            let dateString = httpDate(date)
            let canonical = "PUT\n\n\(contentType)\n\(dateString)\n/\(bucket)/\(key)"
            let signature = Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(canonical.utf8), using: SymmetricKey(data: Data(secret.utf8)))).base64EncodedString()
            let request = HTTPRequest(url: url, method: .put, headers: ["Content-Type": contentType, "Date": dateString, "Authorization": "OSS \(accessKey):\(signature)"], body: data, timeout: .seconds(60))
            return (request, publicURL(field("domain"), key: encodedKey) ?? url)
        case .hostCOS:
            let region = field("region"), secretID = field("secretID")
            guard !region.isEmpty, !secretID.isEmpty, let url = URL(string: "https://\(bucket).cos.\(region).myqcloud.com/\(encodedKey)") else { throw .upload(.notConfigured) }
            let start = Int(date.timeIntervalSince1970), end = start + 600
            let keyTime = "\(start);\(end)"
            let signKey = hex(HMAC<Insecure.SHA1>.authenticationCode(for: Data(keyTime.utf8), using: SymmetricKey(data: Data(secret.utf8))))
            let host = url.host ?? ""
            let httpString = "put\n/\(key)\n\nhost=\(host.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? host)\n"
            let stringToSign = "sha1\n\(keyTime)\n\(hex(Insecure.SHA1.hash(data: Data(httpString.utf8))))\n"
            let signature = hex(HMAC<Insecure.SHA1>.authenticationCode(for: Data(stringToSign.utf8), using: SymmetricKey(data: Data(signKey.utf8))))
            let authorization = "q-sign-algorithm=sha1&q-ak=\(secretID)&q-sign-time=\(keyTime)&q-key-time=\(keyTime)&q-header-list=host&q-url-param-list=&q-signature=\(signature)"
            let request = HTTPRequest(url: url, method: .put, headers: ["Content-Type": contentType, "Authorization": authorization], body: data, timeout: .seconds(60))
            return (request, publicURL(field("domain"), key: encodedKey) ?? url)
        case .hostKodo:
            let accessKey = field("accessKey"), uploadHost = field("uploadHost").isEmpty ? "https://upload.qiniup.com" : field("uploadHost")
            guard !accessKey.isEmpty, let url = URL(string: uploadHost.hasPrefix("http") ? uploadHost : "https://\(uploadHost)") else { throw .upload(.notConfigured) }
            let policy = ["scope": "\(bucket):\(key)", "deadline": Int(date.timeIntervalSince1970) + 3600] as [String: Any]
            let encodedPolicy = base64URL((try? JSONSerialization.data(withJSONObject: policy, options: [.sortedKeys])) ?? Data())
            let sign = base64URL(Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(encodedPolicy.utf8), using: SymmetricKey(data: Data(secret.utf8)))))
            let token = "\(accessKey):\(sign):\(encodedPolicy)"
            let boundary = "TF2-\(UUID().uuidString)"
            var body = Data()
            func part(_ name: String, _ value: String) { body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)) }
            part("token", token)
            part("key", key)
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            let request = HTTPRequest(url: url, method: .post, headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"], body: body, timeout: .seconds(60))
            guard let domain = publicURL(field("domain"), key: encodedKey) else { throw .upload(.notConfigured) }
            return (request, domain)
        default:
            throw .upload(.notConfigured)
        }
    }

    static func publicURL(_ domain: String, key: String) -> URL? {
        let trimmed = domain.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !trimmed.isEmpty else { return nil }
        return URL(string: (trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)") + "/" + key)
    }

    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
}
