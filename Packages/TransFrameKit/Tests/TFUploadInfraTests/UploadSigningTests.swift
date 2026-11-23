import Foundation
import Testing
import TFDomain
@testable import TFUploadInfra

@Suite("Upload signing (N-08)")
struct UploadSigningTests {
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    func settings(_ provider: EngineID, _ fields: [String: String]) -> ImageHostSettings {
        var s = ImageHostSettings()
        s.provider = provider
        for (k, v) in fields { s.setField(k, v, for: provider) }
        return s
    }

    @Test func ossSignsPutWithDateAndKey() throws {
        let s = settings(.hostOSS, ["endpoint": "oss-cn-hangzhou.aliyuncs.com", "bucket": "b", "accessKeyID": "AK", "pathPrefix": "shots"])
        let (request, url) = try UploadSigning.request(provider: .hostOSS, data: Data([1]), fileName: "a.png", contentType: "image/png", settings: s, secret: "SK", date: date)
        #expect(request.url.absoluteString == "https://b.oss-cn-hangzhou.aliyuncs.com/shots/a.png")
        #expect(request.method == .put)
        #expect(request.headers["Date"] == "Tue, 14 Nov 2023 22:13:20 GMT")
        #expect(request.headers["Authorization"]?.hasPrefix("OSS AK:") == true)
        #expect(url?.absoluteString == "https://b.oss-cn-hangzhou.aliyuncs.com/shots/a.png")
    }

    @Test func cosUsesQSign() throws {
        let s = settings(.hostCOS, ["region": "ap-shanghai", "bucket": "b-123", "secretID": "SID", "domain": "img.example.com"])
        let (request, url) = try UploadSigning.request(provider: .hostCOS, data: Data(), fileName: "x.png", contentType: "image/png", settings: s, secret: "SK", date: date)
        let auth = try #require(request.headers["Authorization"])
        #expect(auth.contains("q-ak=SID"))
        #expect(auth.contains("q-sign-time=1700000000;1700000600"))
        #expect(url?.absoluteString == "https://img.example.com/x.png")
    }

    @Test func kodoRequiresDomainAndBuildsMultipart() throws {
        let s = settings(.hostKodo, ["bucket": "b", "accessKey": "AK", "domain": "cdn.example.com"])
        let (request, url) = try UploadSigning.request(provider: .hostKodo, data: Data([0xFF]), fileName: "k.png", contentType: "image/png", settings: s, secret: "SK", date: date)
        #expect(request.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(String(decoding: request.body ?? Data(), as: UTF8.self).contains("name=\"token\""))
        #expect(url?.absoluteString == "https://cdn.example.com/k.png")
        #expect(throws: AppError.self) {
            try UploadSigning.request(provider: .hostKodo, data: Data(), fileName: "k.png", contentType: "image/png",
                                      settings: settings(.hostKodo, ["bucket": "b", "accessKey": "AK"]), secret: "SK", date: date)
        }
    }

    @Test func missingBucketIsNotConfigured() {
        #expect(throws: AppError.upload(.notConfigured)) {
            try UploadSigning.request(provider: .hostOSS, data: Data(), fileName: "a", contentType: "image/png", settings: settings(.hostOSS, [:]), secret: "s", date: date)
        }
    }
}
