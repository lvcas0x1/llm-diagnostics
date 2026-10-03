import Foundation
import Testing
@testable import LLMUsageBar

/// Regressions reported in review; each test reproduces the reported input.
@Suite("Regression: HTTP parser bounds")
struct HTTPBoundsRegressionTests {
    @Test func negativeContentLengthIsInvalid() {
        let raw = Data("POST /v1/metrics HTTP/1.1\r\nContent-Length: -1\r\n\r\n{}".utf8)
        guard case .invalid = HTTPRequest.parse(raw) else { Issue.record("expected invalid"); return }
    }

    @Test func oversizedContentLengthIsInvalid() {
        let raw = Data("POST /v1/metrics HTTP/1.1\r\nContent-Length: 999999999999\r\n\r\n".utf8)
        guard case .invalid = HTTPRequest.parse(raw) else { Issue.record("expected invalid"); return }
    }

    @Test func nonNumericContentLengthIsInvalid() {
        let raw = Data("POST /v1/metrics HTTP/1.1\r\nContent-Length: abc\r\n\r\n".utf8)
        guard case .invalid = HTTPRequest.parse(raw) else { Issue.record("expected invalid"); return }
    }

    @Test func negativeChunkSizeIsInvalid() {
        let raw = Data("POST /v1/traces HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n-1\r\nxx\r\n0\r\n\r\n".utf8)
        guard case .invalid = HTTPRequest.parse(raw) else { Issue.record("expected invalid"); return }
    }

    @Test func malformedChunkSizeIsInvalid() {
        let raw = Data("POST /v1/traces HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nxx\r\n0\r\n\r\n".utf8)
        guard case .invalid = HTTPRequest.parse(raw) else { Issue.record("expected invalid"); return }
    }
}

@Suite("Regression: OTLP series keys")
struct SeriesKeyRegressionTests {
    /// Two resources whose session.id is a resource attribute, with identical data points.
    @Test func resourceLevelSessionIdIsPartOfTheSeriesKey() {
        func resource(_ session: String) -> [String: Any] {
            ["resource": ["attributes": [otlpAttr("session.id", session)]],
             "scopeMetrics": [["metrics": [[
                "name": "claude_code.token.usage",
                "sum": ["aggregationTemporality": 1, "dataPoints": [[
                    "attributes": [otlpAttr("type", "input"), otlpAttr("model", "m")],
                    "startTimeUnixNano": "1790000000000000000", "timeUnixNano": "1790000060000000000",
                    "asDouble": 100.0]]],
             ]]]]]
        }
        let points = OTLPParser.parseMetrics(jsonData(["resourceMetrics": [resource("a"), resource("b")]]))
        #expect(points.map(\.sessionId) == ["a", "b"])
        #expect(Set(points.map(\.seriesKey)).count == 2)
    }
}

@Suite("Regression: Codex timestamps")
struct CodexTimestampRegressionTests {
    @Test func acceptsTimestampsWithoutFractionalSeconds() throws {
        let url = CodexParseTests.write([
            CodexParseTests.meta("codex-tui"),
            CodexParseTests.usage("2026-10-01T00:00:02Z", 10, 0, 1),
            CodexParseTests.usage("2026-10-01T00:00:03.250Z", 10, 0, 1),
        ])
        let mtime = Date(timeIntervalSince1970: 0)
        let f = try #require(CodexScanner.parse(url, mtime: mtime))
        #expect(f.records.map(\.time.timeIntervalSince1970) == [1790812802, 1790812803.25])
    }
}

@Suite("Regression: Copilot AI units")
struct CopilotAIUnitRegressionTests {
    /// Copilot in VS Code (observed): invoke_agent has a parent (VS Code's agent host span), so a
    /// "no parent = top-level" rule found nothing and AI units stayed 0. Units now come from chat
    /// spans, counted once however the invocation is wrapped.
    @Test func aiUnitsComeFromChatSpansWhateverTheParents() {
        func span(_ id: String, parent: String?, attrs: [String: Any]) -> [String: Any] {
            var s: [String: Any] = ["traceId": "t", "spanId": id, "endTimeUnixNano": "1791019312796000000",
                                    "attributes": attrs.map { otlpAttr($0.key, $0.value) }]
            if let parent { s["parentSpanId"] = parent }
            return s
        }
        let body = jsonData(["resourceSpans": [["scopeSpans": [["spans": [
            span("host", parent: nil, attrs: ["vscode.agent_host.turnId": "t1"]),
            span("agent", parent: "host", attrs: ["gen_ai.operation.name": "invoke_agent", "gen_ai.conversation.id": "c",
                                                  "github.copilot.nano_aiu": 195_224_000.0]),
            span("chat1", parent: "agent", attrs: ["gen_ai.operation.name": "chat", "gen_ai.conversation.id": "c",
                                                   "gen_ai.usage.input_tokens": 22654, "gen_ai.usage.output_tokens": 136,
                                                   "github.copilot.nano_aiu": 195_224_000.0]),
        ]]]]]])
        let spans = CopilotParser.parseTraces(body)
        #expect(spans.map(\.nanoAIU) == [195_224_000])
        #expect(spans.map(\.tokens.total) == [22790])
    }

    /// Copilot CLI 1.0.91 (observed): two chat requests in one invocation; their AI units add up
    /// to the top-level invoke_agent's (155,944,000) and the CLI's "AI Credits 0.16".
    @Test func multipleChatSpansAddUp() {
        let spans = CopilotParser.parseTraces(tracesBody([
            ("root", ["gen_ai.operation.name": "invoke_agent", "gen_ai.conversation.id": "c", "github.copilot.nano_aiu": 155_944_000.0]),
            ("c1", ["gen_ai.operation.name": "chat", "gen_ai.conversation.id": "c", "github.copilot.nano_aiu": 80_000_000.0]),
            ("c2", ["gen_ai.operation.name": "chat", "gen_ai.conversation.id": "c", "github.copilot.nano_aiu": 75_944_000.0]),
        ], parents: ["c1": "root", "c2": "root"]))
        #expect(spans.reduce(0) { $0 + $1.nanoAIU } == 155_944_000)
    }
}

@Suite("Regression: review round 3")
struct ReviewRound3RegressionTests {
    @Test func chunkTerminatorMustBeCRLF() {
        let bad = Data("POST /v1/traces HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nabcdXY3\r\nefg\r\n0\r\n\r\n".utf8)
        guard case .invalid = HTTPRequest.parse(bad) else { Issue.record("expected invalid"); return }
    }

    @Test func varintOver64BitsIsRejected() {
        // Field 1, varint whose 10th byte carries more than the 64th bit.
        let over = Data([0x08] + Array(repeating: 0xff, count: 9) + [0x02])
        #expect(OTLPProtobuf.traceSpans(over) == nil)
        // UInt64.max is still valid.
        let max = Data([0x08] + Array(repeating: 0xff, count: 9) + [0x01])
        #expect(OTLPProtobuf.traceSpans(max) != nil)
    }

    @Test func spanIdsAreCaseInsensitive() {
        func body(_ id: String) -> Data {
            tracesBody([(id, ["gen_ai.operation.name": "chat", "gen_ai.conversation.id": "c",
                              "gen_ai.usage.input_tokens": 10, "github.copilot.nano_aiu": 1_000_000.0])])
        }
        let upper = CopilotParser.parseTraces(body("5B8EFFF798038103"))
        let lower = CopilotParser.parseTraces(body("5b8efff798038103"))
        #expect(upper.map(\.spanId) == lower.map(\.spanId))
    }
}
