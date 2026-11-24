import CoreGraphics
import Foundation

/// Contract version of the in-memory types (SPEC §02 §0.3). Participates in cache keys.
public enum Contracts {
    public static let version = 1
}

// MARK: - Coordinate spaces (SPEC §02 §1.1)

public protocol CoordinateSpace: Sendable {}
/// Global points, origin at the top-left of the primary display, y down.
public enum QuartzGlobal: CoordinateSpace {}
/// Points inside one display, origin at that display's top-left, y down.
public enum DisplayLocal: CoordinateSpace {}
/// Pixels of one captured frame (or any image handed to an engine), origin top-left.
public enum FramePixel: CoordinateSpace {}
/// Pixels of the session base image, origin top-left.
public enum DocumentPixel: CoordinateSpace {}
/// Pixels of the output canvas, origin top-left.
public enum CanvasPixel: CoordinateSpace {}

public struct SpaceRect<S: CoordinateSpace>: Sendable, Hashable, Codable {
    public var raw: CGRect

    public init(_ raw: CGRect) { self.raw = raw }
    public init(x: Double, y: Double, width: Double, height: Double) {
        raw = CGRect(x: x, y: y, width: width, height: height)
    }

    public static var zero: SpaceRect<S> { SpaceRect(.zero) }

    public var minX: Double { raw.minX }
    public var minY: Double { raw.minY }
    public var maxX: Double { raw.maxX }
    public var maxY: Double { raw.maxY }
    public var midX: Double { raw.midX }
    public var midY: Double { raw.midY }
    public var width: Double { raw.width }
    public var height: Double { raw.height }
    public var origin: SpacePoint<S> { SpacePoint(raw.origin) }
    public var isEmpty: Bool { raw.isEmpty || raw.isNull }
    public var area: Double { isEmpty ? 0 : raw.width * raw.height }

    public func intersection(_ other: SpaceRect<S>) -> SpaceRect<S>? {
        let result = raw.intersection(other.raw)
        return result.isNull || result.isEmpty ? nil : SpaceRect(result)
    }
    public func union(_ other: SpaceRect<S>) -> SpaceRect<S> { SpaceRect(raw.union(other.raw)) }
    public func contains(_ point: SpacePoint<S>) -> Bool { raw.contains(point.raw) }
    public func contains(_ rect: SpaceRect<S>) -> Bool { raw.contains(rect.raw) }
    public func intersects(_ rect: SpaceRect<S>) -> Bool { raw.intersects(rect.raw) }
    public func offsetBy(dx: Double, dy: Double) -> SpaceRect<S> { SpaceRect(raw.offsetBy(dx: dx, dy: dy)) }
    public func insetBy(dx: Double, dy: Double) -> SpaceRect<S> { SpaceRect(raw.insetBy(dx: dx, dy: dy)) }
    public var standardized: SpaceRect<S> { SpaceRect(raw.standardized) }

    /// Reinterprets the raw rectangle in another space. Only for documented conversions.
    public func relabeled<T: CoordinateSpace>(as _: T.Type = T.self) -> SpaceRect<T> { SpaceRect<T>(raw) }

    /// Points → pixels: multiply, floor the minimum edges, ceil the maximum edges (SPEC §02 §1.1).
    public func scaledOutward<T: CoordinateSpace>(by scale: Double, to _: T.Type = T.self) -> SpaceRect<T> {
        let minX = (raw.minX * scale).rounded(.down)
        let minY = (raw.minY * scale).rounded(.down)
        let maxX = (raw.maxX * scale).rounded(.up)
        let maxY = (raw.maxY * scale).rounded(.up)
        return SpaceRect<T>(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Rounds outward to integral coordinates without scaling.
    public var integralOutward: SpaceRect<S> { scaledOutward(by: 1) }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(raw.origin.x)
        hasher.combine(raw.origin.y)
        hasher.combine(raw.size.width)
        hasher.combine(raw.size.height)
    }
    public static func == (lhs: SpaceRect<S>, rhs: SpaceRect<S>) -> Bool { lhs.raw == rhs.raw }

    private enum CodingKeys: String, CodingKey { case x, y, width, height }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        raw = CGRect(
            x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y),
            width: try c.decode(Double.self, forKey: .width), height: try c.decode(Double.self, forKey: .height)
        )
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Double(raw.origin.x), forKey: .x)
        try c.encode(Double(raw.origin.y), forKey: .y)
        try c.encode(Double(raw.size.width), forKey: .width)
        try c.encode(Double(raw.size.height), forKey: .height)
    }
}

