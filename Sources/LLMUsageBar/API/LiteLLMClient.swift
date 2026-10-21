import Foundation

enum APIError: LocalizedError {
    case missingKey
    case badURL
    case http(Int, String?)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "No API key configured. Add one in Settings."
        case .badURL: return "The gateway URL is invalid."
        case .http(401, _): return "Unauthorized (401): the API key was rejected."
        case .http(403, _): return "Forbidden (403): this key can't access that endpoint."
        case .http(404, _): return "Not found (404): endpoint unavailable on this gateway."
        case .http(let c, let m): return "HTTP \(c)" + (m.map { ": \($0)" } ?? "")
        case .decoding(let what): return "Unexpected response format from \(what)."
        case .transport(let m): return m
        }
    }

    var isUnavailable: Bool {
        if case .http(let c, _) = self { return [403, 404, 405, 501].contains(c) }
        return false
    }
}

struct LiteLLMClient {
    var baseURL: URL
    var apiKey: String
    var session: URLSession = .shared

    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        for suffix in ["/v1", "/ui"] where s.lowercased().hasSuffix(suffix) {
            s.removeLast(suffix.count)
        }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), u.host != nil else { return nil }
        return u
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError.badURL
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.badURL }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                throw APIError.http(code, Self.errorMessage(data))
            }
            return data
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    private static func errorMessage(_ data: Data) -> String? {
        guard let o = J.parse(data) as? JSONObject else { return nil }
        let e = o["error"] ?? o["detail"]
        if let s = J.string(e) { return String(s.prefix(160)) }
        if let d = e as? JSONObject, let m = J.string(J.first(d, "message", "detail")) { return String(m.prefix(160)) }
        return nil
    }

    func keyInfo() async throws -> (KeyInfo, Data) {
        let d = try await get("key/info")
        guard let k = KeyInfo.parse(d) else { throw APIError.decoding("/key/info") }
        return (k, d)
    }

    func userInfo() async throws -> (UserInfo, Data) {
        let d = try await get("user/info")
        guard let u = UserInfo.parse(d) else { throw APIError.decoding("/user/info") }
        return (u, d)
    }

    func models() async throws -> ([String], Data) {
        let d = try await get("v1/models")
        guard let m = ModelList.parse(d) else { throw APIError.decoding("/v1/models") }
        return (m, d)
    }

    /// Fetches all pages of daily activity for the inclusive date range.
    func dailyActivity(start: String, end: String) async throws -> [DailyRow] {
        var page = 1
        var rows: [DailyRow] = []
        while page <= 200 {
            let d = try await get("user/daily/activity", query: [
                .init(name: "start_date", value: start),
                .init(name: "end_date", value: end),
                .init(name: "page", value: String(page)),
                .init(name: "page_size", value: "1000"),
            ])
            guard let p = DailyActivityPage.parse(d) else { throw APIError.decoding("/user/daily/activity") }
            rows.append(contentsOf: p.rows)
            if !p.hasMore || p.rows.isEmpty { break }
            page += 1
        }
        return Self.mergeByDate(rows)
    }

    /// Pages could theoretically split a date; merge rows with equal dates.
    static func mergeByDate(_ rows: [DailyRow]) -> [DailyRow] {
        var map: [String: DailyRow] = [:]
        for r in rows {
            if var e = map[r.date] {
                e.metrics += r.metrics
                for (k, v) in r.breakdown.models { e.breakdown.models[k, default: .zero] += v }
                for (k, v) in r.breakdown.providers { e.breakdown.providers[k, default: .zero] += v }
                for (k, v) in r.breakdown.keys {
                    var cur = e.breakdown.keys[k] ?? KeyBreakdown(alias: v.alias, metrics: .zero)
                    cur.metrics += v.metrics
                    cur.alias = cur.alias ?? v.alias
                    e.breakdown.keys[k] = cur
                }
                map[r.date] = e
            } else {
                map[r.date] = r
            }
        }
        return map.values.sorted { $0.date < $1.date }
    }
}
