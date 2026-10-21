import Foundation
import Observation
import AppKit

struct ModelUsage: Identifiable {
    var name: String
    var metrics: Metrics
    var share: Double
    var id: String { name }
}

struct KeyUsage: Identifiable {
    var key: UserKey?
    var hash: String
    var alias: String?
    var lifetimeSpend: Double
    var periodSpend: Double?
    var periodRequests: Int?
    var id: String { hash }
}

struct PeriodTrend {
    var current: Double
    var previous: Double
    var percent: Double? {
        guard previous > 0.0001 else { return nil }
        return (current - previous) / previous * 100
    }
}

@MainActor
@Observable
final class UsageStore {
    // Data
    private(set) var user: UserInfo?
    private(set) var keyInfo: KeyInfo?
    private(set) var models: [String] = []
    private(set) var daily: [DailyRow] = []
    private(set) var usingSnapshotFallback = false
    private(set) var dailyEndpointMessage: String?

    // Status
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    private(set) var lastError: String?
    private(set) var backfillProgress: String?
    var hasKey: Bool = Keychain.resolvedKey() != nil

    // Settings mirrors (persisted to UserDefaults)
    var menuBarMode: MenuBarMode {
        didSet { UserDefaults.standard.set(menuBarMode.rawValue, forKey: SettingsKeys.menuBarMode) }
    }
    var refreshMinutes: Int {
        didSet {
            UserDefaults.standard.set(refreshMinutes, forKey: SettingsKeys.refreshMinutes)
            restartTimer()
        }
    }
    var baseURLString: String {
        didSet { UserDefaults.standard.baseURLString = baseURLString }
    }