public struct SpacePoint<S: CoordinateSpace>: Sendable, Hashable, Codable {
    public var raw: CGPoint

    public init(_ raw: CGPoint) { self.raw = raw }
    public init(x: Double, y: Double) { raw = CGPoint(x: x, y: y) }

    public var x: Double { raw.x }
    public var y: Double { raw.y }

    public func offsetBy(dx: Double, dy: Double) -> SpacePoint<S> { SpacePoint(x: x + dx, y: y + dy) }
    public func distance(to other: SpacePoint<S>) -> Double { hypot(x - other.x, y - other.y) }
    public func relabeled<T: CoordinateSpace>(as _: T.Type = T.self) -> SpacePoint<T> { SpacePoint<T>(raw) }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(raw.x)
        hasher.combine(raw.y)
    }
    public static func == (lhs: SpacePoint<S>, rhs: SpacePoint<S>) -> Bool { lhs.raw == rhs.raw }

    private enum CodingKeys: String, CodingKey { case x, y }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        raw = CGPoint(x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Double(raw.x), forKey: .x)
        try c.encode(Double(raw.y), forKey: .y)
    }
}

public typealias QuartzRect = SpaceRect<QuartzGlobal>
public typealias QuartzPoint = SpacePoint<QuartzGlobal>
public typealias DisplayLocalRect = SpaceRect<DisplayLocal>
public typealias FrameRect = SpaceRect<FramePixel>
public typealias DocumentRect = SpaceRect<DocumentPixel>
public typealias DocumentPoint = SpacePoint<DocumentPixel>
public typealias CanvasRect = SpaceRect<CanvasPixel>
public typealias CanvasPoint = SpacePoint<CanvasPixel>

/// Four corner points (top-left, top-right, bottom-right, bottom-left) in document pixels.
public struct Quad: Sendable, Codable, Equatable, Hashable {
    public var topLeft: DocumentPoint
    public var topRight: DocumentPoint
    public var bottomRight: DocumentPoint
    public var bottomLeft: DocumentPoint

    public init(topLeft: DocumentPoint, topRight: DocumentPoint, bottomRight: DocumentPoint, bottomLeft: DocumentPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    public var boundingBox: DocumentRect {
        let xs = [topLeft.x, topRight.x, bottomRight.x, bottomLeft.x]
        let ys = [topLeft.y, topRight.y, bottomRight.y, bottomLeft.y]
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        return DocumentRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
    }

    public func offsetBy(dx: Double, dy: Double) -> Quad {
        Quad(
            topLeft: topLeft.offsetBy(dx: dx, dy: dy), topRight: topRight.offsetBy(dx: dx, dy: dy),
            bottomRight: bottomRight.offsetBy(dx: dx, dy: dy), bottomLeft: bottomLeft.offsetBy(dx: dx, dy: dy)
        )
    }
}

/// Straight-alpha RGBA color, components in 0...1.
public struct RGBA: Sendable, Codable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public func withAlpha(_ alpha: Double) -> RGBA { RGBA(red: red, green: green, blue: blue, alpha: alpha) }

    /// Parses `#RRGGBB`, `RRGGBB`, `#RGB` or `#RRGGBBAA` (case-insensitive).
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        if text.count == 6 {
            self.init(
                red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        } else {
            self.init(
                red: Double((value >> 24) & 0xFF) / 255, green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255, alpha: Double(value & 0xFF) / 255
            )
        }
    }

    private static func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }

    /// Canonical `#RRGGBB`, uppercase.
    public var hexString: String {
        String(format: "#%02X%02X%02X", Self.byte(red), Self.byte(green), Self.byte(blue))
    }
    public var rgbString: String { "rgb(\(Self.byte(red)), \(Self.byte(green)), \(Self.byte(blue)))" }

    /// WCAG relative luminance.
    public var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    public static func contrastRatio(_ a: RGBA, _ b: RGBA) -> Double {
        let (l1, l2) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (l1 + 0.05) / (l2 + 0.05)
    }

    public static let black = RGBA(red: 0, green: 0, blue: 0)
    public static let white = RGBA(red: 1, green: 1, blue: 1)
    public static let clear = RGBA(red: 0, green: 0, blue: 0, alpha: 0)
}

public struct PixelSize: Hashable, Sendable, Codable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
    public var pixelCount: Int { width * height }
    public var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
}

public struct OSVersion: Sendable, Codable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
    public static func < (lhs: OSVersion, rhs: OSVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
    public var description: String { patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)" }

    public static var current: OSVersion {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return OSVersion(v.majorVersion, v.minorVersion, v.patchVersion)
    }
}
