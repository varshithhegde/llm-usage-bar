import Foundation
import AppKit
import ServiceManagement
import UserNotifications

enum BudgetAlert {
    private static let lastAlertKey = "lastBudgetAlertDay"

    static var isBundled: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func requestPermission() async -> Bool {
        guard isBundled else { return false }
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    @MainActor
    static func check(todaySpend: Double) {
        let d = UserDefaults.standard
        guard d.bool(forKey: SettingsKeys.alertEnabled) else { return }
        let threshold = d.double(forKey: SettingsKeys.alertThreshold)
        guard threshold > 0, todaySpend >= threshold else { return }
        let today = Day.today
        guard d.string(forKey: lastAlertKey) != today else { return }
        d.set(today, forKey: lastAlertKey)
        guard isBundled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Daily AI spend alert"
        content.body = "Today's spend is \(Fmt.currency(todaySpend)), above your \(Fmt.currency(threshold)) threshold."
        content.sound = .default
        let req = UNNotificationRequest(identifier: "budget-\(today)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var statusDescription: String? {
        switch SMAppService.mainApp.status {
        case .requiresApproval: return "Approval required in System Settings → General → Login Items."
        case .notFound: return "Only available when running from the built .app bundle."
        default: return nil
        }
    }

    static func set(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
enum CSVExporter {
    static func export(_ csv: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "llm-usage-\(Day.today).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let a = NSAlert(error: error)
            a.runModal()
        }
    }
}
