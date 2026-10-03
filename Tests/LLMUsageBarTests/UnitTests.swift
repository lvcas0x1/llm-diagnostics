import Foundation
import Testing
@testable import LLMUsageBar

// MARK: - Helpers

func otlpAttr(_ key: String, _ value: Any) -> [String: Any] {
    switch value {
    case let s as String: return ["key": key, "value": ["stringValue": s]]
    case let i as Int: return ["key": key, "value": ["intValue": String(i)]]  // int64 is a JSON string
    case let d as Double: return ["key": key, "value": ["doubleValue": d]]
    default: fatalError("unsupported attribute value")
    }
}

func jsonData(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

/// ExportMetricsServiceRequest with one sum metric.
func metricsBody(name: String, cumulative: Bool, points: [(attrs: [String: Any], value: Double, start: String)],
                 resource: [String: Any] = [:]) -> Data {
    let dps: [[String: Any]] = points.map { p in
        ["attributes": p.attrs.map { otlpAttr($0.key, $0.value) },
         "startTimeUnixNano": p.start, "timeUnixNano": "1790000000000000000", "asDouble": p.value]
    }
    return jsonData(["resourceMetrics": [[
        "resource": ["attributes": resource.map { otlpAttr($0.key, $0.value) }],
        "scopeMetrics": [["metrics": [[
            "name": name,
            "sum": ["aggregationTemporality": cumulative ? 2 : 1, "isMonotonic": true, "dataPoints": dps],
        ]]]],
    ]]])
}

/// ExportTraceServiceRequest with the given spans.
func tracesBody(_ spans: [(id: String, attrs: [String: Any])], resource: [String: Any] = [:]) -> Data {
    jsonData(["resourceSpans": [[
        "resource": ["attributes": resource.map { otlpAttr($0.key, $0.value) }],
        "scopeSpans": [["spans": spans.map { s in
            ["traceId": "t", "spanId": s.id, "name": "span", "endTimeUnixNano": "1790000000000000000",
             "attributes": s.attrs.map { otlpAttr($0.key, $0.value) }] as [String: Any]
        }]],
    ]]])
}

// MARK: - OTLP metrics parser (Claude Code)

@Suite("Unit: OTLPParser")
struct OTLPParserTests {
    @Test func parsesDeltaTokenAndCostPoints() {
        let tokens = OTLPParser.parseMetrics(metricsBody(
            name: "claude_code.token.usage", cumulative: false,
            points: [(["session.id": "s1", "model": "claude-opus-5-5", "type": "input"], 120, "1")],
            resource: ["cc.label": "devbox"]))
        #expect(tokens.count == 1)
        #expect(tokens[0].kind == .tokens)
        #expect(tokens[0].sessionId == "s1")
        #expect(tokens[0].tokenType == "input")
        #expect(tokens[0].value == 120)
        #expect(tokens[0].isCumulative == false)
        #expect(tokens[0].label == "devbox")
        #expect(tokens[0].startTime == Date(timeIntervalSince1970: 1e-9))

        let cost = OTLPParser.parseMetrics(metricsBody(
            name: "claude_code.cost.usage", cumulative: true,
            points: [(["session.id": "s1", "model": "m"], 0.25, "1")]))
        #expect(cost.first?.kind == .cost)
        #expect(cost.first?.isCumulative == true)
    }

    @Test func ignoresOtherMetricsAndPointsWithoutSession() {
        #expect(OTLPParser.parseMetrics(metricsBody(
            name: "gen_ai.client.token.usage", cumulative: false,
            points: [(["session.id": "s1"], 1, "1")])).isEmpty)
        #expect(OTLPParser.parseMetrics(metricsBody(
            name: "claude_code.token.usage", cumulative: false,
            points: [(["model": "m"], 1, "1")])).isEmpty)
    }

    @Test func acceptsIntValuesAsStringsAndTemporalityNames() {
        let body = jsonData(["resourceMetrics": [["scopeMetrics": [["metrics": [[
            "name": "claude_code.token.usage",
            "sum": ["aggregationTemporality": "AGGREGATION_TEMPORALITY_CUMULATIVE",
                    "dataPoints": [["attributes": [otlpAttr("session.id", "s")], "asInt": "42"]]],
        ]]]]]]])
        let p = OTLPParser.parseMetrics(body)
        #expect(p.first?.value == 42)
        #expect(p.first?.isCumulative == true)
    }

    @Test func rejectsGarbage() {
        #expect(OTLPParser.parseMetrics(Data("not json".utf8)).isEmpty)
        #expect(OTLPParser.parseMetrics(jsonData(["foo": 1])).isEmpty)
    }
}

