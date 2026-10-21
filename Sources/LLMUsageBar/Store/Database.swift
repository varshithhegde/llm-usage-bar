import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin, thread-safe SQLite wrapper holding all locally persisted usage data.
final class Database: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    let url: URL

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LLMUsageBar", isDirectory: true)
    }

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw NSError(domain: "Database", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        migrate()
    }

    deinit { sqlite3_close(db) }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS daily (
            date TEXT PRIMARY KEY,
            spend REAL NOT NULL DEFAULT 0,
            prompt_tokens INTEGER NOT NULL DEFAULT 0,
            completion_tokens INTEGER NOT NULL DEFAULT 0,
            total_tokens INTEGER NOT NULL DEFAULT 0,
            api_requests INTEGER NOT NULL DEFAULT 0,
            successful_requests INTEGER NOT NULL DEFAULT 0,
            failed_requests INTEGER NOT NULL DEFAULT 0,
            cache_read_tokens INTEGER NOT NULL DEFAULT 0,
            cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
            breakdown TEXT,
            source TEXT NOT NULL DEFAULT 'api',
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL,
            kind TEXT NOT NULL,
            ref TEXT NOT NULL,
            spend REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_snap ON snapshots(kind, ref, ts);
        CREATE TABLE IF NOT EXISTS cache (
            name TEXT PRIMARY KEY,
            data BLOB NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT
        );
        """)
    }

    // MARK: - Low level

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private enum Value { case text(String?), real(Double), int(Int), blob(Data) }

    private func withStatement<T>(_ sql: String, _ binds: [Value], _ body: (OpaquePointer) -> T) -> T? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return nil }
        defer { sqlite3_finalize(s) }
        for (i, v) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .text(let t):
                if let t { sqlite3_bind_text(s, idx, t, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(s, idx) }
            case .real(let d): sqlite3_bind_double(s, idx, d)
            case .int(let n): sqlite3_bind_int64(s, idx, Int64(n))
            case .blob(let d):
                _ = d.withUnsafeBytes { sqlite3_bind_blob(s, idx, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
            }
        }
        return body(s)
    }

    private func run(_ sql: String, _ binds: [Value]) {
        lock.lock(); defer { lock.unlock() }
        _ = withStatement(sql, binds) { sqlite3_step($0) }
    }

    private func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }

    // MARK: - Daily

    func upsertDaily(_ rows: [DailyRow]) {
        guard !rows.isEmpty else { return }
        let enc = JSONEncoder()
        lock.lock(); defer { lock.unlock() }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        let sql = """
        INSERT INTO daily (date, spend, prompt_tokens, completion_tokens, total_tokens, api_requests,
            successful_requests, failed_requests, cache_read_tokens, cache_creation_tokens, breakdown, source, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(date) DO UPDATE SET
            spend=excluded.spend, prompt_tokens=excluded.prompt_tokens, completion_tokens=excluded.completion_tokens,
            total_tokens=excluded.total_tokens, api_requests=excluded.api_requests,
            successful_requests=excluded.successful_requests, failed_requests=excluded.failed_requests,
            cache_read_tokens=excluded.cache_read_tokens, cache_creation_tokens=excluded.cache_creation_tokens,
            breakdown=excluded.breakdown, source=excluded.source, updated_at=excluded.updated_at
        """
        let now = Date().timeIntervalSince1970
        for r in rows {
            let m = r.metrics
            let bd = (try? enc.encode(r.breakdown)).flatMap { String(data: $0, encoding: .utf8) }
            _ = withStatement(sql, [
                .text(r.date), .real(m.spend), .int(m.promptTokens), .int(m.completionTokens), .int(m.totalTokens),
                .int(m.apiRequests), .int(m.successfulRequests), .int(m.failedRequests),
                .int(m.cacheReadTokens), .int(m.cacheCreationTokens), .text(bd), .text(r.source), .real(now),
            ]) { sqlite3_step($0) }
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    func allDaily() -> [DailyRow] {
        let dec = JSONDecoder()
        lock.lock(); defer { lock.unlock() }
        let sql = """
        SELECT date, spend, prompt_tokens, completion_tokens, total_tokens, api_requests, successful_requests,
               failed_requests, cache_read_tokens, cache_creation_tokens, breakdown, source
        FROM daily ORDER BY date ASC
        """
        return withStatement(sql, []) { s in
            var out: [DailyRow] = []
            while sqlite3_step(s) == SQLITE_ROW {
                guard let date = text(s, 0) else { continue }
                var m = Metrics()
                m.spend = sqlite3_column_double(s, 1)
                m.promptTokens = Int(sqlite3_column_int64(s, 2))
                m.completionTokens = Int(sqlite3_column_int64(s, 3))
                m.totalTokens = Int(sqlite3_column_int64(s, 4))
                m.apiRequests = Int(sqlite3_column_int64(s, 5))
                m.successfulRequests = Int(sqlite3_column_int64(s, 6))
                m.failedRequests = Int(sqlite3_column_int64(s, 7))
                m.cacheReadTokens = Int(sqlite3_column_int64(s, 8))
                m.cacheCreationTokens = Int(sqlite3_column_int64(s, 9))
                let bd = text(s, 10).flatMap { try? dec.decode(DailyBreakdown.self, from: Data($0.utf8)) } ?? DailyBreakdown()
                out.append(DailyRow(date: date, metrics: m, breakdown: bd, source: text(s, 11) ?? "api"))
            }
            return out
        } ?? []
    }

    // MARK: - Snapshots

    func addSnapshot(_ s: Snapshot) {
        run("INSERT INTO snapshots (ts, kind, ref, spend) VALUES (?,?,?,?)",
            [.real(s.timestamp.timeIntervalSince1970), .text(s.kind), .text(s.ref), .real(s.spend)])
    }

    func snapshots(kind: String, ref: String? = nil) -> [Snapshot] {
        lock.lock(); defer { lock.unlock() }
        let sql = ref == nil
            ? "SELECT ts, kind, ref, spend FROM snapshots WHERE kind=? ORDER BY ts ASC"
            : "SELECT ts, kind, ref, spend FROM snapshots WHERE kind=? AND ref=? ORDER BY ts ASC"
        var binds: [Value] = [.text(kind)]
        if let ref { binds.append(.text(ref)) }
        return withStatement(sql, binds) { s in
            var out: [Snapshot] = []
            while sqlite3_step(s) == SQLITE_ROW {
                out.append(Snapshot(
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(s, 0)),
                    kind: text(s, 1) ?? kind, ref: text(s, 2) ?? "",
                    spend: sqlite3_column_double(s, 3)))
            }
            return out
        } ?? []
    }

    func snapshotCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return withStatement("SELECT COUNT(*) FROM snapshots", []) { s in
            sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int64(s, 0)) : 0
        } ?? 0
    }

    // MARK: - Cache & meta

    func setCache(_ name: String, _ data: Data) {
        run("INSERT OR REPLACE INTO cache (name, data, updated_at) VALUES (?,?,?)",
            [.text(name), .blob(data), .real(Date().timeIntervalSince1970)])
    }

    func cache(_ name: String) -> (data: Data, updated: Date)? {
        lock.lock(); defer { lock.unlock() }
        return withStatement("SELECT data, updated_at FROM cache WHERE name=?", [.text(name)]) { s -> (Data, Date)? in
            guard sqlite3_step(s) == SQLITE_ROW else { return nil }
            let n = Int(sqlite3_column_bytes(s, 0))
            let data = n > 0 ? Data(bytes: sqlite3_column_blob(s, 0), count: n) : Data()
            return (data, Date(timeIntervalSince1970: sqlite3_column_double(s, 1)))
        } ?? nil
    }

    func setMeta(_ key: String, _ value: String?) {
        run("INSERT OR REPLACE INTO meta (key, value) VALUES (?,?)", [.text(key), .text(value)])
    }

    func meta(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return withStatement("SELECT value FROM meta WHERE key=?", [.text(key)]) { s in
            sqlite3_step(s) == SQLITE_ROW ? text(s, 0) : nil
        } ?? nil
    }

    func resetAll() {
        exec("DELETE FROM daily; DELETE FROM snapshots; DELETE FROM cache; DELETE FROM meta; VACUUM;")
    }
}
