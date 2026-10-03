import Foundation
import Network
import Testing
@testable import LLMUsageBar

/// ExportTraceServiceRequest encoded by the official opentelemetry-proto 1.45.0 Python package
/// (protobuf 7.36.2), shaped like a real Copilot trace in VS Code: an agent-host span without
/// gen_ai attributes, an invoke_agent under it (220,880,000 nano AIU), and a chat child (gpt-6-luna,
/// 12,166 in / 5 out / 1,280 cached, 220,880,000 nano AIU, with an event and a status). Resource
/// attributes: service.name = copilot-chat, cc.label = vscode.
let officialTraceFixture = Data(base64Encoded: "CqgGCjYKHgoMc2VydmljZS5uYW1lEg4KDGNvcGlsb3QtY2hhdAoUCghjYy5sYWJlbBIICgZ2c2NvZGUS7QUKDgoMY29waWxvdC1jaGF0ElgKEL4kYfzwcixYdsDvtiE814cSCKqqqqqqqqqqKg9hZ2VudF9ob3N0LnR1cm5BAOhOZZP62hhKIAoYdnNjb2RlLmFnZW50X2hvc3QudHVybklkEgQKAnQxEtsBChC+JGH88HIsWHbA77YhPNeHEgiwWPxoFfAo1iIIqqqqqqqqqqoqDGludm9rZV9hZ2VudDlAGWC7kvraGEEA3xFlk/raGEonChVnZW5fYWkub3BlcmF0aW9uLm5hbWUSDgoMaW52b2tlX2FnZW50SiMKFmdlbl9haS5jb252ZXJzYXRpb24uaWQSCQoHY29udi1wYkokChdnaXRodWIuY29waWxvdC5uYW5vX2FpdRIJIQAAAAC5VKpBSh8KGWdpdGh1Yi5jb3BpbG90LnR1cm5fY291bnQSAhgBEqIDChC+JGH88HIsWHbA77YhPNeHEgjd3acmzN/LWSIIsFj8aBXwKNYqD2NoYXQgZ3B0LTYtbHVuYTlARpG8kvraGEGAUbZkk/raGEofChVnZW5fYWkub3BlcmF0aW9uLm5hbWUSBgoEY2hhdEojChZnZW5fYWkuY29udmVyc2F0aW9uLmlkEgkKB2NvbnYtcGJKHgoUZ2VuX2FpLnJlcXVlc3QubW9kZWwSBgoEYXV0b0olChVnZW5fYWkucmVzcG9uc2UubW9kZWwSDAoKZ3B0LTYtbHVuYUogChlnZW5fYWkudXNhZ2UuaW5wdXRfdG9rZW5zEgMYhl9KIAoaZ2VuX2FpLnVzYWdlLm91dHB1dF90b2tlbnMSAhgFSisKJGdlbl9haS51c2FnZS5jYWNoZV9yZWFkLmlucHV0X3Rva2VucxIDGIAKShsKFWdlbl9haS5yZXF1ZXN0LnN0cmVhbRICEAFKJAoXZ2l0aHViLmNvcGlsb3QubmFub19haXUSCSEAAAAAuVSqQVoSCQEAAAAAAAAAEgdpZ25vcmVkegIYAQ==")!

@Suite("Unit: OTLP protobuf traces")
struct ProtobufTraceTests {
    @Test func decodesOfficialEncoding() throws {
        let raw = try #require(OTLPProtobuf.traceSpans(officialTraceFixture))
        #expect(raw.map(\.spanId) == ["aaaaaaaaaaaaaaaa", "b058fc6815f028d6", "dddda726ccdfcb59"])
        #expect(raw.map(\.parentSpanId) == ["", "aaaaaaaaaaaaaaaa", "b058fc6815f028d6"])
        #expect(raw[1].startNanos == 1_791_019_309_949_000_000)
        #expect(raw[1].endNanos == 1_791_019_312_796_000_000)
        #expect(raw[2].resource["cc.label"] == "vscode")
        #expect(raw[2].attributes["gen_ai.usage.input_tokens"] == "12166")
        #expect(raw[2].attributes["gen_ai.request.stream"] == "true")
        #expect(raw[2].attributes["github.copilot.nano_aiu"].flatMap(Double.init) == 220_880_000)
    }

