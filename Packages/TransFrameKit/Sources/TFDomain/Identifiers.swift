import CoreGraphics
import Foundation

// MARK: - Typed identifiers (SPEC §02 §1.2)

public protocol UUIDIdentifier: Hashable, Sendable, Codable, CustomStringConvertible {
    var raw: UUID { get }
    init(raw: UUID)
}

public extension UUIDIdentifier {
    init() { self.init(raw: UUID()) }
    var description: String { raw.uuidString }
    /// First 8 hex characters; safe for logs.
    var shortDescription: String { String(raw.uuidString.prefix(8)) }
}

public struct SessionID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct OperationID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct SegmentID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct BlockID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct AnnotationID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct AnalysisResultID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct HistoryEntryID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct GlossaryEntryID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }

public struct DisplayID: Hashable, Sendable, Codable {
    public let raw: UInt32
    public init(_ raw: UInt32) { self.raw = raw }
}

public struct WindowID: Hashable, Sendable, Codable {
    public let raw: UInt32
    public init(_ raw: UInt32) { self.raw = raw }
}

public struct LanguageCode: Hashable, Sendable, Codable, CustomStringConvertible {
    public let bcp47: String
    public init(_ bcp47: String) { self.bcp47 = bcp47 }
    public var description: String { bcp47 }

    /// Primary language subtag, lower-cased ("zh-Hans" → "zh").
    public var primary: String { String(bcp47.split(separator: "-").first ?? Substring(bcp47)).lowercased() }

    /// Whether two codes denote the same written language. Chinese scripts are distinct.
    public func isSameLanguage(as other: LanguageCode) -> Bool {
        if primary == "zh" || other.primary == "zh" {
            return script == other.script && primary == other.primary
        }
        return primary == other.primary
    }

    private var script: String {
        let lower = bcp47.lowercased()
        if lower.contains("hant") || lower == "zh-tw" || lower == "zh-hk" { return "hant" }
        return lower.hasPrefix("zh") ? "hans" : ""
    }

    public var isRightToLeft: Bool { ["ar", "he", "fa", "ur", "yi"].contains(primary) }

    public static let english = LanguageCode("en")
    public static let simplifiedChinese = LanguageCode("zh-Hans")
}

public struct ContentHash: Hashable, Sendable, Codable, CustomStringConvertible {
    public let sha256: Data
    public init(sha256: Data) { self.sha256 = sha256 }
    public var hex: String { sha256.map { String(format: "%02x", $0) }.joined() }
    /// First 8 hex characters; the only form allowed in logs (SPEC §01 §9.7).
    public var prefix8: String { String(hex.prefix(8)) }
    public var description: String { prefix8 }
}

// MARK: - Pixels

/// Immutable pixel container that crosses actor boundaries (SPEC §02 §1.2).
public struct PixelImage: Sendable {
    public let cgImage: CGImage
    /// Pixels per point at capture time; > 0.
    public let scale: Double

    public init(cgImage: CGImage, scale: Double) {
        precondition(scale > 0, "PixelImage scale must be positive")
        self.cgImage = cgImage
        self.scale = scale
    }

    public var pixelSize: PixelSize { PixelSize(width: cgImage.width, height: cgImage.height) }
    public var pointSize: CGSize { CGSize(width: Double(cgImage.width) / scale, height: Double(cgImage.height) / scale) }
}
