import Foundation

struct Metrics: Codable, Equatable {
    var spend: Double = 0
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var totalTokens: Int = 0
    var apiRequests: Int = 0
    var successfulRequests: Int = 0
    var failedRequests: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0

    static let zero = Metrics()

    init() {}

    init(json: JSONObject?) {
        guard let m = json else { return }
        spend = J.double(J.first(m, "spend")) ?? 0
        promptTokens = J.int(J.first(m, "prompt_tokens", "input_tokens")) ?? 0
        completionTokens = J.int(J.first(m, "completion_tokens", "output_tokens")) ?? 0
        totalTokens = J.int(J.first(m, "total_tokens")) ?? (promptTokens + completionTokens)
        apiRequests = J.int(J.first(m, "api_requests", "requests")) ?? 0
        successfulRequests = J.int(J.first(m, "successful_requests")) ?? 0
        failedRequests = J.int(J.first(m, "failed_requests")) ?? 0
        cacheReadTokens = J.int(J.first(m, "cache_read_input_tokens")) ?? 0
        cacheCreationTokens = J.int(J.first(m, "cache_creation_input_tokens")) ?? 0
        if totalTokens == 0 { totalTokens = promptTokens + completionTokens }
    }

    static func + (a: Metrics, b: Metrics) -> Metrics {
        var r = Metrics()
        r.spend = a.spend + b.spend
        r.promptTokens = a.promptTokens + b.promptTokens
        r.completionTokens = a.completionTokens + b.completionTokens
        r.totalTokens = a.totalTokens + b.totalTokens
        r.apiRequests = a.apiRequests + b.apiRequests
        r.successfulRequests = a.successfulRequests + b.successfulRequests
        r.failedRequests = a.failedRequests + b.failedRequests
        r.cacheReadTokens = a.cacheReadTokens + b.cacheReadTokens
        r.cacheCreationTokens = a.cacheCreationTokens + b.cacheCreationTokens
        return r
    }

    static func += (a: inout Metrics, b: Metrics) { a = a + b }
}

struct KeyBreakdown: Codable, Equatable {
    var alias: String?
    var metrics: Metrics
}

struct DailyBreakdown: Codable, Equatable {
    var models: [String: Metrics] = [:]
    var keys: [String: KeyBreakdown] = [:]
    var providers: [String: Metrics] = [:]
}

/// One row of daily usage. `source` is "api" (from /user/daily/activity) or "snapshot" (derived).
struct DailyRow: Identifiable, Equatable {
    var date: String
    var metrics: Metrics
    var breakdown: DailyBreakdown
    var source: String = "api"
    var id: String { date }
}

struct DailyActivityPage {
    var rows: [DailyRow]
    var page: Int
    var totalPages: Int
    var hasMore: Bool

    /// Parses LiteLLM's `/user/daily/activity` payload leniently.
    static func parse(_ data: Data) -> DailyActivityPage? {
        guard let root = J.parse(data) as? JSONObject else { return nil }
        let results = J.array(J.first(root, "results", "data"))
        var rows: [DailyRow] = []
        for case let r as JSONObject in results {
            guard let rawDate = J.string(r["date"]) else { continue }
            let date = String(rawDate.prefix(10))
            let metrics = Metrics(json: J.dict(r["metrics"]))
            var bd = DailyBreakdown()
            let b = J.dict(r["breakdown"])
            for (name, v) in J.dict(b?["models"]) ?? [:] {
                bd.models[name] = Metrics(json: J.dict((v as? JSONObject)?["metrics"]))
            }
            for (name, v) in J.dict(b?["providers"]) ?? [:] {
                bd.providers[name] = Metrics(json: J.dict((v as? JSONObject)?["metrics"]))
            }
            for (hash, v) in J.dict(b?["api_keys"]) ?? [:] {
                let o = v as? JSONObject
                let alias = J.string(J.dict(o?["metadata"])?["key_alias"])
                bd.keys[hash] = KeyBreakdown(alias: alias, metrics: Metrics(json: J.dict(o?["metrics"])))
            }
            rows.append(DailyRow(date: date, metrics: metrics, breakdown: bd))
        }
        let meta = J.dict(root["metadata"])
        let page = J.int(meta?["page"]) ?? 1
        let total = J.int(meta?["total_pages"]) ?? page
        let hasMore = (meta?["has_more"] as? Bool) ?? (page < total)
        return DailyActivityPage(rows: rows, page: page, totalPages: total, hasMore: hasMore)
    }
}

struct KeyInfo: Equatable {
    var token: String?
    var alias: String?
    var userID: String?
    var teamID: String?
    var spend: Double
    var maxBudget: Double?
    var budgetDuration: String?
    var budgetResetAt: Date?
    var tpmLimit: Int?
    var rpmLimit: Int?
    var expires: Date?
    var models: [String]