extension UsagePoint.Kind: Equatable {}

// MARK: - HTTP request parser

@Suite("Unit: HTTPRequest")
struct HTTPRequestTests {
    @Test func parsesContentLengthBody() throws {
        let raw = Data("POST /v1/metrics HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8)
        guard case .complete(let req, let consumed) = HTTPRequest.parse(raw) else {
            Issue.record("expected complete"); return
        }
        #expect(req.method == "POST")
        #expect(req.path == "/v1/metrics")
        #expect(req.headers["content-type"] == "application/json")
        #expect(req.body == Data("{}".utf8))
        #expect(consumed == raw.count)
    }

    @Test func reportsIncompleteUntilBodyArrives() {
        let head = "POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\n"
        guard case .incomplete = HTTPRequest.parse(Data((head + "12345").utf8)) else {
            Issue.record("expected incomplete"); return
        }
        guard case .incomplete = HTTPRequest.parse(Data("POST /x HTTP/1.1\r\nContent-".utf8)) else {
            Issue.record("expected incomplete header"); return
        }
    }

    @Test func decodesChunkedBody() {
        let raw = Data("POST /v1/traces HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nabcd\r\n3\r\nefg\r\n0\r\n\r\n".utf8)
        guard case .complete(let req, let consumed) = HTTPRequest.parse(raw) else {
            Issue.record("expected complete"); return
        }
        #expect(String(data: req.body, encoding: .utf8) == "abcdefg")
        #expect(consumed == raw.count)
    }

    @Test func keepsPipelinedRemainder() {
        let one = "POST /a HTTP/1.1\r\nContent-Length: 1\r\n\r\nx"
        let raw = Data((one + "POST /b HTTP/1.1\r\n").utf8)
        guard case .complete(_, let consumed) = HTTPRequest.parse(raw) else {
            Issue.record("expected complete"); return
        }
        #expect(consumed == one.utf8.count)
    }

    @Test func rejectsBadRequestLine() {
        guard case .invalid = HTTPRequest.parse(Data("GARBAGE\r\n\r\n".utf8)) else {
            Issue.record("expected invalid"); return
        }
    }
}

// MARK: - OpenAI pricing

@Suite("Unit: OpenAIPricing")
struct OpenAIPricingTests {
    @Test func bundledTableHasCurrentModels() throws {
        let astra = try #require(OpenAIPricing.bundled.price(for: "gpt-6-astra"))
        #expect(astra.short.input == 10 && astra.short.cachedInput == 1 && astra.short.cacheWrite == 12.5 && astra.short.output == 50)
        #expect(astra.long.input == 20 && astra.long.output == 75)
    }

    @Test func stripsContextNoteAndFallsBackForDashCells() throws {
        // "gpt-5.5-pro (<272K context length)": cached input is "-".
        let pro = try #require(OpenAIPricing.bundled.price(for: "gpt-5.5-pro"))
        #expect(pro.short.cachedInput == pro.short.input)
        // gpt-5-mini has no long-context columns: long falls back to short.
        let mini = try #require(OpenAIPricing.bundled.price(for: "gpt-5-mini"))
        #expect(mini.long.input == mini.short.input)
    }

    @Test func matchesDatedSnapshotsByPrefix() {
        #expect(OpenAIPricing.bundled.price(for: "gpt-6-luna-2026-09-01") != nil)
        #expect(OpenAIPricing.bundled.price(for: "unknown-model") == nil)
    }

