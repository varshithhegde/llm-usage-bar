import Foundation

enum Fmt {
    private static let currencyFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    private static let preciseCurrencyFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 4
        return f
    }()

    private static let intFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    static func currency(_ v: Double) -> String {
        if v > 0, v < 0.01 { return preciseCurrencyFmt.string(from: NSNumber(value: v)) ?? "$0.00" }
        return currencyFmt.string(from: NSNumber(value: v)) ?? String(format: "$%.2f", v)
    }

    static func compactCurrency(_ v: Double) -> String {
        if abs(v) >= 10_000 { return "$" + abbreviate(v) }
        return currency(v)
    }

    static func int(_ v: Int) -> String { intFmt.string(from: NSNumber(value: v)) ?? "\(v)" }

    static func abbreviate(_ v: Double) -> String {
        let a = abs(v)
        let sign = v < 0 ? "-" : ""
        func f(_ x: Double, _ s: String) -> String {
            let str = x >= 100 ? String(format: "%.0f", x) : String(format: "%.1f", x)
            return sign + (str.hasSuffix(".0") ? String(str.dropLast(2)) : str) + s
        }
        switch a {
        case 1e12...: return f(a / 1e12, "T")
        case 1e9...: return f(a / 1e9, "B")
        case 1e6...: return f(a / 1e6, "M")
        case 1e3...: return f(a / 1e3, "K")
        default: return sign + String(format: "%.0f", a)
        }
    }

    static func tokens(_ v: Int) -> String { abbreviate(Double(v)) }

    static func percent(_ v: Double) -> String {
        String(format: abs(v) >= 10 ? "%.0f%%" : "%.1f%%", v)
    }

    static func relative(_ d: Date?) -> String {
        guard let d else { return "Never updated" }
        if Date().timeIntervalSince(d) < 45 { return "Updated just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "Updated " + f.localizedString(for: d, relativeTo: Date())
    }

    private static let mediumDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func date(_ d: Date?) -> String { d.map { mediumDate.string(from: $0) } ?? "—" }

    private static let dayLabelFmt: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = Day.timeZone
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()

    static func dayLabel(_ key: String) -> String {
        guard let d = Day.date(from: key) else { return key }
        if key == Day.today { return "Today" }
        if key == Day.offset(Day.today, by: -1) { return "Yesterday" }
        return dayLabelFmt.string(from: d)
    }
}