    @Test func producesCopilotSpansLikeJSON() throws {
        let spans = try #require(CopilotParser.parseTracesProtobuf(officialTraceFixture))
        #expect(spans.count == 1)  // only the chat span carries usage
        #expect(spans[0].model == "gpt-6-luna")
        #expect(spans[0].tokens.input == 12166 && spans[0].tokens.output == 5 && spans[0].tokens.cacheRead == 1280)
        #expect(spans[0].nanoAIU == 220_880_000)
        #expect(spans[0].sessionId == "conv-pb" && spans[0].label == "vscode")

        // The same data as OTLP/JSON gives the same result.
        func span(_ id: String, _ parent: String, _ start: String, _ end: String, _ attrs: [String: Any]) -> [String: Any] {
            ["spanId": id, "parentSpanId": parent, "startTimeUnixNano": start, "endTimeUnixNano": end,
             "attributes": attrs.map { otlpAttr($0.key, $0.value) }]
        }
        let json = jsonData(["resourceSpans": [[
            "resource": ["attributes": [otlpAttr("service.name", "copilot-chat"), otlpAttr("cc.label", "vscode")]],
            "scopeSpans": [["spans": [
                span("aaaaaaaaaaaaaaaa", "", "0", "1791019312800000000", ["vscode.agent_host.turnId": "t1"]),
                span("b058fc6815f028d6", "aaaaaaaaaaaaaaaa", "1791019309949000000", "1791019312796000000",
                     ["gen_ai.operation.name": "invoke_agent", "gen_ai.conversation.id": "conv-pb", "github.copilot.nano_aiu": 220_880_000.0]),
                span("dddda726ccdfcb59", "b058fc6815f028d6", "1791019309969000000", "1791019312790000000",
                     ["gen_ai.operation.name": "chat", "gen_ai.conversation.id": "conv-pb", "gen_ai.request.model": "auto",
                      "gen_ai.response.model": "gpt-6-luna", "gen_ai.usage.input_tokens": 12166,
                      "gen_ai.usage.output_tokens": 5, "gen_ai.usage.cache_read.input_tokens": 1280,
                      "github.copilot.nano_aiu": 220_880_000.0]),
            ]]],
        ]]])
        let fromJSON = CopilotParser.parseTraces(json)
        #expect(fromJSON.map(\.spanId) == spans.map(\.spanId))
        #expect(fromJSON.map(\.time) == spans.map(\.time))
        #expect(fromJSON.map(\.startTime) == spans.map(\.startTime))
        #expect(fromJSON.map(\.nanoAIU) == spans.map(\.nanoAIU))
    }

    @Test func emptyBodyIsAnEmptyRequest() {
        #expect(CopilotParser.parseTracesProtobuf(Data())?.isEmpty == true)
    }

    @Test func everyTruncationIsRejectedWithoutCrashing() {
        // Cutting inside a field must be reported as malformed; cutting exactly at a top-level
        // field boundary is a valid shorter message.
        for n in 1..<officialTraceFixture.count {
            _ = OTLPProtobuf.traceSpans(officialTraceFixture.prefix(n))
        }
        #expect(OTLPProtobuf.traceSpans(officialTraceFixture.prefix(officialTraceFixture.count - 1)) == nil)
    }

    @Test func malformedInputIsRejected() {
        #expect(OTLPProtobuf.traceSpans(Data([0x0a, 0xff, 0xff, 0xff, 0xff, 0x0f])) == nil)        // length beyond end
        #expect(OTLPProtobuf.traceSpans(Data([0x08] + Array(repeating: 0xff, count: 11))) == nil)  // varint too long
        #expect(OTLPProtobuf.traceSpans(Data([0x0b])) == nil)                                       // group wire type
        #expect(OTLPProtobuf.traceSpans(Data([0x00, 0x00])) == nil)                                 // field number 0
        #expect(OTLPProtobuf.traceSpans(Data("{\"resourceSpans\":[]}".utf8)) == nil)              // JSON is not protobuf
    }