    @Test func parsesMarkdownWithHtmlAndOtherTables() throws {
        let md = """
        <div>intro</div>
        ### Batch pricing data
        | Model | Short context input | Short context cached input | Short context output |
        | --- | --- | --- | --- |
        | m1 | $9.00 | $9.00 | $9.00 |
        ### Standard pricing data
        | Model | Short context input | Short context cached input | Short context output |
        | --- | --- | --- | --- |
        | <a href="#">m1</a> | $1.00 | $0.10 | $4.00 |
        """
        let p = try #require(OpenAIPricing.parse(markdown: md))
        #expect(p.price(for: "m1")?.short.input == 1)  // Standard, not Batch
        #expect(p.price(for: "m1")?.short.cacheWrite == 1)  // no cache-write column: input price
        #expect(OpenAIPricing.parse(markdown: "no tables here") == nil)
    }
}

// MARK: - Codex rollout parser

@Suite("Unit: CodexScanner.parse")
struct CodexParseTests {
    static func write(_ lines: [[String: Any]]) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID()).jsonl")
        let text = lines.map { String(data: jsonData($0), encoding: .utf8)! }.joined(separator: "\n") + "\n"
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func meta(_ originator: String, source: String = "cli") -> [String: Any] {
        ["timestamp": "2026-10-01T00:00:00.000Z", "type": "session_meta",
         "payload": ["id": "sess-1", "cwd": "/tmp/proj", "source": source, "originator": originator]]
    }

    static func usage(_ ts: String, _ input: Int, _ cached: Int, _ output: Int, type: String = "token_usage_record") -> [String: Any] {
        let u: [String: Any] = ["input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": 0,
                                "output_tokens": output, "reasoning_output_tokens": 0, "total_tokens": input + output]
        if type == "token_usage_record" {
            return ["timestamp": ts, "type": type, "payload": ["usage": u]]
        }
        return ["timestamp": ts, "type": "event_msg",
                "payload": ["type": "token_count", "info": ["total_token_usage": u, "last_token_usage": u]]]
    }

    @Test func readsPerResponseRecordsWithModelAndTime() throws {
        let url = Self.write([
            Self.meta("codex-tui", source: "vscode"),
            ["timestamp": "2026-10-01T00:00:01.000Z", "type": "turn_context", "payload": ["model": "gpt-6-luna"]],
            Self.usage("2026-10-01T00:00:02.500Z", 1000, 400, 100),
            ["timestamp": "2026-10-01T00:00:03.000Z", "type": "turn_context", "payload": ["model": "gpt-6-astra"]],
            Self.usage("2026-10-01T00:00:04.000Z", 300_001, 0, 10),
        ])
        let f = try #require(CodexScanner.parse(url, mtime: Date()))
        #expect(f.sessionId == "sess-1")
        #expect(f.cwd == "/tmp/proj")
        #expect(f.records.count == 2)
        #expect(f.records[0].model == "gpt-6-luna")
        #expect(f.records[0].tokens.total == 1100)
        #expect(f.records[0].isLongContext == false)
        #expect(f.records[1].model == "gpt-6-astra")
        #expect(f.records[1].isLongContext == true)
        #expect(abs(f.records[0].time.timeIntervalSince1970 - 1790812802.5) < 0.001)
    }

    @Test func acceptsExecAndRejectsNonCliOriginators() {
        #expect(CodexScanner.parse(Self.write([Self.meta("codex_exec", source: "exec")]), mtime: Date()) != nil)
        #expect(CodexScanner.parse(Self.write([Self.meta("codex_vscode", source: "vscode")]), mtime: Date()) == nil)
        #expect(CodexScanner.parse(Self.write([Self.usage("2026-10-01T00:00:00.000Z", 1, 0, 1)]), mtime: Date()) == nil)
    }

    @Test func fallsBackToTokenCountDeltas() throws {
        // Running totals 1000 -> 1500 input; deltas 1000 and 500.
        let url = Self.write([
            Self.meta("codex-tui"),
            Self.usage("2026-10-01T00:00:01.000Z", 1000, 0, 10, type: "token_count"),
            Self.usage("2026-10-01T00:00:02.000Z", 1000, 0, 10, type: "token_count"),  // unchanged: no record
            Self.usage("2026-10-01T00:00:03.000Z", 1500, 0, 20, type: "token_count"),
        ])
        let f = try #require(CodexScanner.parse(url, mtime: Date()))
        #expect(f.records.map(\.tokens.input) == [1000, 500])
        #expect(f.records.map(\.tokens.output) == [10, 10])
    }

    @Test func skipsMalformedLines() throws {
        let url = Self.write([Self.meta("codex-tui"), Self.usage("2026-10-01T00:00:01.000Z", 10, 0, 1)])
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("{broken json\n".utf8))
        try handle.close()
        #expect(CodexScanner.parse(url, mtime: Date())?.records.count == 1)
    }
}

// MARK: - Copilot trace parser

