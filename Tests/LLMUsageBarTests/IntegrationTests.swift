import Foundation
import Network
import Testing
@testable import LLMUsageBar

/// Points the stores at fresh temporary directories. Environment variables are process-wide,
/// so every suite that uses this is serialized.
@discardableResult
func useTemporaryDirectories() -> (support: URL, codexHome: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("llm-usage-tests-\(UUID())")
    let support = root.appendingPathComponent("support"), codex = root.appendingPathComponent("codex")
    try! FileManager.default.createDirectory(at: codex.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    setenv("LLM_USAGE_BAR_SUPPORT_DIR", support.path, 1)
    setenv("CODEX_HOME", codex.path, 1)
    // Never download prices from tests.
    UserDefaults.standard.set(false, forKey: "openAIPricingAutoUpdate")
    return (support, codex)
}

func claudePoint(_ kind: UsagePoint.Kind, session: String = "s1", model: String = "claude-opus-5-5",
                 type: String? = "input", value: Double, cumulative: Bool = false, series: String? = nil,
                 start: Date? = nil, end: Date = Date()) -> UsagePoint {
    UsagePoint(kind: kind, sessionId: session, model: model, tokenType: kind == .tokens ? type : nil,
               value: value, isCumulative: cumulative, seriesKey: series ?? "\(kind)-\(type ?? "")",
               label: nil, time: end, startTime: start)
}

@Suite("Integration", .serialized)
@MainActor
struct IntegrationTests {

    // MARK: Claude Code store

    @Test func claudeAccumulatesDeltaAndCumulative() {
        useTemporaryDirectories()
        let store = ClaudeStore()
        store.ingest([claudePoint(.tokens, value: 100)])
        #expect(store.sessions.isEmpty, "ingest while stopped must be ignored")

        store.setRunning(true)
        store.ingest([claudePoint(.tokens, type: "input", value: 100),
                      claudePoint(.tokens, type: "output", value: 50),
                      claudePoint(.cost, value: 0.01)])
        #expect(store.totalTokens == 150)
        #expect(abs(store.totalCost - 0.01) < 1e-12)
        #expect(store.sessions["s1"]?.byModel?["claude-opus-5-5"]?.tokens == 150)

        // Cumulative series: 200 then 260 adds 200 + 60; a drop to 30 is a restart and adds 30.
        for v in [200.0, 260, 30] {
            store.ingest([claudePoint(.tokens, type: "cacheRead", value: v, cumulative: true, series: "c")])
        }
        #expect(store.sessions["s1"]?.tokens["cacheRead"] == 290)
    }

    @Test func claudeResetPersistenceAndOff() throws {
        let dirs = useTemporaryDirectories()
        let file = dirs.support.appendingPathComponent("claude-state.json")
        let store = ClaudeStore()
        store.setRunning(true)
        store.ingest([claudePoint(.tokens, value: 500, cumulative: true, series: "c"), claudePoint(.cost, value: 1.5)])
        store.saveNow()

        let reloaded = ClaudeStore()
        reloaded.setRunning(true)
        #expect(reloaded.totalTokens == 500)
        #expect(reloaded.totalCost == 1.5)

        // After a reset, a series that started before it is only a baseline; later increases count.
        reloaded.reset()
        #expect(reloaded.totalTokens == 0)
        let processStart = Date().addingTimeInterval(-600)
        reloaded.ingest([claudePoint(.tokens, value: 520, cumulative: true, series: "c", start: processStart)])
        #expect(reloaded.totalTokens == 0)
        reloaded.ingest([claudePoint(.tokens, value: 540, cumulative: true, series: "c", start: processStart,
                                     end: Date().addingTimeInterval(1))])
        #expect(reloaded.totalTokens == 20)
        reloaded.setRunning(false)

        // A store that is never turned on does not create or read the file.
        try FileManager.default.removeItem(at: file)
        let off = ClaudeStore()
        off.ingest([claudePoint(.tokens, value: 1)])
        off.saveNow()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func claudeExcludesUsageFromBeforeCollectionAndWhileOff() {
        useTemporaryDirectories()
        let store = ClaudeStore()
        let beforeOn = Date().addingTimeInterval(-30)
        store.setRunning(true)
        let on = Date()

        // Delta interval that started before collection: not counted. Fully after: counted.
        store.ingest([claudePoint(.tokens, value: 100, start: beforeOn, end: on.addingTimeInterval(0.01))])
        #expect(store.totalTokens == 0)
        store.ingest([claudePoint(.tokens, value: 40, start: on.addingTimeInterval(0.01), end: on.addingTimeInterval(0.02))])
        #expect(store.totalTokens == 40)

        // Delayed delta from before collection started: not counted.
        store.ingest([claudePoint(.tokens, value: 7, start: beforeOn.addingTimeInterval(-60), end: beforeOn)])
        #expect(store.totalTokens == 40)

        // Cumulative series from a process that started before collection: first value is a baseline.
        store.ingest([claudePoint(.cost, value: 3.0, cumulative: true, series: "cost-c", start: beforeOn, end: on.addingTimeInterval(0.01))])
        #expect(store.totalCost == 0)
        store.ingest([claudePoint(.cost, value: 3.5, cumulative: true, series: "cost-c", start: beforeOn, end: on.addingTimeInterval(0.02))])
        #expect(abs(store.totalCost - 0.5) < 1e-12)

        // Turned off and on again: a delta interval that overlaps the off period is not counted,
        // and a cumulative increase across the off period is only a new baseline.
        Thread.sleep(forTimeInterval: 0.1)
        store.setRunning(false)
        let off = Date()
        Thread.sleep(forTimeInterval: 0.2)
        store.setRunning(true)
        let on2 = Date()
        store.ingest([claudePoint(.tokens, value: 9, start: off, end: on2.addingTimeInterval(0.01))])
        store.ingest([claudePoint(.cost, value: 9.0, cumulative: true, series: "cost-c", start: beforeOn, end: on2.addingTimeInterval(0.01))])
        #expect(store.totalTokens == 40)
        #expect(abs(store.totalCost - 0.5) < 1e-12)
        store.ingest([claudePoint(.cost, value: 9.25, cumulative: true, series: "cost-c", start: beforeOn, end: on2.addingTimeInterval(0.02))])
        #expect(abs(store.totalCost - 0.75) < 1e-12)
        store.setRunning(false)
    }

    /// Reported: 100 -> 150 -> old 100 -> 180 counted 330 instead of 180.
    @Test func claudeIgnoresOutOfOrderCumulativeReadings() {
        useTemporaryDirectories()
        let store = ClaudeStore()
        store.setRunning(true)
        let on = Date()
        func reading(_ v: Double, _ dt: TimeInterval, series: String, start: Date) -> UsagePoint {
            claudePoint(.tokens, value: v, cumulative: true, series: series, start: start, end: on.addingTimeInterval(dt))
        }
        // Series started while collecting: total must equal the latest value.
        let s1 = on.addingTimeInterval(0.001)
        store.ingest([reading(100, 0.01, series: "a", start: s1), reading(150, 0.02, series: "a", start: s1),
                      reading(100, 0.01, series: "a", start: s1),  // late re-send of the first reading
                      reading(180, 0.03, series: "a", start: s1)])
        #expect(store.totalTokens == 180)

        // Series started before collection: only increases after the first reading count.
        let s2 = on.addingTimeInterval(-60)
        store.ingest([reading(1000, 0.01, series: "b", start: s2), reading(1050, 0.02, series: "b", start: s2),
                      reading(1020, 0.015, series: "b", start: s2),  // late, out of order
                      reading(1080, 0.03, series: "b", start: s2)])
        #expect(store.totalTokens == 180 + 80)
        store.setRunning(false)
    }

    /// Reported: two sessions identified only by a resource attribute collided into one.
    @Test func claudeKeepsResourceLevelSessionsApart() {
        useTemporaryDirectories()
        let store = ClaudeStore()
        store.setRunning(true)
        let now = Date()
        let startNanos = String(Int64(now.timeIntervalSince1970 * 1e9) + 1_000_000)
        let endNanos = String(Int64(now.timeIntervalSince1970 * 1e9) + 2_000_000)
        func resource(_ session: String) -> [String: Any] {
            ["resource": ["attributes": [otlpAttr("session.id", session)]],
             "scopeMetrics": [["metrics": [[
                "name": "claude_code.token.usage",
                "sum": ["aggregationTemporality": 1, "dataPoints": [[
                    "attributes": [otlpAttr("type", "input"), otlpAttr("model", "m")],
                    "startTimeUnixNano": startNanos, "timeUnixNano": endNanos, "asDouble": 100.0]]],
             ]]]]]
        }
        store.ingest(OTLPParser.parseMetrics(jsonData(["resourceMetrics": [resource("a"), resource("b")]])))
        #expect(store.totalTokens == 200)
        #expect(store.sessions.count == 2)
        store.setRunning(false)
    }

    /// Reported: state saved by v0.0.1 (series keys without session/resource) held cumulative 100;
    /// the new build then received 150 for the same series and counted 250 instead of 150.
    @Test func claudeContinuesCumulativeSeriesSavedByOlderBuilds() throws {
        let dirs = useTemporaryDirectories()
        let start = Date().addingTimeInterval(-600), t1 = Date().addingTimeInterval(-60)
        let ref = Date(timeIntervalSinceReferenceDate: 0)
        let startNanos = String(Int64(start.timeIntervalSince1970 * 1e9))
        // v0.0.1 key: name|<point attributes>|<start>
        let oldKey = "claude_code.token.usage|model=m,session.id=s1,type=input|" + startNanos
        let session: [String: Any] = ["id": "s1", "isLocal": false, "tokens": ["input": 100.0], "costUSD": 0.0,
                                      "byModel": ["m": ["tokens": 100.0, "costUSD": 0.0]],
                                      "firstSeen": start.timeIntervalSince(ref), "lastSeen": t1.timeIntervalSince(ref)]
        let old: [String: Any] = ["sessions": ["s1": session], "seriesLast": [oldKey: 100.0],
                                  "seriesLastTime": [oldKey: t1.timeIntervalSince(ref)],
                                  "periods": [["start": start.addingTimeInterval(-60).timeIntervalSince(ref)]]]
        try FileManager.default.createDirectory(at: dirs.support, withIntermediateDirectories: true)
        try jsonData(old).write(to: dirs.support.appendingPathComponent("claude-state.json"))

        let store = ClaudeStore()
        store.setRunning(true)
        let body = metricsBody(name: "claude_code.token.usage", cumulative: true,
                               points: [(["session.id": "s1", "model": "m", "type": "input"], 150, startNanos)],
                               resource: ["service.name": "claude-code"],
                               time: String(Int64(Date().timeIntervalSince1970 * 1e9)))
        store.ingest(OTLPParser.parseMetrics(body))
        #expect(store.totalTokens == 150)
        store.setRunning(false)
    }

    /// Reported: after the upgrade, a re-sent older reading arrived first and used up the migrated
    /// reading; the next cumulative 150 then counted in full (250 instead of 150). Also across a restart.
    @Test(arguments: [false, true])
    func claudeKeepsMigratedReadingWhenAStaleReadingArrivesFirst(restartBetween: Bool) throws {
        let dirs = useTemporaryDirectories()
        let start = Date().addingTimeInterval(-600), t1 = Date().addingTimeInterval(-60)
        let ref = Date(timeIntervalSinceReferenceDate: 0)
        let startNanos = String(Int64(start.timeIntervalSince1970 * 1e9))
        let oldKey = "claude_code.token.usage|model=m,session.id=s1,type=input|" + startNanos
        let session: [String: Any] = ["id": "s1", "isLocal": false, "tokens": ["input": 100.0], "costUSD": 0.0,
                                      "firstSeen": start.timeIntervalSince(ref), "lastSeen": t1.timeIntervalSince(ref)]
        let old: [String: Any] = ["sessions": ["s1": session], "seriesLast": [oldKey: 100.0],
                                  "seriesLastTime": [oldKey: t1.timeIntervalSince(ref)],
                                  "periods": [["start": start.addingTimeInterval(-60).timeIntervalSince(ref)]]]
        try FileManager.default.createDirectory(at: dirs.support, withIntermediateDirectories: true)
        try jsonData(old).write(to: dirs.support.appendingPathComponent("claude-state.json"))
        func reading(_ value: Double, at time: Date) -> Data {
            metricsBody(name: "claude_code.token.usage", cumulative: true,
                        points: [(["session.id": "s1", "model": "m", "type": "input"], value, startNanos)],
                        time: String(Int64(time.timeIntervalSince1970 * 1e9)))
        }
        var store = ClaudeStore()
        store.setRunning(true)
        // A re-sent older reading (before the saved one), so it is skipped as stale.
        store.ingest(OTLPParser.parseMetrics(reading(90, at: t1.addingTimeInterval(-10))))
        #expect(store.totalTokens == 100)
        if restartBetween {
            // App quit and relaunched: the app saves on quit, and the collection period stays open
            // (turning Claude Code off would close it, and increases across an off period are not counted).
            store.saveNow()
            store = ClaudeStore()
            store.setRunning(true)
        }
        store.ingest(OTLPParser.parseMetrics(reading(150, at: Date())))
        #expect(store.totalTokens == 150)
        store.setRunning(false)
    }

    /// Reported: span IDs saved in upper case by an older build were not normalized, so the same
    /// span re-sent (now lower-cased on arrival) counted twice.
    @Test func copilotNormalizesSavedSpanIds() throws {
        let dirs = useTemporaryDirectories()
        let now = Date()
        let ref = Date(timeIntervalSinceReferenceDate: 0)
        let saved: [String: Any] = [
            "sessions": ["c1": ["id": "c1", "lastSeen": now.timeIntervalSince(ref), "nanoAIU": 1_000_000.0,
                                "byModel": ["m": ["input": 10.0, "output": 0.0, "cacheRead": 0.0, "cacheCreation": 0.0]]]],
            "periods": [["start": now.addingTimeInterval(-600).timeIntervalSince(ref)]],
            "recent": ["seen": ["5B8EFFF798038103": now.timeIntervalSince(ref)]],
        ]
        try FileManager.default.createDirectory(at: dirs.support, withIntermediateDirectories: true)
        try jsonData(saved).write(to: dirs.support.appendingPathComponent("copilot-state.json"))
        let store = CopilotStore()
        store.setRunning(true)
        let resent = CopilotParser.parseTraces(tracesBody([("5B8EFFF798038103", [
            "gen_ai.operation.name": "chat", "gen_ai.conversation.id": "c1", "gen_ai.usage.input_tokens": 10,
            "github.copilot.nano_aiu": 1_000_000.0])]))
        store.ingest(resent.map { s in
            CopilotSpan(spanId: s.spanId, sessionId: s.sessionId, label: s.label, time: now, model: "m",
                        tokens: s.tokens, nanoAIU: s.nanoAIU, startTime: now)
        })
        #expect(store.totalTokens == 10)
        #expect(abs(store.totalCost - 0.00001) < 1e-12)
        store.setRunning(false)
    }

    /// Unversioned state may already use the current key (saved after the key change): continue it too.
    @Test func claudeContinuesUnversionedStateWithCurrentKeys() throws {
        let dirs = useTemporaryDirectories()
        let start = Date().addingTimeInterval(-600), t1 = Date().addingTimeInterval(-60)
        let ref = Date(timeIntervalSinceReferenceDate: 0)
        let startNanos = String(Int64(start.timeIntervalSince1970 * 1e9))
        let body = { (value: Double) in
            metricsBody(name: "claude_code.token.usage", cumulative: true,
                        points: [(["session.id": "s1", "model": "m", "type": "input"], value, startNanos)],
                        time: String(Int64(Date().timeIntervalSince1970 * 1e9)))
        }
        let currentKey = try #require(OTLPParser.parseMetrics(body(0)).first?.seriesKey)
        let session: [String: Any] = ["id": "s1", "isLocal": false, "tokens": ["input": 100.0], "costUSD": 0.0,
                                      "firstSeen": start.timeIntervalSince(ref), "lastSeen": t1.timeIntervalSince(ref)]
        let old: [String: Any] = ["sessions": ["s1": session], "seriesLast": [currentKey: 100.0],
                                  "seriesLastTime": [currentKey: t1.timeIntervalSince(ref)],
                                  "periods": [["start": start.addingTimeInterval(-60).timeIntervalSince(ref)]]]
        try FileManager.default.createDirectory(at: dirs.support, withIntermediateDirectories: true)
        try jsonData(old).write(to: dirs.support.appendingPathComponent("claude-state.json"))

        let store = ClaudeStore()
        store.setRunning(true)
        store.ingest(OTLPParser.parseMetrics(body(150)))
        #expect(store.totalTokens == 150)
        store.saveNow()
        // Saved again with a format version; the reading continues normally.
        let reloaded = ClaudeStore()
        reloaded.setRunning(true)
        reloaded.ingest(OTLPParser.parseMetrics(body(170)))
        #expect(reloaded.totalTokens == 170)
        reloaded.setRunning(false)
        store.setRunning(false)
    }

    @Test func claudeDoesNotCountResentDeltaPoints() {
        useTemporaryDirectories()
        let store = ClaudeStore()
        store.setRunning(true)
        let start = Date().addingTimeInterval(0.5), end = Date().addingTimeInterval(1)
        let point = claudePoint(.tokens, value: 100, start: start, end: end)
        store.ingest([point])
        store.ingest([point])  // re-sent export
        #expect(store.totalTokens == 100)
        store.saveNow()

        // Still recognised after a restart.
        let reloaded = ClaudeStore()
        reloaded.setRunning(true)
        reloaded.ingest([point])
        #expect(reloaded.totalTokens == 100)
        // The next interval of the same series is new data.
        reloaded.ingest([claudePoint(.tokens, value: 5, start: end, end: end.addingTimeInterval(1))])
        #expect(reloaded.totalTokens == 105)
        reloaded.setRunning(false)
    }

    // MARK: Codex store

    static func codexFile(_ records: [CodexUsageRecord], session: String = "sess") -> CodexFile {
        CodexFile(sessionId: session, cwd: "/tmp/proj", source: "cli", mtime: Date(), records: records)
    }

    static func rec(_ time: Date, _ model: String = "gpt-6-luna", input: Double, cached: Double = 0, output: Double) -> CodexUsageRecord {
        CodexUsageRecord(time: time, model: model, tokens: CodexTokens(input: input, cachedInput: cached, output: output))
    }

    @Test func codexCountsOnlyRecordsInsideCollectionPeriods() {
        useTemporaryDirectories()
        let store = CodexStore()
        let before = Date().addingTimeInterval(-60)
        store.setRunning(true)
        let after = Date().addingTimeInterval(1)

        // gpt-6-luna short: input $0.10, cached $0.01, output $0.50 per 1M.
        // 600 uncached * 0.10 + 400 cached * 0.01 + 100 output * 0.50 = 114 -> $0.000114
        var records = [Self.rec(before, input: 999_000, output: 999),
                       Self.rec(after, input: 1000, cached: 400, output: 100)]
        store.accumulate([Self.codexFile(records)])
        #expect(store.totalTokens == 1100)
        #expect(abs(store.totalCost - 0.000114) < 1e-12)

        // Same file scanned again: nothing is counted twice.
        store.accumulate([Self.codexFile(records)])
        #expect(store.totalTokens == 1100)

        // Long context (> 272K input): long rates $0.20 input, $0.75 output.
        records.append(Self.rec(after, input: 300_000, output: 100))
        store.accumulate([Self.codexFile(records)])
        #expect(abs(store.totalCost - (0.000114 + 0.060075)) < 1e-12)

        // Off period: a record written while off is skipped after turning back on.
        store.setRunning(false)
        let duringOff = Date().addingTimeInterval(0.5)
        Thread.sleep(forTimeInterval: 1)
        store.setRunning(true)
        records.append(Self.rec(duringOff, input: 5000, output: 500))
        records.append(Self.rec(Date().addingTimeInterval(1), input: 2000, output: 200))
        store.accumulate([Self.codexFile(records)])
        #expect(store.totalTokens == 1100 + 300_100 + 2200)
        store.setRunning(false)
    }

    @Test func codexUnknownModelResetAndPersistence() {
        useTemporaryDirectories()
        let store = CodexStore()
        store.setRunning(true)
        let t = Date().addingTimeInterval(1)
        store.accumulate([Self.codexFile([Self.rec(t, "mystery-model", input: 100, output: 10)])])
        #expect(store.totalTokens == 110)
        #expect(store.totalCost == 0)
        #expect(store.unpricedModels == ["mystery-model"])
        store.saveNow()

        let reloaded = CodexStore()
        reloaded.setRunning(true)
        #expect(reloaded.totalTokens == 110)
        reloaded.reset()
        #expect(reloaded.totalTokens == 0)
        // Records processed before the reset are not counted again.
        reloaded.accumulate([Self.codexFile([Self.rec(t, "mystery-model", input: 100, output: 10)])])
        #expect(reloaded.totalTokens == 0)
        reloaded.setRunning(false)
    }

    @Test func codexClosesPeriodLeftOpenWhileAppWasNotRunning() throws {
        let dirs = useTemporaryDirectories()
        let store = CodexStore()
        store.setRunning(true)
        store.saveNow()
        // Simulate quitting while on: the period stays open in the file.
        let next = CodexStore()
        next.closeOpenPeriod()
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dirs.support.appendingPathComponent("codex-state.json"))) as! [String: Any]
        let periods = json["periods"] as! [[String: Any]]
        #expect(periods.count == 1)
        #expect(periods[0]["end"] != nil)
        store.setRunning(false)
    }

    @Test func codexScannerReadsFilesFromCodexHome() async throws {
        let dirs = useTemporaryDirectories()
        let day = dirs.codexHome.appendingPathComponent("sessions/2026/10/03")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let line: [String: Any] = ["timestamp": "2026-10-03T00:00:00.000Z", "type": "session_meta",
                                   "payload": ["id": "x", "source": "cli", "originator": "codex-tui"]]
        try (String(data: jsonData(line), encoding: .utf8)! + "\n").write(to: day.appendingPathComponent("rollout-a.jsonl"), atomically: true, encoding: .utf8)
        let files = await withCheckedContinuation { cont in CodexScanner().scan { cont.resume(returning: $0) } }
        #expect(files.map(\.sessionId) == ["x"])
    }

    // MARK: Copilot store

    static func chat(_ id: String, model: String, input: Double, output: Double, nanoAIU: Double = 0,
                     time: Date = Date(), startTime: Date? = nil) -> CopilotSpan {
        CopilotSpan(spanId: id, sessionId: "c1", label: "repo", time: time, model: model,
                    tokens: CopilotTokens(input: input, output: output), nanoAIU: nanoAIU, startTime: startTime)
    }

    @Test func copilotExcludesSpansFromBeforeCollectionAndDedupesBeyondOldLimit() {
        useTemporaryDirectories()
        let store = CopilotStore()
        let beforeOn = Date().addingTimeInterval(-30)
        store.setRunning(true)
        let t = Date().addingTimeInterval(1)

        // A request that started before collection: its tokens and AI units are not counted.
        store.ingest([Self.chat("early", model: "m", input: 1, output: 1, nanoAIU: 5_000_000_000, time: t, startTime: beforeOn)])
        #expect(store.totalCost == 0 && store.totalTokens == 0)

        // More spans than the old 20,000-ID limit; the first one re-sent afterwards is still a duplicate.
        let many = (0..<25_000).map { i in Self.chat("s\(i)", model: "m", input: 1, output: 0, time: t, startTime: t) }
        store.ingest(many)
        #expect(store.totalTokens == 25_000)
        store.ingest([many[0]])
        #expect(store.totalTokens == 25_000)

        // Data older than the de-duplication window cannot be checked and is not counted.
        let old = Date().addingTimeInterval(-RecentKeys.window - 60)
        store.ingest([Self.chat("old", model: "m", input: 1, output: 0, time: old, startTime: old)])
        #expect(store.totalTokens == 25_000)
        store.setRunning(false)
    }

    @Test func copilotAccumulatesDedupesAndPersists() {
        useTemporaryDirectories()
        let store = CopilotStore()
        store.ingest([Self.chat("x", model: "m", input: 1, output: 1)])
        #expect(store.sessions.isEmpty, "ingest while stopped must be ignored")

        store.setRunning(true)
        let batch = [Self.chat("a", model: "claude-sonnet-5", input: 1000, output: 100, nanoAIU: 2_000_000_000),
                     Self.chat("b", model: "gpt-6-luna", input: 300, output: 30, nanoAIU: 500_000_000)]
        store.ingest(batch)
        store.ingest(batch)  // re-sent export
        #expect(store.totalTokens == 1430)
        #expect(abs(store.totalCost - 0.025) < 1e-12)
        #expect(store.sessions.first?.name == "repo")
        store.saveNow()

        let reloaded = CopilotStore()
        reloaded.setRunning(true)
        #expect(reloaded.totalTokens == 1430)
        reloaded.ingest(batch)  // still recognised as seen after reload
        #expect(reloaded.totalTokens == 1430)
        reloaded.reset()
        #expect(reloaded.totalTokens == 0)
        reloaded.setRunning(false)
    }

    // MARK: OTLP server over a real socket

    final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var _points: [UsagePoint] = []
        private var _spans: [CopilotSpan] = []
        private var _states: [OTLPServer.State] = []
        var points: [UsagePoint] { lock.withLock { _points } }
        var spans: [CopilotSpan] { lock.withLock { _spans } }
        var states: [OTLPServer.State] { lock.withLock { _states } }
        func add(_ p: [UsagePoint]) { lock.withLock { _points += p } }
        func add(_ s: [CopilotSpan]) { lock.withLock { _spans += s } }
        func add(_ s: OTLPServer.State) { lock.withLock { _states.append(s) } }
    }

    static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    static func post(_ port: UInt16, _ path: String, _ body: Data, contentType: String = "application/json") async throws -> Int {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (_, resp) = try await URLSession.shared.data(for: req)
        return (resp as! HTTPURLResponse).statusCode
    }

    /// Sends raw bytes and returns the first response line.
    static func rawRequest(_ port: UInt16, _ bytes: String) async -> String {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let once = OnceFlag()
            conn.stateUpdateHandler = { state in
                if case .ready = state {
                    conn.send(content: Data(bytes.utf8), completion: .contentProcessed { _ in })
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                        let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
                        if once.claim() { cont.resume(returning: line) }
                        conn.cancel()
                    }
                } else if case .failed = state, once.claim() {
                    cont.resume(returning: "connection failed")
                    conn.cancel()
                } else if case .waiting = state, once.claim() {
                    // A refused connection waits for the network to change instead of failing.
                    cont.resume(returning: "connection failed")
                    conn.cancel()
                }
            }
            conn.start(queue: .global())
        }
    }

    final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    /// Reported: a negative Content-Length crashed the parser. Over a socket the server must
    /// answer 400 and keep serving.
    @Test func serverSurvivesMalformedLengths() async throws {
        let inbox = Inbox()
        let server = OTLPServer(onPoints: { inbox.add($0) }, onSpans: { inbox.add($0) }, onState: { inbox.add($0) })
        let port: UInt16 = 47_319
        server.start(port: port, metrics: true, traces: true)
        await Self.waitUntil { inbox.states.contains(.listening(port: port)) }
        for bad in ["Content-Length: -1\r\n", "Content-Length: 99999999999\r\n", "Transfer-Encoding: chunked\r\n"] {
            let body = bad.hasPrefix("Transfer") ? "-5\r\nxx\r\n0\r\n\r\n" : "{}"
            let reply = await Self.rawRequest(port, "POST /v1/metrics HTTP/1.1\r\n" + bad + "\r\n" + body)
            #expect(reply == "HTTP/1.1 400 Bad Request", "\(bad)")
        }
        let metrics = metricsBody(name: "claude_code.token.usage", cumulative: false,
                                  points: [(["session.id": "s", "type": "input"], 7, "1")])
        #expect(try await Self.post(port, "/v1/metrics", metrics) == 200)
        server.stop()
    }

    @Test func serverRoutesPayloadsByProvider() async throws {
        let inbox = Inbox()
        let server = OTLPServer(onPoints: { inbox.add($0) }, onSpans: { inbox.add($0) }, onState: { inbox.add($0) })
        let port: UInt16 = 47_318
        server.start(port: port, metrics: true, traces: false)
        await Self.waitUntil { inbox.states.contains(.listening(port: port)) }
        #expect(inbox.states.contains(.listening(port: port)))

        let metrics = metricsBody(name: "claude_code.token.usage", cumulative: false,
                                  points: [(["session.id": "s", "type": "input"], 7, "1")])
        let traces = tracesBody([("a", ["gen_ai.operation.name": "chat", "gen_ai.conversation.id": "c",
                                        "gen_ai.usage.input_tokens": 5, "gen_ai.usage.output_tokens": 1])])
        #expect(try await Self.post(port, "/v1/metrics", metrics) == 200)
        #expect(try await Self.post(port, "/v1/traces", traces) == 200)
        #expect(try await Self.post(port, "/v1/metrics", metrics, contentType: "application/x-protobuf") == 415)
        await Self.waitUntil { inbox.points.count == 1 }
        #expect(inbox.points.count == 1)
        #expect(inbox.spans.isEmpty, "traces must be ignored while Copilot is off")

        // Toggle providers while a client connection is still open (URLSession keep-alive plus an
        // idle raw connection): the listener must keep accepting.
        let idle = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        idle.start(queue: .global())
        try? await Task.sleep(for: .milliseconds(100))
        server.start(port: port, metrics: false, traces: true)
        try? await Task.sleep(for: .milliseconds(100))
        let body = String(data: traces, encoding: .utf8)!
        let chunked = "POST /v1/traces HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
            + String(body.utf8.count, radix: 16) + "\r\n" + body + "\r\n0\r\n\r\n"
        #expect(await Self.rawRequest(port, chunked) == "HTTP/1.1 200 OK")
        #expect(try await Self.post(port, "/v1/metrics", metrics) == 200)
        await Self.waitUntil { inbox.spans.count == 1 }
        #expect(inbox.spans.count == 1)
        #expect(inbox.points.count == 1, "metrics must be ignored while Claude Code is off")

        #expect(inbox.states.filter { if case .failed = $0 { true } else { false } }.isEmpty)

        // Stopped: the port is closed, open connections included.
        server.stop()
        await Self.waitUntil { inbox.states.last == .stopped }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await Self.rawRequest(port, "GET / HTTP/1.1\r\n\r\n") == "connection failed")

        // Restart on the same port right after stopping.
        server.start(port: port, metrics: true, traces: true)
        await Self.waitUntil { inbox.states.last == .listening(port: port) }
        #expect(inbox.states.last == .listening(port: port))
        #expect(try await Self.post(port, "/v1/metrics", metrics) == 200)
        idle.cancel()
        server.stop()
    }
}
