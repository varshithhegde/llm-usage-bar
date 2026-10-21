import Foundation
import AppKit

/// Offline sanity checks, run with `LLMUsageBar --selftest`.
@MainActor
enum SelfTest {
    private static var failures = 0

    private static func check(_ cond: Bool, _ name: String) {
        print((cond ? "  ✓ " : "  ✗ ") + name)
        if !cond { failures += 1 }
    }

    private static func runPlacementTests() {
        print("• Pet placement (multi-display)")
        let size = CGSize(width: 200, height: 150)
        let builtIn = DisplayInfo(id: "UUID-BUILTIN", name: "Built-in Retina Display",
                                  frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080), isMain: true)
        let ext = DisplayInfo(id: "UUID-EXT", name: "LG UltraFine",
                              frame: CGRect(x: 1728, y: 37, width: 1920, height: 1080),
                              visibleFrame: CGRect(x: 1728, y: 37, width: 1920, height: 1050), isMain: false)
        // Same monitor after reconnect: new arrangement and resolution, same UUID.
        let extMoved = DisplayInfo(id: "UUID-EXT", name: "LG UltraFine",
                                   frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440),
                                   visibleFrame: CGRect(x: -2560, y: 0, width: 2560, height: 1410), isMain: false)

        // Relative ↔ absolute
        let vf = ext.visibleFrame
        let rel = PetPlacement.toRelative(CGPoint(x: 1728 + 480, y: 37 + 525), in: vf)
        check(abs(rel.x - 0.25) < 1e-9 && abs(rel.y - 0.5) < 1e-9, "absolute → relative")
        check(PetPlacement.toAbsolute(rel, in: vf) == CGPoint(x: 2208, y: 562), "relative → absolute")
        check(PetPlacement.toAbsolute(rel, in: extMoved.visibleFrame) == CGPoint(x: -1920, y: 705), "relative survives arrangement + resolution change")
        let outside = PetPlacement.toRelative(CGPoint(x: -50, y: 99999), in: vf)
        check(outside == RelativePoint(x: 0, y: 1), "relative clamped to 0…1")

        // Clamp
        let c1 = PetPlacement.clamp(CGPoint(x: 1730, y: 1000), size: size, in: vf)
        check(c1 == CGPoint(x: 1828, y: 937), "clamp keeps whole pet inside")
        let tiny = PetPlacement.clamp(CGPoint(x: 5, y: 5), size: size, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        check(tiny == CGPoint(x: 50, y: 0), "clamp on a screen smaller than the pet")
        let def = PetPlacement.defaultAnchor(size: size, in: builtIn.visibleFrame)
        check(def == CGPoint(x: 1728 - 24 - 100, y: 24), "default is bottom-right with margin")

        // User drag onto the external display sets preferred + saves position there.
        guard let dragged = PetPlacement.recordUserPlacement(PlacementState(), anchor: CGPoint(x: 2208, y: 562),
                                                             displays: [builtIn, ext], size: size) else {
            check(false, "drag placement"); return
        }
        var state = dragged.state
        check(state.preferredDisplay == "UUID-EXT" && dragged.decision.displayID == "UUID-EXT", "drag sets preferred display")
        check(state.names["UUID-EXT"] == "LG UltraFine", "display name remembered")

        // Disconnect: fall back to built-in (default corner, nothing saved there yet).
        let fb = PetPlacement.resolve(state: state, displays: [builtIn], size: size)
        check(fb?.displayID == "UUID-BUILTIN" && fb?.isFallback == true, "fallback to remaining screen")
        check(fb?.anchor == def, "fallback uses default corner when no saved spot")
        state = PetPlacement.refreshNames(state, displays: [builtIn])
        check(state.preferredDisplay == "UUID-EXT", "fallback doesn't overwrite preferred display")
        check(state.positions["UUID-EXT"] == rel, "fallback doesn't overwrite saved position")

        // Fallback uses the remaining screen's own saved spot when it has one.
        var withBuiltin = state
        withBuiltin.positions["UUID-BUILTIN"] = RelativePoint(x: 0.1, y: 0.5)
        let fb2 = PetPlacement.resolve(state: withBuiltin, displays: [builtIn], size: size)
        check(fb2?.anchor == CGPoint(x: 173, y: 540), "fallback uses that screen's saved spot")

        // Reconnect (possibly rearranged): back to the saved relative spot on the preferred display.
        let back = PetPlacement.resolve(state: state, displays: [builtIn, extMoved], size: size)
        check(back?.displayID == "UUID-EXT" && back?.isFallback == false, "reconnect restores preferred display")
        check(back?.anchor == CGPoint(x: -1920, y: 705), "reconnect restores relative position")

        // Fallback to the main display, not just the first one listed.
        let noPref = PetPlacement.resolve(state: PlacementState(), displays: [ext, builtIn], size: size)
        check(noPref?.displayID == "UUID-BUILTIN" && noPref?.isFallback == false, "no preference → main display, not fallback")
        check(PetPlacement.resolve(state: state, displays: [], size: size) == nil, "no displays → no decision")

        // Explicit move to screen changes preferred.
        let moved = PetPlacement.moveToDisplay(state, displayID: "UUID-BUILTIN", displays: [builtIn, ext], size: size)
        check(moved?.state.preferredDisplay == "UUID-BUILTIN", "move-to-screen changes preferred display")
        check(moved?.state.positions["UUID-EXT"] == rel, "move-to-screen keeps other display's spot")
        check(PetPlacement.moveToDisplay(state, displayID: "NOPE", displays: [builtIn], size: size) == nil, "move to missing display ignored")

        // Legacy migration: old single absolute anchor assigned to the display containing it.
        let mig = PetPlacement.migrate(legacyAnchor: CGPoint(x: 3531, y: 894), displays: [builtIn, ext], size: size)
        check(mig.preferredDisplay == "UUID-EXT" && mig.positions["UUID-EXT"] != nil, "legacy position migrated to containing display")
        let migOff = PetPlacement.migrate(legacyAnchor: CGPoint(x: -9000, y: 300), displays: [builtIn, ext], size: size)
        check(migOff.preferredDisplay == "UUID-BUILTIN", "off-screen legacy position → nearest display")
        let roundTrip = (try? JSONEncoder().encode(state)).flatMap { try? JSONDecoder().decode(PlacementState.self, from: $0) }
        check(roundTrip == state, "placement state Codable round-trip")

        // Debounce: only the latest scheduled change is acted on.
        var deb = ChangeDebouncer()
        let t1 = deb.schedule(), t2 = deb.schedule(), t3 = deb.schedule()
        check(!deb.isCurrent(t1) && !deb.isCurrent(t2) && deb.isCurrent(t3), "debouncer keeps only latest")

        // Spaces behaviour
        check(PetController.collectionBehavior(allSpaces: true).contains(.canJoinAllSpaces), "all Spaces on")
        let single = PetController.collectionBehavior(allSpaces: false)
        check(!single.contains(.canJoinAllSpaces) && !single.contains(.moveToActiveSpace), "single Space")

        // Live display ids are stable strings (UUID form when available).
        let live = DisplayIdentity.connected
        check(!live.isEmpty && live.allSatisfy { !$0.id.isEmpty }, "live displays have ids (\(live.map(\.name).joined(separator: ", ")))")
        check(Set(live.map(\.id)).count == live.count, "live display ids unique")
    }

    private static func runPetTests() {
        print("• Pet sprite URLs")
        let bw = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-v/black-white/animated"
        let sd = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/other/showdown"
        let png = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon"
        let m = SpriteSource.candidates(id: 150, shiny: false).map(\.absoluteString)
        check(m == ["\(bw)/150.gif", "\(sd)/150.gif", "\(png)/150.png"], "Mewtwo fallback chain")
        let ms = SpriteSource.candidates(id: 150, shiny: true).map(\.absoluteString)
        check(ms.first == "\(bw)/shiny/150.gif", "shiny Gen V first")
        check(ms.last == "\(png)/150.png", "shiny falls back to regular art")
        let gen9 = SpriteSource.candidates(id: 1000, shiny: false).map(\.absoluteString)
        check(gen9 == ["\(sd)/1000.gif", "\(png)/1000.png"], "id > 649 skips black-white")
        check(SpriteSource.candidates(id: 649, shiny: false).first == URL(string: "\(bw)/649.gif"), "id 649 uses black-white")

        print("• Pet sprite cache")
        let dir = URL(fileURLWithPath: "/tmp/x")
        check(SpriteCache.spriteFile(id: 150, shiny: false, in: dir).path == "/tmp/x/150.sprite", "regular cache path")
        check(SpriteCache.spriteFile(id: 150, shiny: true, in: dir).path == "/tmp/x/150-shiny.sprite", "shiny cache path")
        check(SpriteCache.directory.path.hasSuffix("Application Support/LLMUsageBar/sprites"), "cache dir under app support")
        check(PetCatalog.curated.count == 34 && Set(PetCatalog.curated.map(\.id)).count == 34, "34 unique curated Pokémon")
        check(PetCatalog.clamp(0) == 1 && PetCatalog.clamp(5000) == 1025, "custom id clamped")

        print("• Pet mood")
        check(PetMood.compute(todaySpend: 1, budget: nil, baseline: 10) == .calm, "baseline <50% calm")
        check(PetMood.compute(todaySpend: 8, budget: nil, baseline: 10) == .normal, "baseline 80% normal")
        check(PetMood.compute(todaySpend: 12, budget: nil, baseline: 10) == .excited, "baseline 120% excited")
        check(PetMood.compute(todaySpend: 16, budget: nil, baseline: 10) == .overheated, "baseline 160% overheated")
        check(PetMood.compute(todaySpend: 0, budget: nil, baseline: 0) == .calm, "no data calm")
        check(PetMood.compute(todaySpend: 3, budget: nil, baseline: 0) == .normal, "no baseline, some spend normal")
        check(PetMood.compute(todaySpend: 20, budget: 50, baseline: 1) == .calm, "budget takes precedence over baseline")
        check(PetMood.compute(todaySpend: 45, budget: 50, baseline: 1) == .excited, "90% of budget excited")
        check(PetMood.compute(todaySpend: 50, budget: 50, baseline: 100) == .overheated, "at budget overheated")

        print("• Pet layout & GIF decode")
        let ds = PetLayout.displaySize(natural: CGSize(width: 40, height: 50), scale: 2)
        check(ds == CGSize(width: 80, height: 100), "2× native size")
        let big = PetLayout.displaySize(natural: CGSize(width: 200, height: 100), scale: 1)
        check(big.width == 96 && big.height == 48, "large sprite fitted to box")
        let clamped = PetPlacement.clamp(CGPoint(x: 5000, y: -300), size: CGSize(width: 100, height: 100),
                                         in: CGRect(x: 0, y: 0, width: 1440, height: 900))
        check(clamped == CGPoint(x: 1390, y: 0), "off-screen anchor clamped")
        runPlacementTests()
        // 1×1 two-frame GIF (delays 10cs and 0 → 0.1 s each).
        let gif = Data(base64Encoded: "R0lGODlhAQABAPAAAAAAAP///yH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAQABAAACAkQBACH5BAAAAAAALAAAAAABAAEAAAICTAEAOw==")!
        let anim = SpriteAnimation(data: gif)
        check(anim?.frames.count == 2, "GIF frames decoded")
        check(anim.map { abs($0.duration - 0.2) < 0.001 } == true, "GIF delays (zero → 100 ms)")
        check(anim?.keyTimes == [0, 0.5, 1], "keyframe times")
        check(SpriteAnimation(data: Data("nope".utf8)) == nil, "invalid image rejected")
    }

    static func run() -> Bool {
        print("LLMUsageBar self-test")

        print("• JSON parsing")
        let keyJSON = """
        {"key":"88dc28d0f030c55ed4ab77ed8faf098196cb1c05df778539800c9f1243fe6b4b","info":{"key_alias":"ai-usage","user_id":"u-1","team_id":null,
         "spend":"12.5","max_budget":null,"budget_duration":null,"budget_reset_at":null,"tpm_limit":100000,"rpm_limit":"60",
         "expires":null,"models":[],"unknown_field":{"nested":true}}}
        """
        let k = KeyInfo.parse(Data(keyJSON.utf8))
        check(k?.alias == "ai-usage", "key alias")
        check(k?.spend == 12.5, "numeric string spend")
        check(k?.rpmLimit == 60 && k?.tpmLimit == 100000, "rate limits")
        check(k?.maxBudget == nil, "null budget tolerated")

        let userJSON = """
        {"user_id":"u-1","user_info":{"user_id":"u-1","user_alias":null,"user_email":"me@example.com","user_role":"internal_user",
          "spend":2235.807,"max_budget":null,"teams":["t1"],"models":[],"created_at":"2026-08-06T06:20:58.847000Z",
          "updated_at":"2026-10-12T10:00:00Z","model_spend":{"claude-opus-5-5":2000.1,"gpt-x":"235.7"}},
         "keys":[{"token":"abc123def456","key_name":"sk-...cV","key_alias":"ai-usage","spend":100.25,"created_at":"2026-08-07T00:00:00Z","models":[],"expires":null},
                 {"token":"zzz999","key_name":null,"key_alias":null,"spend":5,"created_at":"bogus-date"},
                 {"no_token":true}],
         "teams":[]}
        """
        let u = UserInfo.parse(Data(userJSON.utf8))
        check(u?.spend == 2235.807, "user spend")
        check(u?.displayName == "me@example.com", "display name falls back to email")
        check(u?.createdAt != nil && Day.key(u!.createdAt!) == "2026-08-06", "created_at with 6-digit fractions")
        check(u?.keys.count == 2, "keys parsed, invalid skipped")
        check(u?.keys.first?.masked == "sk-...cV", "masked key name")
        check(u?.modelSpend["gpt-x"] == 235.7, "model_spend string number")

        let modelsJSON = #"{"data":[{"id":"claude-opus-5-5"},{"id":"gpt-x"},{"id":"claude-opus-5-5"},{"object":"model"}]}"#
        check(ModelList.parse(Data(modelsJSON.utf8)) == ["claude-opus-5-5", "gpt-x"], "models list dedup")

        let today = Day.today
        let y = Day.offset(today, by: -1)
        let dailyJSON = """
        {"results":[
          {"date":"\(y)","metrics":{"spend":1.23,"prompt_tokens":1000,"completion_tokens":200,"total_tokens":1200,"api_requests":10,
            "successful_requests":9,"failed_requests":1,"cache_read_input_tokens":500,"cache_creation_input_tokens":null},
           "breakdown":{"models":{"claude-opus-5-5":{"metrics":{"spend":1.0,"api_requests":7}},"gpt-x":{"metrics":{"spend":"0.23","api_requests":3}}},
             "api_keys":{"abc123def456":{"metrics":{"spend":1.23},"metadata":{"key_alias":"ai-usage"}}},"providers":{}}},
          {"date":"\(today)","metrics":{"spend":4.5,"api_requests":20,"prompt_tokens":5000,"completion_tokens":1000},"breakdown":null},
          {"metrics":{"spend":99}}
        ],"metadata":{"total_spend":5.73,"page":1,"total_pages":1,"has_more":false}}
        """
        let page = DailyActivityPage.parse(Data(dailyJSON.utf8))
        check(page?.rows.count == 2, "daily rows (dateless row skipped)")
        check(page?.hasMore == false, "pagination metadata")
        check(page?.rows.first?.breakdown.models["gpt-x"]?.spend == 0.23, "model breakdown")
        check(page?.rows.first?.breakdown.keys["abc123def456"]?.alias == "ai-usage", "key breakdown alias")
        check(page?.rows.last?.metrics.totalTokens == 6000, "total tokens derived when missing")
        check(DailyActivityPage.parse(Data("[1,2]".utf8)) == nil, "wrong shape returns nil, no crash")
        check(DailyActivityPage.parse(Data("not json".utf8)) == nil, "garbage returns nil")
        check(KeyInfo.parse(Data(#"{"info":"oops"}"#.utf8))?.spend == 0, "info as wrong type tolerated")

        print("• URL normalization")
        check(LiteLLMClient.normalize("https://ai-gateway.dev.devrev-eng.ai/v1/")?.absoluteString == "https://ai-gateway.dev.devrev-eng.ai", "strip /v1/")
        check(LiteLLMClient.normalize("gw.example.com")?.absoluteString == "https://gw.example.com", "add scheme")
        check(LiteLLMClient.normalize("  ") == nil, "empty is invalid")

        print("• Snapshot deltas")
        let cal = Day.calendar
        let d0 = cal.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 9))!
        let d1 = cal.date(byAdding: .hour, value: 5, to: d0)!
        let d2 = cal.date(byAdding: .day, value: 1, to: d0)!
        let d3 = cal.date(byAdding: .hour, value: 3, to: d2)!
        let d4 = cal.date(byAdding: .day, value: 1, to: d2)!
        let snaps = [
            Snapshot(timestamp: d0, kind: "user", ref: "u", spend: 100),
            Snapshot(timestamp: d1, kind: "user", ref: "u", spend: 103),
            Snapshot(timestamp: d2, kind: "user", ref: "u", spend: 110),
            Snapshot(timestamp: d3, kind: "user", ref: "u", spend: 112.5),
            Snapshot(timestamp: d4, kind: "user", ref: "u", spend: 4), // budget reset
        ]
        let deltas = SnapshotMath.dailyDeltas(snaps.shuffled())
        check(abs((deltas["2026-10-10"] ?? -1) - 3) < 1e-9, "day 1 delta = 3")
        check(abs((deltas["2026-10-11"] ?? -1) - 9.5) < 1e-9, "day 2 delta = 9.5")
        check(abs((deltas["2026-10-12"] ?? -1) - 4) < 1e-9, "reset handled = 4")

        print("• SQLite store")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("llmusage-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let db = try Database(url: dir.appendingPathComponent("t.sqlite"))
            db.upsertDaily(page!.rows)
            check(db.allDaily().count == 2, "insert 2 rows")
            var updated = page!.rows[1]
            updated.metrics.spend = 6.75
            db.upsertDaily([updated])
            let all = db.allDaily()
            check(all.count == 2, "upsert keeps 2 rows")
            check(all.last?.metrics.spend == 6.75, "upsert updates spend")
            check(all.first?.breakdown.models["claude-opus-5-5"]?.apiRequests == 7, "breakdown round-trips")
            for s in snaps { db.addSnapshot(s) }
            check(db.snapshots(kind: "user").count == 5, "snapshots stored")
            db.setCache("user_info", Data(userJSON.utf8))
            check(db.cache("user_info").flatMap { UserInfo.parse($0.data) }?.spend == 2235.807, "cache round-trip")
            db.setMeta("backfill_done", "1")
            check(db.meta("backfill_done") == "1", "meta round-trip")

            let merged = UsageStore.mergeWithSnapshots(apiRows: [all[0]], snapshots: snaps)
            check(merged.contains { $0.date == "2026-10-11" && $0.source == "snapshot" }, "fallback fills from snapshots")
            check(merged.first { $0.date == all[0].date }?.source == "api", "API rows take precedence")

            let store = UsageStore(database: db, startTimers: false)
            check(store.daily.count == 2, "store loads cached daily")
            check(store.user?.spend == 2235.807, "store loads cached user")
            check(abs(store.todaySpend - 6.75) < 1e-9, "today spend")
            check(abs(store.yesterdaySpend - 1.23) < 1e-9, "yesterday spend")
            check(store.series(for: .week).count == 7, "7-day series zero-filled")
            check(store.modelUsage(for: .week).first?.name == "claude-opus-5-5", "model ranking")
            check(store.keyUsage(for: .week).first { $0.hash == "abc123def456" }?.periodSpend == 1.23, "key period spend")
            let csv = store.csv()
            check(csv.split(separator: "\n").count == 3, "CSV has header + 2 rows")

            db.resetAll()
            check(db.allDaily().isEmpty && db.snapshotCount() == 0, "reset clears data")
        } catch {
            check(false, "database open: \(error)")
        }

        print("• Formatting")
        check(Fmt.currency(12.346) == "$12.35", "currency")
        check(Fmt.tokens(1_234_567) == "1.2M", "1.2M")
        check(Fmt.tokens(340_000) == "340K", "340K")
        check(Fmt.tokens(999) == "999", "999")

        runPetTests()

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILURE(S)")
        return failures == 0
    }
}
