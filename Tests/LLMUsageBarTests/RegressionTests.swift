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