@Suite("Unit: CopilotParser")
struct CopilotParserTests {
    @Test func readsChatTokensAndTopLevelAIUnitsOnly() {
        let spans = CopilotParser.parseTraces(tracesBody([
            ("a", ["gen_ai.operation.name": "invoke_agent", "gen_ai.conversation.id": "c1",
                   "server.address": "api.githubcopilot.com", "github.copilot.nano_aiu": 2_500_000_000]),
            ("b", ["gen_ai.operation.name": "invoke_agent", "gen_ai.conversation.id": "c1",
                   "github.copilot.nano_aiu": 1_000_000_000]),  // subagent: no server.address
            ("c", ["gen_ai.operation.name": "chat", "gen_ai.conversation.id": "c1",
                   "gen_ai.request.model": "req-model", "gen_ai.response.model": "claude-sonnet-5",
                   "gen_ai.usage.input_tokens": 1200, "gen_ai.usage.output_tokens": 80,
                   "gen_ai.usage.cache_read.input_tokens": 900, "github.copilot.nano_aiu": 2_000_000_000]),
            ("d", ["gen_ai.operation.name": "execute_tool", "gen_ai.conversation.id": "c1"]),
            ("e", ["gen_ai.operation.name": "chat"]),  // no session id
        ], resource: ["cc.label": "repo-x"]))
        #expect(spans.count == 2)
        guard case .topLevelAgent(let aiu) = spans[0].kind else { Issue.record("expected agent"); return }
        #expect(aiu == 2_500_000_000)
        #expect(spans[0].label == "repo-x")
        guard case .chat(let model, let t) = spans[1].kind else { Issue.record("expected chat"); return }
        #expect(model == "claude-sonnet-5")
        #expect(t.total == 1280)
        #expect(t.cacheRead == 900)
    }

    @Test func rejectsGarbage() {
        #expect(CopilotParser.parseTraces(Data("[]".utf8)).isEmpty)
    }
}

// MARK: - Collection periods and recent keys

@Suite("Unit: CollectionPeriod / RecentKeys")
struct CollectionTests {
    @Test func coversRequiresStartAndEndInOnePeriod() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var periods: [CollectionPeriod] = []
        periods.open(at: t0)
        periods.close(at: t0.addingTimeInterval(100))
        periods.open(at: t0.addingTimeInterval(200))
        #expect(periods.covers(start: t0.addingTimeInterval(10), end: t0.addingTimeInterval(20)))
        #expect(!periods.covers(start: t0.addingTimeInterval(-1), end: t0.addingTimeInterval(20)))   // before start
        #expect(!periods.covers(start: t0.addingTimeInterval(50), end: t0.addingTimeInterval(250)))  // spans off period
        #expect(!periods.covers(start: nil, end: t0.addingTimeInterval(150)))                          // while off
        #expect(periods.covers(start: nil, end: t0.addingTimeInterval(1_000_000)))                     // open period
        periods.open(at: t0.addingTimeInterval(300))  // already open: no new period
        #expect(periods.count == 2)
    }

    @Test func recentKeysUseATimeWindow() {
        let now = Date()
        var keys = RecentKeys()
        let first = keys.insertIfNew("a", time: now, now: now)
        let again = keys.insertIfNew("a", time: now, now: now)
        let tooOld = keys.insertIfNew("old", time: now.addingTimeInterval(-RecentKeys.window - 1), now: now)
        #expect(first && !again && !tooOld)
        keys.prune(now: now.addingTimeInterval(RecentKeys.window + 1))
        #expect(keys.seen.isEmpty)
    }
}

// MARK: - Formatting

@Suite("Unit: Format")
struct FormatTests {
    @Test func usd() {
        #expect(Format.usd(0) == "$0")
        #expect(Format.usd(1.234) == "$1.23")
        #expect(Format.usd(150.4) == "$150")
    }

    @Test func tokens() {
        #expect(Format.kTokens(0) == "0k")
        #expect(Format.kTokens(1_499) == "1k")
        #expect(Format.tokens(1_500) == "1.5K")
        #expect(Format.tokens(2_500_000) == "2.5M")
    }

    @Test func dayKey() {
        var c = DateComponents()
        c.year = 2026; c.month = 1; c.day = 2; c.hour = 12
        #expect(Format.dayKey(Calendar.current.date(from: c)!) == "2026-01-02")
    }
}