    @Test func negativeIntAndUnknownFieldsAreHandled() throws {
        // KeyValue{key:"n", value:AnyValue{int_value:-1}} inside a span, plus unknown fields of every
        // wire type at each level.
        let anyValue: [UInt8] = [0x18] + Array(repeating: 0xff, count: 9) + [0x01]           // int_value = -1
        let kv: [UInt8] = [0x0a, 0x01, 0x6e, 0x12, UInt8(anyValue.count)] + anyValue
        let span: [UInt8] = [0x12, 0x01, 0xab] + [0x4a, UInt8(kv.count)] + kv
            + [0xf8, 0x07, 0x01] + [0xfd, 0x07, 1, 2, 3, 4] + [0xf9, 0x07, 1, 2, 3, 4, 5, 6, 7, 8]  // fields 127
        let scope: [UInt8] = [0x12, UInt8(span.count)] + span + [0x1a, 0x00]
        let resourceSpans: [UInt8] = [0x12, UInt8(scope.count)] + scope + [0x18, 0x05]
        let request: [UInt8] = [0x0a, UInt8(resourceSpans.count)] + resourceSpans + [0x10, 0x01]
        let raw = try #require(OTLPProtobuf.traceSpans(Data(request)))
        #expect(raw.count == 1)
        #expect(raw[0].spanId == "ab")
        #expect(raw[0].attributes["n"] == "-1")
    }
}

@Suite("Integration: protobuf over the receiver", .serialized)
struct ProtobufServerTests {
    @Test func protobufTracesAreAcceptedWithoutChangingMetrics() async throws {
        let inbox = IntegrationTests.Inbox()
        let server = OTLPServer(onPoints: { inbox.add($0) }, onSpans: { inbox.add($0) }, onState: { inbox.add($0) })
        let port: UInt16 = 47_320
        server.start(port: port, metrics: true, traces: false)
        await IntegrationTests.waitUntil { inbox.states.contains(.listening(port: port)) }

        func post(_ path: String, _ body: Data, _ type: String) async throws -> (Int, String?, Int) {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            req.httpMethod = "POST"
            req.setValue(type, forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as! HTTPURLResponse
            return (http.statusCode, http.value(forHTTPHeaderField: "Content-Type"), data.count)
        }

        // Copilot off: protobuf traces answered 200 (empty protobuf response) and ignored.
        var r = try await post("/v1/traces", officialTraceFixture, "application/x-protobuf")
        #expect(r.0 == 200 && r.1 == "application/x-protobuf" && r.2 == 0)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(inbox.spans.isEmpty)

        // Copilot on: recorded.
        server.start(port: port, metrics: true, traces: true)
        try? await Task.sleep(for: .milliseconds(100))
        r = try await post("/v1/traces", officialTraceFixture, "application/x-protobuf")
        #expect(r.0 == 200 && r.1 == "application/x-protobuf" && r.2 == 0)
        await IntegrationTests.waitUntil { inbox.spans.count == 1 }
        #expect(inbox.spans.count == 1)

        // Malformed protobuf: 400. Existing behavior unchanged: protobuf metrics 415, JSON traces 200 with "{}".
        r = try await post("/v1/traces", Data([0x0a, 0xff, 0x01]), "application/x-protobuf")
        #expect(r.0 == 400)
        r = try await post("/v1/metrics", officialTraceFixture, "application/x-protobuf")
        #expect(r.0 == 415)
        r = try await post("/v1/traces", Data("{}".utf8), "application/json")
        #expect(r.0 == 200 && r.1 == "application/json" && r.2 == 2)
        server.stop()
    }
}
