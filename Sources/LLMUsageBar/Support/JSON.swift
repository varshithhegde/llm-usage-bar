import Foundation

typealias JSONObject = [String: Any]

/// Lenient accessors for loosely-typed JSON produced by `JSONSerialization`.
/// Tolerates nulls, missing keys, and numbers encoded as strings.
enum J {
    static func parse(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func double(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber:
            let d = n.doubleValue
            return d.isFinite ? d : nil
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let d = Double(t), d.isFinite else { return nil }
            return d
        default:
            return nil
        }
    }

    static func int(_ v: Any?) -> Int? {
        guard let d = double(v), abs(d) < 9.0e18 else { return nil }
        return Int(d)
    }

    static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    static func dict(_ v: Any?) -> JSONObject? { v as? JSONObject }
    static func array(_ v: Any?) -> [Any] { (v as? [Any]) ?? [] }

    static func strings(_ v: Any?) -> [String] {
        array(v).compactMap { string($0) }
    }

    /// First non-nil value among several candidate keys.
    static func first(_ obj: JSONObject?, _ keys: String...) -> Any? {
        guard let obj else { return nil }
        for k in keys {
            if let v = obj[k], !(v is NSNull) { return v }
        }
        return nil
    }
}

enum DateParse {
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let noTZ: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        return f
    }()
    private static let noTZNoFrac: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    static func iso8601(_ v: Any?) -> Date? {
        guard let s = J.string(v) else { return nil }
        if let d = isoFrac.date(from: s) ?? iso.date(from: s) ?? noTZ.date(from: s) ?? noTZNoFrac.date(from: s) {
            return d
        }
        if s.count >= 10, let d = Day.date(from: String(s.prefix(10))) { return d }
        return nil
    }
}

/// Day keys are "yyyy-MM-dd" strings in UTC, matching how LiteLLM buckets daily activity.
enum Day {
    static let timeZone = TimeZone(identifier: "UTC")!

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }()

    static func key(_ date: Date) -> String { fmt.string(from: date) }
    static func date(from key: String) -> Date? { fmt.date(from: key) }
    static var today: String { key(Date()) }

    static func offset(_ key: String, by days: Int) -> String {
        guard let d = date(from: key), let n = calendar.date(byAdding: .day, value: days, to: d) else { return key }
        return self.key(n)
    }

    /// Inclusive list of day keys from `start` to `end`.
    static func range(from start: String, to end: String) -> [String] {
        guard var d = date(from: start), let e = date(from: end), d <= e else { return [] }
        var out: [String] = []
        let cal = calendar
        while d <= e, out.count < 20000 {
            out.append(key(d))
            guard let n = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = n
        }
        return out
    }
}
