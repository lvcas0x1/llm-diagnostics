import Foundation

/// One data point of `claude_code.token.usage` or `claude_code.cost.usage`.
struct UsagePoint: Sendable {
    enum Kind: Sendable { case tokens, cost }

    let kind: Kind
    let sessionId: String
    let model: String?
    /// Token type: input, output, cacheRead, cacheCreation. Nil for cost.
    let tokenType: String?
    let value: Double
    let isCumulative: Bool
    /// Identifies a time series; used to convert cumulative values to deltas.
    let seriesKey: String
    /// Value of the `cc.label` resource attribute, if the sender set one.
    let label: String?
    let terminalType: String?
    /// End of the measured interval (`timeUnixNano`).
    let time: Date
    /// Start of the measured interval (`startTimeUnixNano`): for delta points the previous
    /// export, for cumulative points the process start.
    var startTime: Date? = nil
}

/// Parses OTLP/HTTP JSON metric export requests (ExportMetricsServiceRequest).
/// Spec: https://opentelemetry.io/docs/specs/otlp/#json-protobuf-encoding
enum OTLPParser {
    static let tokenMetric = "claude_code.token.usage"
    static let costMetric = "claude_code.cost.usage"
    static let labelAttribute = "cc.label"

    static func parseMetrics(_ data: Data) -> [UsagePoint] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resourceMetrics = root["resourceMetrics"] as? [[String: Any]]
        else { return [] }

        var points: [UsagePoint] = []
        for rm in resourceMetrics {
            let resourceAttrs = attributes((rm["resource"] as? [String: Any])?["attributes"])
            for sm in rm["scopeMetrics"] as? [[String: Any]] ?? [] {
                for metric in sm["metrics"] as? [[String: Any]] ?? [] {
                    guard let name = metric["name"] as? String,
                          name == tokenMetric || name == costMetric,
                          let sum = metric["sum"] as? [String: Any]
                    else { continue }
                    let cumulative = isCumulative(sum["aggregationTemporality"])
                    for dp in sum["dataPoints"] as? [[String: Any]] ?? [] {
                        let attrs = attributes(dp["attributes"])
                        guard let sessionId = attrs["session.id"] ?? resourceAttrs["session.id"],
                              let value = number(dp["asDouble"]) ?? number(dp["asInt"])
                        else { continue }
                        let start = stringValue(dp["startTimeUnixNano"]) ?? ""
                        // The session ID may come from the resource, so the key includes the
                        // session and every resource attribute, not only the data point attributes.
                        func joined(_ a: [String: String]) -> String {
                            a.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                        }
                        let key = [name, "session=" + sessionId, joined(resourceAttrs), joined(attrs), start]
                            .joined(separator: "|")
                        let nanos = number(dp["timeUnixNano"]) ?? 0
                        points.append(UsagePoint(
                            kind: name == tokenMetric ? .tokens : .cost,
                            sessionId: sessionId,
                            model: attrs["model"],
                            tokenType: attrs["type"],
                            value: value,
                            isCumulative: cumulative,
                            seriesKey: key,
                            label: attrs[labelAttribute] ?? resourceAttrs[labelAttribute],
                            terminalType: attrs["terminal.type"],
                            time: nanos > 0 ? Date(timeIntervalSince1970: nanos / 1e9) : Date(),
                            startTime: number(dp["startTimeUnixNano"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1e9) : nil }
                        ))
                    }
                }
            }
        }
        return points
    }

    /// AGGREGATION_TEMPORALITY_CUMULATIVE = 2 (enum may arrive as int or name).
    private static func isCumulative(_ raw: Any?) -> Bool {
        if let n = raw as? NSNumber { return n.intValue == 2 }
        if let s = raw as? String { return s == "2" || s.hasSuffix("CUMULATIVE") }
        return false
    }

    static func attributes(_ raw: Any?) -> [String: String] {
        var out: [String: String] = [:]
        for kv in raw as? [[String: Any]] ?? [] {
            guard let key = kv["key"] as? String,
                  let value = kv["value"] as? [String: Any] else { continue }
            if let s = value["stringValue"] as? String { out[key] = s }
            else if let v = value["intValue"] ?? value["doubleValue"] ?? value["boolValue"] {
                out[key] = "\(v)"
            }
        }
        return out
    }

    /// int64 values are encoded as JSON strings in OTLP/JSON; accept both forms.
    static func number(_ raw: Any?) -> Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    static func stringValue(_ raw: Any?) -> String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }
}
