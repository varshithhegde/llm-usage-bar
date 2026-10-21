import SwiftUI
import AppKit

@main
enum Main {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run() ? 0 : 1)
        }
        LLMUsageBarApp.main()
    }
}

struct LLMUsageBarApp: App {
    @State private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(store)
        } label: {
            MenuBarLabel()
                .environment(store)
        }
        .menuBarExtraStyle(.window)

        Window("LLM Usage Settings", id: "settings") {
            SettingsView()
                .environment(store)
                .environment(PetModel.shared)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

struct MenuBarLabel: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content
            .onAppear {
                // The label is created at launch, so this is where the desktop pet starts up.
                let open = openWindow
                PetController.shared.openSettings = { open(id: "settings") }
                PetController.shared.install(store: store)
            }
    }

    private var content: some View {
        HStack(spacing: 4) {
            Image(systemName: store.lastError != nil && store.user == nil
                  ? "exclamationmark.triangle"
                  : "chart.line.uptrend.xyaxis")
            if let text = store.menuBarText, store.hasKey {
                Text(text).monospacedDigit()
            }
        }
    }
}
