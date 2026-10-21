import SwiftUI
import AppKit

enum Tab: String, CaseIterable, Identifiable {
    case overview = "Overview", models = "Models", keys = "Keys", history = "History"
    var id: String { rawValue }
}

struct PopoverView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var tab: Tab = .overview

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(openSettings: showSettings)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            if !store.hasKey {
                OnboardingView(openSettings: showSettings)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        SummaryGrid()
                        Picker("", selection: $tab) {
                            ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        Group {
                            switch tab {
                            case .overview: OverviewTab()
                            case .models: ModelsTab()
                            case .keys: KeysTab()
                            case .history: HistoryTab()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                .frame(height: 520)
            }

            Divider()
            FooterView(openSettings: showSettings)
        }
        .frame(width: 400)
        .onAppear { store.refreshIfStale() }
    }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.identifier?.rawValue.contains("settings") == true || $0.title == "LLM Usage Settings" }?
                .makeKeyAndOrderFront(nil)
        }
    }
}

struct HeaderView: View {
    @Environment(UsageStore.self) private var store
    var openSettings: () -> Void
    @State private var spin = false
    @State private var showError = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(store.user?.displayName ?? "LLM Usage")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let p = store.backfillProgress {
                        Text(p)
                    } else if store.isRefreshing {
                        Text("Refreshing…")
                    } else {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text(Fmt.relative(store.lastUpdated))
                        }
                    }
                    if let email = store.user?.email, store.user?.alias != nil {
                        Text("·")
                        Text(email).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)

            if let err = store.lastError {
                Button { showError.toggle() } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                .buttonStyle(.borderless)
                .help("Last refresh had problems")
                .popover(isPresented: $showError, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Last refresh failed").font(.headline)
                        Text(err).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Showing cached data.").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .frame(width: 280)
                }
            }

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(spin ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: spin)
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing || !store.hasKey)
            .help("Refresh now")
            .onChange(of: store.isRefreshing, initial: true) { _, v in spin = v }
        }
    }
}

struct SummaryGrid: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let empty = store.lastUpdated == nil && store.daily.isEmpty
        let today = store.todayMetrics
        let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        VStack(spacing: 8) {
            LazyVGrid(columns: cols, spacing: 8) {
                StatCard(title: "Today", value: Fmt.currency(store.todaySpend),
                         subtitle: "\(Fmt.int(today.apiRequests)) req · \(Fmt.tokens(today.totalTokens)) tok",
                         systemImage: "sun.max.fill", tint: .orange, placeholder: empty)
                StatCard(title: "Yesterday", value: Fmt.currency(store.yesterdaySpend),
                         systemImage: "moon.fill", tint: .indigo, placeholder: empty)
                StatCard(title: "7 days", value: Fmt.compactCurrency(store.last7Spend),
                         subtitle: "\(Fmt.currency(store.last7Spend / 7))/day",
                         systemImage: "calendar", tint: .blue, placeholder: empty)
                StatCard(title: "This month", value: Fmt.compactCurrency(store.monthSpend),
                         systemImage: "calendar.badge.clock", tint: .teal, placeholder: empty)
                StatCard(title: "Lifetime", value: Fmt.compactCurrency(store.lifetimeSpend),
                         subtitle: store.user?.createdAt.map { "since " + Fmt.date($0) },
                         systemImage: "infinity", tint: .purple, placeholder: empty)
                BudgetCard()
            }
            if let msg = store.dailyEndpointMessage ?? (store.usingSnapshotFallback ? "Daily breakdown unavailable — daily spend is derived from local snapshots, so history starts from when the app first ran." : nil) {
                InfoBanner(text: msg, systemImage: "clock.arrow.circlepath", tint: .orange)
            }
        }
    }
}

struct BudgetCard: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let budget = store.keyInfo?.maxBudget ?? store.user?.maxBudget
        let spent = store.keyInfo?.maxBudget != nil ? (store.keyInfo?.spend ?? 0) : store.lifetimeSpend
        let rpm = store.keyInfo?.rpmLimit
        let tpm = store.keyInfo?.tpmLimit
        if let budget, budget > 0 {
            let frac = spent / budget
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
                    Text("Budget").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).textCase(.uppercase)
                }
                Text(Fmt.percent(frac * 100))
                    .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(frac > 0.9 ? .red : frac > 0.7 ? .orange : .primary)
                ShareBar(fraction: frac, tint: frac > 0.9 ? .red : frac > 0.7 ? .orange : .green)
                Text("of \(Fmt.compactCurrency(budget))" + (store.keyInfo?.budgetDuration ?? store.user?.budgetDuration).map { " / \($0)" }.orEmpty)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        } else {
            let limits = [rpm.map { "\(Fmt.abbreviate(Double($0))) RPM" }, tpm.map { "\(Fmt.abbreviate(Double($0))) TPM" }]
                .compactMap { $0 }.joined(separator: " · ")
            StatCard(title: "Budget", value: "No limit",
                     subtitle: limits.isEmpty ? "No rate limits" : limits,
                     systemImage: "checkmark.seal.fill", tint: .green)
        }
    }
}

extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

struct OnboardingView: View {
    var openSettings: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            EmptyState(systemImage: "key.horizontal",
                       title: "Connect your LiteLLM gateway",
                       message: "Add your API key in Settings. It's stored securely in your Keychain.")
            Button("Open Settings…", action: openSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(.bottom, 24)
    }
}

struct PetFooterToggle: View {
    @Bindable private var pet = PetModel.shared

    var body: some View {
        Button {
            pet.enabled.toggle()
        } label: {
            Label(pet.enabled ? "Hide Pet" : "Show Pet", systemImage: pet.enabled ? "pawprint.fill" : "pawprint")
        }
        .help(pet.enabled ? "Hide the desktop pet" : "Show the desktop pet")
        .contextMenu {
            Toggle("Click-Through", isOn: $pet.clickThrough)
            Toggle("Shiny", isOn: $pet.shiny)
        }
        if pet.enabled && pet.clickThrough {
            Button {
                pet.clickThrough = false
            } label: {
                Image(systemName: "cursorarrow.rays")
            }
            .help("Click-through is on. Click to make the pet interactive again.")
        }
    }
}

struct FooterView: View {
    @Environment(UsageStore.self) private var store
    var openSettings: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: openSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            Button {
                if let u = store.gatewayUIURL { NSWorkspace.shared.open(u) }
            } label: {
                Label("Gateway UI", systemImage: "safari")
            }
            .disabled(store.gatewayUIURL == nil)
            PetFooterToggle()
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
