import Foundation

enum MenuBarMode: String, CaseIterable, Identifiable {
    case today, week, lifetime, iconOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .today: return "Today's spend"
        case .week: return "Last 7 days"
        case .lifetime: return "Lifetime spend"
        case .iconOnly: return "Icon only"
        }
    }
}

enum Period: String, CaseIterable, Identifiable {
    case week = "7D", month = "30D", all = "All"
    var id: String { rawValue }
    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .all: return nil
        }
    }
}

enum SettingsKeys {
    static let baseURL = "baseURL"
    static let refreshMinutes = "refreshMinutes"
    static let menuBarMode = "menuBarMode"
    static let alertEnabled = "dailyAlertEnabled"
    static let alertThreshold = "dailyAlertThreshold"
    static let defaultBaseURL = "https://ai-gateway.dev.devrev-eng.ai"
}

extension UserDefaults {
    var baseURLString: String {
        get { string(forKey: SettingsKeys.baseURL) ?? SettingsKeys.defaultBaseURL }
        set { set(newValue, forKey: SettingsKeys.baseURL) }
    }
    var refreshMinutes: Int {
        let v = integer(forKey: SettingsKeys.refreshMinutes)
        return v > 0 ? v : 5
    }
}
