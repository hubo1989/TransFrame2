import Foundation

/// Local rule classifier for the privacy guard (ADR-0010 §5–7). Pure; shared by the image and text channels.
public enum SensitiveTextClassifier {
    public struct Match: Sendable, Equatable {
        public let range: Range<String.Index>
        public let category: SensitiveCategory
        public let confidence: Double
    }

    private static let rules: [(SensitiveCategory, String, Double)] = [
        (.privateKey, #"(?s)-----BEGIN ((?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY)-----.*?-----END \1-----"#, 0.99),
        (.privateKey, #"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----"#, 0.99),
        (
            .apiKey,
            #"\b(?:sk-(?:proj-|ant-)?[A-Za-z0-9_\-]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|"# +
                #"xox[baprs]-[A-Za-z0-9\-]{10,}|AIza[0-9A-Za-z_\-]{35}|glpat-[A-Za-z0-9_\-]{20})\b"#,
            0.97
        ),
        (.email, #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#, 0.9),
        (.phone, #"(?<![\d])(?:\+?\d{1,3}[\s\-]?)?(?:\(?\d{2,4}\)?[\s\-]?)\d{3,4}[\s\-]?\d{4}(?![\d])"#, 0.6),
        (.password, #"(?i)(?:password|passwd|pwd|密码|口令)\s*[:：=]\s*\S+"#, 0.9),
    ]

    public static func matches(in text: String) -> [Match] {
        var found: [Match] = []
        let ns = text as NSString
        for (category, pattern, confidence) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for result in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let range = Range(result.range, in: text) else { continue }
                found.append(Match(range: range, category: category, confidence: confidence))
            }
        }
        found += cardNumbers(in: text) + nationalIDs(in: text) + highEntropyTokens(in: text)
        // Prefer high-confidence matches when ranges overlap.
        var kept: [Match] = []
        for match in found.sorted(by: { ($0.confidence, text[$0.range].count) > ($1.confidence, text[$1.range].count) })
        where !kept.contains(where: { $0.range.overlaps(match.range) }) {
            kept.append(match)
        }
        return kept.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// 13–19 digits with optional separators that pass the Luhn check.
    static func cardNumbers(in text: String) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\d)(?:\d[ \-]?){12,18}\d(?!\d)"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            let digits = text[range].filter(\.isNumber)
            return (13...19).contains(digits.count) && luhn(String(digits)) ? Match(range: range, category: .paymentCard, confidence: 0.95) : nil
        }
    }

    public static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            guard var value = character.wholeNumberValue else { return false }
            if index % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0 && !digits.isEmpty
    }

    /// Chinese resident ID (18 characters with checksum) and US SSN.
    static func nationalIDs(in text: String) -> [Match] {
        var out: [Match] = []
        if let cn = try? NSRegularExpression(pattern: #"(?<![\dXx])\d{17}[\dXx](?![\dXx])"#) {
            for result in cn.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(result.range, in: text), chineseIDChecksum(String(text[range])) else { continue }
                out.append(Match(range: range, category: .nationalID, confidence: 0.95))
            }
        }
        if let ssn = try? NSRegularExpression(pattern: #"\b(?!000|666|9\d\d)\d{3}-(?!00)\d{2}-(?!0000)\d{4}\b"#) {
            for result in ssn.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(result.range, in: text) { out.append(Match(range: range, category: .nationalID, confidence: 0.9)) }
            }
        }
        return out
    }

    public static func chineseIDChecksum(_ id: String) -> Bool {
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let codes = Array("10X98765432")
        let characters = Array(id.uppercased())
        guard characters.count == 18 else { return false }
        var sum = 0
        for i in 0..<17 {
            guard let digit = characters[i].wholeNumberValue else { return false }
            sum += digit * weights[i]
        }
        return codes[sum % 11] == characters[17]
    }

    /// Long random-looking tokens (≥ 32 chars, mixed classes, high Shannon entropy) are treated as secrets.
    static func highEntropyTokens(in text: String) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: #"\b[A-Za-z0-9_\-+/=]{32,}\b"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            let token = String(text[range])
            let hasDigit = token.contains(where: \.isNumber), hasUpper = token.contains(where: \.isUppercase), hasLower = token.contains(where: \.isLowercase)
            guard hasDigit, hasUpper, hasLower, entropy(token) >= 4.0 else { return nil }
            return Match(range: range, category: .apiKey, confidence: 0.85)
        }
    }

    static func entropy(_ s: String) -> Double {
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0) { $0 - (Double($1) / n) * log2(Double($1) / n) }
    }
}
