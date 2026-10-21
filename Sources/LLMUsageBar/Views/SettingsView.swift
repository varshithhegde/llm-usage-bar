import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(PetModel.self) private var pet

    var body: some View {
        @Bindable var pet = pet
        TabView(selection: $pet.settingsTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            PetSettingsView()
                .tabItem { Label("Pet", systemImage: "pawprint") }
                .tag(SettingsTab.pet)
        }
        .frame(width: 500)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

struct GeneralSettingsView: View {
    @Environment(UsageStore.self) private var store

    @State private var apiKey = ""
    @State private var keyStatus: String?
    @State private var keySource: String = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var baseURL = ""
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var confirmReset = false
    @AppStorage(SettingsKeys.alertEnabled) private var alertEnabled = false
    @AppStorage(SettingsKeys.alertThreshold) private var alertThreshold: Double = 25
    @State private var notifNote: String?

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                SecureField("API key", text: $apiKey, prompt: Text(keySource.isEmpty ? "sk-…" : "•••••••• (\(keySource))"))
                    .textContentType(.password)
                    .onSubmit(saveKey)
                TextField("Gateway URL", text: $baseURL, prompt: Text(SettingsKeys.defaultBaseURL))
                    .onSubmit(saveURL)
                HStack {
                    Button("Save") { saveKey(); saveURL() }
                        .keyboardShortcut(.defaultAction)
                    Button {
                        Task { await test() }
                    } label: {
                        if testing { ProgressView().controlSize(.small) } else { Text("Test connection") }
                    }
                    .disabled(testing)
                    if !keySource.isEmpty {
                        Button("Remove key", role: .destructive) {
                            Keychain.delete()
                            refreshKeySource()
                            keyStatus = "Key removed from Keychain."
                        }
                    }
                    Spacer()
                }
                if let r = testResult {
                    Label(r.message, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(r.ok ? .green : .red)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let keyStatus {
                    Text(keyStatus).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("The key is stored in your macOS Keychain. If empty, LITELLM_API_KEY from the environment is used.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Display & refresh") {
                Picker("Menu bar shows", selection: $store.menuBarMode) {
                    ForEach(MenuBarMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Refresh every", selection: $store.refreshMinutes) {
                    ForEach([1, 5, 15, 30, 60], id: \.self) { m in
                        Text(m == 60 ? "1 hour" : "\(m) min").tag(m)
                    }
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in setLaunch(v) }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Alerts") {
                Toggle("Notify when today's spend exceeds", isOn: $alertEnabled)
                    .onChange(of: alertEnabled) { _, v in
                        guard v else { return }
                        Task {
                            let ok = await BudgetAlert.requestPermission()
                            notifNote = ok ? nil : "Notifications aren't permitted. Enable them in System Settings → Notifications."
                        }
                    }
                HStack {
                    TextField("Threshold", value: $alertThreshold, format: .currency(code: "USD"))
                        .frame(width: 120)
                    Stepper("", value: $alertThreshold, in: 1...100_000, step: 5).labelsHidden()
                    Text("per day").foregroundStyle(.secondary)
                }
                .disabled(!alertEnabled)
                if let notifNote { Text(notifNote).font(.caption).foregroundStyle(.orange) }
            }

            Section {
                LabeledContent("Stored days", value: "\(store.daily.count)")
                LabeledContent("Snapshots", value: "\(store.db?.snapshotCount() ?? 0)")
                HStack {
                    Button("Export CSV…") { CSVExporter.export(store.csv()) }
                        .disabled(store.daily.isEmpty)
                    Button("Show in Finder") {
                        NSWorkspace.shared.open(Database.defaultDirectory)
                    }
                    Spacer()
                    Button("Reset local data…", role: .destructive) { confirmReset = true }
                }
            } header: {
                Text("Data")
            } footer: {
                Text(Database.defaultDirectory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            baseURL = store.baseURLString
            refreshKeySource()
            launchAtLogin = LaunchAtLogin.isEnabled
            launchError = LaunchAtLogin.statusDescription
            NSApp.activate(ignoringOtherApps: true)
        }
        .confirmationDialog("Reset all local data?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { store.resetLocalData() }
        } message: {
            Text("This deletes stored history and snapshots. Data available from the API will be re-downloaded; snapshot-derived history cannot be recovered.")
        }
    }

    private func refreshKeySource() {
        if Keychain.read() != nil { keySource = "saved in Keychain" }
        else if Keychain.resolvedKey()?.fromEnv == true { keySource = "from LITELLM_API_KEY" }
        else { keySource = "" }
        store.hasKey = Keychain.resolvedKey() != nil
    }

    private func saveKey() {
        let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        if Keychain.save(k) {
            apiKey = ""
            keyStatus = "Key saved to Keychain."
            testResult = nil
            refreshKeySource()
            Task { await store.refresh() }
        } else {
            keyStatus = "Couldn't save to Keychain."
        }
    }

    private func saveURL() {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { baseURL = SettingsKeys.defaultBaseURL }
        guard let u = LiteLLMClient.normalize(baseURL) else {
            testResult = (false, "That gateway URL doesn't look valid.")
            return
        }
        baseURL = u.absoluteString
        if store.baseURLString != baseURL {
            store.baseURLString = baseURL
            Task { await store.refresh() }
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let typed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = LiteLLMClient.normalize(baseURL.isEmpty ? store.baseURLString : baseURL) else {
            testResult = (false, "Invalid gateway URL."); return
        }
        guard let key = typed.isEmpty ? Keychain.resolvedKey()?.key : typed else {
            testResult = (false, "Enter an API key first."); return
        }
        let client = LiteLLMClient(baseURL: url, apiKey: key)
        do {
            let (k, _) = try await client.keyInfo()
            var msg = "Connected" + (k.alias.map { " as key “\($0)”" } ?? "")
            do {
                let (u, _) = try await client.userInfo()
                msg += " · \(u.displayName) · \(Fmt.currency(u.spend)) lifetime"
            } catch {}
            do {
                _ = try await client.dailyActivity(start: Day.offset(Day.today, by: -1), end: Day.today)
                msg += " · daily activity ✓"
            } catch {
                msg += " · daily activity unavailable"
            }
            testResult = (true, msg)
        } catch {
            testResult = (false, error.localizedDescription)
        }
    }

    private func setLaunch(_ on: Bool) {
        do {
            try LaunchAtLogin.set(on)
            launchError = LaunchAtLogin.statusDescription
        } catch {
            launchError = "Couldn't update login item: \(error.localizedDescription)"
            let actual = LaunchAtLogin.isEnabled
            if actual != launchAtLogin { launchAtLogin = actual }
        }
    }
}