    let db: Database?
    private var timerTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    init(database: Database? = nil, startTimers: Bool = true) {
        let d = UserDefaults.standard
        menuBarMode = MenuBarMode(rawValue: d.string(forKey: SettingsKeys.menuBarMode) ?? "") ?? .today
        refreshMinutes = d.refreshMinutes
        baseURLString = d.baseURLString
        if let database {
            db = database
        } else {
            db = try? Database(url: Database.defaultDirectory.appendingPathComponent("usage.sqlite"))
        }
        loadCached()
        if startTimers {
            restartTimer()
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await self?.refresh()
                }
            }
            Task { await refresh() }
        }
    }

    // MARK: - Cache

    func loadCached() {
        guard let db else { return }
        if let c = db.cache("user_info") { user = UserInfo.parse(c.data); lastUpdated = c.updated }
        if let c = db.cache("key_info") { keyInfo = KeyInfo.parse(c.data) }
        if let c = db.cache("models") { models = ModelList.parse(c.data) ?? [] }
        usingSnapshotFallback = db.meta("daily_unavailable") == "1"
        rebuildDaily()
    }

    private func rebuildDaily() {
        guard let db else { daily = []; return }
        let stored = db.allDaily()
        if usingSnapshotFallback || stored.isEmpty {
            daily = Self.mergeWithSnapshots(apiRows: stored, snapshots: db.snapshots(kind: "user"))
        } else {
            daily = stored
        }
    }

    /// API rows take precedence; snapshot-derived deltas fill days with no API data.
    static func mergeWithSnapshots(apiRows: [DailyRow], snapshots: [Snapshot]) -> [DailyRow] {
        var byDate = Dictionary(uniqueKeysWithValues: apiRows.map { ($0.date, $0) })
        for (date, spend) in SnapshotMath.dailyDeltas(snapshots) where byDate[date] == nil {
            var m = Metrics(); m.spend = spend
            byDate[date] = DailyRow(date: date, metrics: m, breakdown: DailyBreakdown(), source: "snapshot")
        }
        return byDate.values.sorted { $0.date < $1.date }
    }

    // MARK: - Refresh

    private func restartTimer() {
        timerTask?.cancel()
        let minutes = max(1, refreshMinutes)
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
                if Task.isCancelled { break }
                await self?.refresh()
            }
        }
    }

    func refreshIfStale() {
        guard let lastUpdated else { Task { await refresh() }; return }
        if Date().timeIntervalSince(lastUpdated) > 60 { Task { await refresh() } }
    }

    func makeClient() throws -> LiteLLMClient {
        guard let key = Keychain.resolvedKey()?.key else { throw APIError.missingKey }
        guard let url = LiteLLMClient.normalize(baseURLString) else { throw APIError.badURL }
        return LiteLLMClient(baseURL: url, apiKey: key)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        hasKey = Keychain.resolvedKey() != nil
        let client: LiteLLMClient
        do { client = try makeClient() } catch {
            lastError = error.localizedDescription
            return
        }
        isRefreshing = true
        defer { isRefreshing = false; backfillProgress = nil }
        var errors: [String] = []
        let now = Date()

        async let userTask = client.userInfo()
        async let keyTask = client.keyInfo()
        async let modelsTask = client.models()

        do {
            let (u, raw) = try await userTask
            user = u
            db?.setCache("user_info", raw)
            if let id = u.userID ?? keyInfo?.userID {
                db?.addSnapshot(Snapshot(timestamp: now, kind: "user", ref: id, spend: u.spend))
            }
            for k in u.keys {
                db?.addSnapshot(Snapshot(timestamp: now, kind: "key", ref: k.token, spend: k.spend))
            }
        } catch { errors.append("User info: \(error.localizedDescription)") }

        do {
            let (k, raw) = try await keyTask
            keyInfo = k
            db?.setCache("key_info", raw)
        } catch { errors.append("Key info: \(error.localizedDescription)") }

        do {
            let (m, raw) = try await modelsTask
            models = m
            db?.setCache("models", raw)
        } catch { /* models list is non-essential */ }

        await refreshDaily(client: client, errors: &errors)

        rebuildDaily()
        if errors.isEmpty || user != nil { lastUpdated = now }
        lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        BudgetAlert.check(todaySpend: todaySpend)
    }

    private func refreshDaily(client: LiteLLMClient, errors: inout [String]) async {
        guard let db else { return }
        let today = Day.today
        let backfilled = db.meta("backfill_done") == "1"
        var start: String
        if backfilled {
            start = Day.offset(today, by: -3)
        } else if let created = user?.createdAt {
            start = Day.key(created)
            backfillProgress = "Backfilling history since \(start)…"
        } else {
            start = Day.offset(today, by: -90)
            backfillProgress = "Backfilling last 90 days…"
        }
        if start > today { start = today }
        do {
            // Fetch in ~90-day chunks so long backfills don't produce huge responses.
            var chunkStart = start
            while chunkStart <= today {
                let chunkEnd = min(Day.offset(chunkStart, by: 89), Day.offset(today, by: 1))
                let rows = try await client.dailyActivity(start: chunkStart, end: chunkEnd)
                db.upsertDaily(rows)
                chunkStart = Day.offset(chunkEnd, by: 1)
            }
            // Only mark complete once we've backfilled from the account's real creation date.
            if !backfilled, user?.createdAt != nil { db.setMeta("backfill_done", "1") }
            db.setMeta("daily_unavailable", "0")
            usingSnapshotFallback = false
            dailyEndpointMessage = nil
        } catch let e as APIError where e.isUnavailable {
            db.setMeta("daily_unavailable", "1")
            usingSnapshotFallback = true
            dailyEndpointMessage = "Daily activity isn't available for this key (\(e.localizedDescription)). Showing spend derived from local snapshots."
        } catch {
            errors.append("Daily activity: \(error.localizedDescription)")
        }
    }

    func resetLocalData() {
        db?.resetAll()
        user = nil; keyInfo = nil; models = []; daily = []
        lastUpdated = nil; usingSnapshotFallback = false
        Task { await refresh() }
    }

    // MARK: - Derived values

    private func spend(from start: String, to end: String) -> Double {
        daily.filter { $0.date >= start && $0.date <= end }.reduce(0) { $0 + $1.metrics.spend }
    }

    func row(for date: String) -> DailyRow? { daily.first { $0.date == date } }

    var todayMetrics: Metrics { row(for: Day.today)?.metrics ?? .zero }
    var todaySpend: Double { todayMetrics.spend }
    var yesterdaySpend: Double { row(for: Day.offset(Day.today, by: -1))?.metrics.spend ?? 0 }
    var last7Spend: Double { spend(from: Day.offset(Day.today, by: -6), to: Day.today) }
    var monthSpend: Double { spend(from: String(Day.today.prefix(7)) + "-01", to: Day.today) }
    var lifetimeSpend: Double { user?.spend ?? keyInfo?.spend ?? daily.reduce(0) { $0 + $1.metrics.spend } }

    var menuBarText: String? {
        switch menuBarMode {
        case .today: return Fmt.currency(todaySpend)
        case .week: return Fmt.currency(last7Spend)
        case .lifetime: return Fmt.currency(lifetimeSpend)
        case .iconOnly: return nil
        }
    }

    func startDate(for period: Period) -> String {
        if let days = period.days { return Day.offset(Day.today, by: -(days - 1)) }
        return daily.first?.date ?? Day.today
    }

    /// Continuous series (zero-filled) for charts.
    func series(for period: Period) -> [DailyRow] {
        let start = startDate(for: period)
        let byDate = Dictionary(uniqueKeysWithValues: daily.map { ($0.date, $0) })
        return Day.range(from: start, to: Day.today).map {
            byDate[$0] ?? DailyRow(date: $0, metrics: .zero, breakdown: DailyBreakdown(), source: "empty")
        }
    }

    func trend(for period: Period) -> PeriodTrend? {
        guard let days = period.days else { return nil }
        let curStart = Day.offset(Day.today, by: -(days - 1))
        let prevEnd = Day.offset(curStart, by: -1)
        let prevStart = Day.offset(prevEnd, by: -(days - 1))
        return PeriodTrend(current: spend(from: curStart, to: Day.today), previous: spend(from: prevStart, to: prevEnd))
    }

    func modelUsage(for period: Period) -> [ModelUsage] {
        let start = startDate(for: period)
        var agg: [String: Metrics] = [:]
        for r in daily where r.date >= start {
            for (m, v) in r.breakdown.models { agg[m, default: .zero] += v }
        }
        if agg.isEmpty, period == .all, let ms = user?.modelSpend, !ms.isEmpty {
            for (m, s) in ms { var x = Metrics(); x.spend = s; agg[m] = x }
        }
        let total = agg.values.reduce(0) { $0 + $1.spend }
        return agg.map { ModelUsage(name: $0.key, metrics: $0.value, share: total > 0 ? $0.value.spend / total : 0) }
            .sorted { $0.metrics.spend == $1.metrics.spend ? $0.metrics.apiRequests > $1.metrics.apiRequests : $0.metrics.spend > $1.metrics.spend }
    }

    func keyUsage(for period: Period) -> [KeyUsage] {
        let start = startDate(for: period)
        var agg: [String: (alias: String?, m: Metrics)] = [:]
        for r in daily where r.date >= start {
            for (h, v) in r.breakdown.keys {
                let cur = agg[h] ?? (v.alias, .zero)
                agg[h] = (cur.alias ?? v.alias, cur.m + v.metrics)
            }
        }
        var out: [KeyUsage] = []
        var seen = Set<String>()
        for k in user?.keys ?? [] {
            let a = agg[k.token]
            out.append(KeyUsage(key: k, hash: k.token, alias: k.alias ?? a?.alias, lifetimeSpend: k.spend,
                                periodSpend: a?.m.spend, periodRequests: a?.m.apiRequests))
            seen.insert(k.token)
        }
        for (h, a) in agg where !seen.contains(h) {
            out.append(KeyUsage(key: nil, hash: h, alias: a.alias, lifetimeSpend: 0,
                                periodSpend: a.m.spend, periodRequests: a.m.apiRequests))
        }
        return out.sorted { ($0.periodSpend ?? $0.lifetimeSpend) > ($1.periodSpend ?? $1.lifetimeSpend) }
    }

    var gatewayUIURL: URL? {
        LiteLLMClient.normalize(baseURLString)?.appendingPathComponent("ui")
    }

    // MARK: - Export

    func csv() -> String {
        var lines = ["date,spend_usd,api_requests,successful_requests,failed_requests,prompt_tokens,completion_tokens,total_tokens,cache_read_tokens,cache_creation_tokens,source,top_model"]
        for r in daily {
            let m = r.metrics
            let top = r.breakdown.models.max { $0.value.spend < $1.value.spend }?.key ?? ""
            let esc = "\"" + top.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            lines.append([r.date, String(format: "%.6f", m.spend), "\(m.apiRequests)", "\(m.successfulRequests)",
                          "\(m.failedRequests)", "\(m.promptTokens)", "\(m.completionTokens)", "\(m.totalTokens)",
                          "\(m.cacheReadTokens)", "\(m.cacheCreationTokens)", r.source, esc].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
