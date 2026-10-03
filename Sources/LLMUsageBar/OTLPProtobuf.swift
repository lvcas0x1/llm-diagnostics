import Foundation

/// Format-independent view of one OTLP span: what the Copilot parser needs from either encoding.
struct OTLPSpan {
    /// Lowercase hex, as in OTLP/JSON.
    var spanId = ""
    var parentSpanId = ""
    var startNanos: Double = 0
    var endNanos: Double = 0
    var attributes: [String: String] = [:]
    var resource: [String: String] = [:]
}

/// Minimal protobuf wire-format reader (https://protobuf.dev/programming-guides/encoding/).
/// Every read is bounds-checked; malformed input throws.
struct ProtobufReader {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(ArraySlice<UInt8>)
    }

    struct Malformed: Error {}

    private let bytes: ArraySlice<UInt8>
    private var index: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        index = bytes.startIndex
    }

    /// The next field, or nil at the end of the message.
    mutating func next() throws -> (number: Int, value: Value)? {
        guard index < bytes.endIndex else { return nil }
        let key = try varint()
        let number = Int(key >> 3)
        guard number > 0 else { throw Malformed() }
        switch key & 7 {
        case 0: return (number, .varint(try varint()))
        case 1: return (number, .fixed64(try fixed(8)))
        case 5: return (number, .fixed32(UInt32(try fixed(4))))
        case 2:
            let length = try varint()
            guard length <= UInt64(bytes.endIndex - index) else { throw Malformed() }
            let end = index + Int(length)
            defer { index = end }
            return (number, .bytes(bytes[index..<end]))
        default:
            throw Malformed()  // groups (3, 4) are deprecated and not used by OTLP
        }
    }

    private mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, to: 70, by: 7) {
            guard index < bytes.endIndex else { throw Malformed() }
            let b = bytes[index]
            index += 1
            // The 10th byte holds only bit 63; anything more does not fit in 64 bits.
            if shift == 63 && b > 1 { throw Malformed() }
            result |= UInt64(b & 0x7f) << UInt64(shift)
            if b & 0x80 == 0 { return result }
        }
        throw Malformed()
    }

    private mutating func fixed(_ size: Int) throws -> UInt64 {
        guard bytes.endIndex - index >= size else { throw Malformed() }
        var result: UInt64 = 0
        for k in 0..<size { result |= UInt64(bytes[index + k]) << UInt64(8 * k) }  // little-endian
        index += size
        return result
    }
}

/// Decodes OTLP/HTTP protobuf trace exports (ExportTraceServiceRequest). Field numbers from
/// opentelemetry-proto: collector/trace/v1/trace_service.proto, trace/v1/trace.proto,
/// common/v1/common.proto, resource/v1/resource.proto. Unknown fields are skipped.
enum OTLPProtobuf {
    /// Spans of the request, or nil when the body is not valid protobuf.
    static func traceSpans(_ data: Data) -> [OTLPSpan]? {
        let bytes = [UInt8](data)
        do {
            var spans: [OTLPSpan] = []
            var request = ProtobufReader(bytes[...])
            while let f = try request.next() {
                // ExportTraceServiceRequest.resource_spans = 1
                if f.number == 1, case .bytes(let rs) = f.value { spans += try resourceSpans(rs) }
            }
            return spans
        } catch {
            return nil
        }
    }

    private static func resourceSpans(_ b: ArraySlice<UInt8>) throws -> [OTLPSpan] {
        var resource: [String: String] = [:]
        var scopes: [ArraySlice<UInt8>] = []
        var r = ProtobufReader(b)
        while let f = try r.next() {
            guard case .bytes(let v) = f.value else { continue }
            switch f.number {
            case 1: resource = try attributes(of: v, field: 1)  // Resource.attributes = 1
            case 2: scopes.append(v)                            // ResourceSpans.scope_spans = 2
            default: break
            }
        }
        var spans: [OTLPSpan] = []
        for scope in scopes {
            var s = ProtobufReader(scope)
            while let f = try s.next() {
                // ScopeSpans.spans = 2
                if f.number == 2, case .bytes(let v) = f.value {
                    var span = try self.span(v)
                    span.resource = resource
                    spans.append(span)
                }
            }
        }
        return spans
    }

    private static func span(_ b: ArraySlice<UInt8>) throws -> OTLPSpan {
        var span = OTLPSpan()
        var r = ProtobufReader(b)
        while let f = try r.next() {
            switch (f.number, f.value) {
            case (2, .bytes(let v)): span.spanId = hex(v)                 // span_id
            case (4, .bytes(let v)): span.parentSpanId = hex(v)           // parent_span_id
            case (7, .fixed64(let v)): span.startNanos = Double(v)       // start_time_unix_nano
            case (8, .fixed64(let v)): span.endNanos = Double(v)         // end_time_unix_nano
            case (9, .bytes(let v)):                                       // attributes
                if let (k, value) = try keyValue(v) { span.attributes[k] = value }
            default: break
            }
        }
        return span
    }

    /// Reads the repeated KeyValue field `field` of a message.
    private static func attributes(of b: ArraySlice<UInt8>, field: Int) throws -> [String: String] {
        var out: [String: String] = [:]
        var r = ProtobufReader(b)
        while let f = try r.next() {
            if f.number == field, case .bytes(let v) = f.value, let (k, value) = try keyValue(v) { out[k] = value }
        }
        return out
    }

    /// KeyValue { key = 1; value = 2 } with scalar AnyValue values as strings, like the JSON path.
    private static func keyValue(_ b: ArraySlice<UInt8>) throws -> (String, String)? {
        var key: String?
        var value: String?
        var r = ProtobufReader(b)
        while let f = try r.next() {
            switch (f.number, f.value) {
            case (1, .bytes(let v)): key = String(decoding: v, as: UTF8.self)
            case (2, .bytes(let v)): value = try anyValue(v)
            default: break
            }
        }
        guard let key, let value else { return nil }
        return (key, value)
    }

    /// AnyValue: string = 1, bool = 2, int64 = 3, double = 4. Arrays, maps, and bytes are ignored.
    private static func anyValue(_ b: ArraySlice<UInt8>) throws -> String? {
        var out: String?
        var r = ProtobufReader(b)
        while let f = try r.next() {
            switch (f.number, f.value) {
            case (1, .bytes(let v)): out = String(decoding: v, as: UTF8.self)
            case (2, .varint(let v)): out = v != 0 ? "true" : "false"
            case (3, .varint(let v)): out = String(Int64(bitPattern: v))
            case (4, .fixed64(let v)): out = String(Double(bitPattern: v))
            default: break
            }
        }
        return out
    }

    private static func hex(_ b: ArraySlice<UInt8>) -> String {
        b.map { String(format: "%02x", $0) }.joined()
    }
}