    static func parse(_ data: Data) -> KeyInfo? {
        guard let root = J.parse(data) as? JSONObject else { return nil }
        let i = J.dict(root["info"]) ?? root
        return KeyInfo(
            token: J.string(root["key"]) ?? J.string(i["token"]),
            alias: J.string(i["key_alias"]),
            userID: J.string(i["user_id"]),
            teamID: J.string(i["team_id"]),
            spend: J.double(i["spend"]) ?? 0,
            maxBudget: J.double(i["max_budget"]),
            budgetDuration: J.string(i["budget_duration"]),
            budgetResetAt: DateParse.iso8601(i["budget_reset_at"]),
            tpmLimit: J.int(i["tpm_limit"]),
            rpmLimit: J.int(i["rpm_limit"]),
            expires: DateParse.iso8601(i["expires"]),
            models: J.strings(i["models"])
        )
    }
}

struct UserKey: Identifiable, Equatable {
    var token: String
    var keyName: String?
    var alias: String?
    var spend: Double
    var maxBudget: Double?
    var createdAt: Date?
    var lastActive: Date?
    var expires: Date?
    var models: [String]
    var id: String { token }

    var displayName: String { alias ?? keyName ?? "Unnamed key" }
    var masked: String {
        if let n = keyName, !n.isEmpty { return n }
        guard token.count > 8 else { return "••••" }
        return "…" + token.suffix(6)
    }
}

struct UserInfo: Equatable {
    var userID: String?
    var alias: String?
    var email: String?
    var role: String?
    var spend: Double
    var maxBudget: Double?
    var budgetDuration: String?
    var budgetResetAt: Date?
    var createdAt: Date?
    var teams: [String]
    var modelSpend: [String: Double]
    var keys: [UserKey]

    var displayName: String { alias ?? email ?? userID ?? "LiteLLM user" }

    static func parse(_ data: Data) -> UserInfo? {
        guard let root = J.parse(data) as? JSONObject else { return nil }
        let u = J.dict(root["user_info"]) ?? [:]
        var keys: [UserKey] = []
        for case let k as JSONObject in J.array(root["keys"]) {
            guard let token = J.string(J.first(k, "token", "key")) else { continue }
            keys.append(UserKey(
                token: token,
                keyName: J.string(k["key_name"]),
                alias: J.string(k["key_alias"]),
                spend: J.double(k["spend"]) ?? 0,
                maxBudget: J.double(k["max_budget"]),
                createdAt: DateParse.iso8601(k["created_at"]),
                lastActive: DateParse.iso8601(J.first(k, "last_active", "updated_at")),
                expires: DateParse.iso8601(k["expires"]),
                models: J.strings(k["models"])
            ))
        }
        var modelSpend: [String: Double] = [:]
        for (m, v) in J.dict(u["model_spend"]) ?? [:] {
            if let d = J.double(v) { modelSpend[m] = d }
        }
        var teams = J.strings(u["teams"])
        if teams.isEmpty {
            teams = J.array(root["teams"]).compactMap {
                J.string(J.first($0 as? JSONObject, "team_alias", "team_id"))
            }
        }
        return UserInfo(
            userID: J.string(J.first(u, "user_id")) ?? J.string(root["user_id"]),
            alias: J.string(u["user_alias"]),
            email: J.string(u["user_email"]),
            role: J.string(u["user_role"]),
            spend: J.double(u["spend"]) ?? keys.reduce(0) { $0 + $1.spend },
            maxBudget: J.double(u["max_budget"]),
            budgetDuration: J.string(u["budget_duration"]),
            budgetResetAt: DateParse.iso8601(u["budget_reset_at"]),
            createdAt: DateParse.iso8601(u["created_at"]),
            teams: teams,
            modelSpend: modelSpend,
            keys: keys.sorted { $0.spend > $1.spend }
        )
    }
}

enum ModelList {
    static func parse(_ data: Data) -> [String]? {
        guard let root = J.parse(data) as? JSONObject else { return nil }
        let ids = J.array(root["data"]).compactMap { J.string(($0 as? JSONObject)?["id"]) }
        return Array(Set(ids)).sorted()
    }
}

struct Snapshot: Equatable {
    var timestamp: Date
    var kind: String   // "user" | "key"
    var ref: String    // user id or key token
    var spend: Double
}

enum SnapshotMath {
    /// Derives per-day spend from a time-ordered series of cumulative spend snapshots.
    /// Each consecutive delta is attributed to the day of the later snapshot. A drop in
    /// cumulative spend is treated as a budget reset (the new value is spend since reset).
    static func dailyDeltas(_ snaps: [Snapshot]) -> [String: Double] {
        let sorted = snaps.sorted { $0.timestamp < $1.timestamp }
        var out: [String: Double] = [:]
        guard var prev = sorted.first else { return out }
        out[Day.key(prev.timestamp), default: 0] += 0
        for s in sorted.dropFirst() {
            let delta = s.spend >= prev.spend ? s.spend - prev.spend : s.spend
            out[Day.key(s.timestamp), default: 0] += delta
            prev = s
        }
        return out
    }
}
