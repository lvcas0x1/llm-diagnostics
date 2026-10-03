import Foundation
import SwiftUI

/// Token counts in OTel GenAI terms: `input` includes cached tokens
/// ("This value SHOULD include all types of input tokens, including cached tokens").
struct CopilotTokens: Codable, Sendable {
    var input: Double = 0
    var output: Double = 0
    var cacheRead: Double = 0
    var cacheCreation: Double = 0

    var total: Double { input + output }
}

/// One LLM request (`chat` span) from a GitHub Copilot trace export.
struct CopilotSpan: Sendable {
    let spanId: String
    let sessionId: String
    let label: String?
    /// Span end (`endTimeUnixNano`).
    let time: Date
    let model: String
    let tokens: CopilotTokens
    /// AI units of this request, in nano AI units.
    let nanoAIU: Double
    /// Span start (`startTimeUnixNano`).
    var startTime: Date? = nil
}

/// Parses OTLP/HTTP trace exports (ExportTraceServiceRequest) from Copilot CLI and from the
/// Copilot SDK behind VS Code's Chat.
/// Span and attribute names: https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference#opentelemetry-monitoring
enum CopilotParser {
    /// OTLP/HTTP JSON (ExportTraceServiceRequest).
    static func parseTraces(_ data: Data) -> [CopilotSpan] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resourceSpans = root["resourceSpans"] as? [[String: Any]] else { return [] }
        var raw: [OTLPSpan] = []
        for rs in resourceSpans {
            let resource = OTLPParser.attributes((rs["resource"] as? [String: Any])?["attributes"])
            for ss in rs["scopeSpans"] as? [[String: Any]] ?? [] {
                for span in ss["spans"] as? [[String: Any]] ?? [] {
                    guard let spanId = span["spanId"] as? String else { continue }
                    // "case-insensitive hex-encoded strings" (OTLP/JSON); protobuf IDs become lowercase hex.
                    raw.append(OTLPSpan(
                        spanId: spanId.lowercased(),
                        parentSpanId: (span["parentSpanId"] as? String ?? "").lowercased(),
                        startNanos: OTLPParser.number(span["startTimeUnixNano"]) ?? 0,
                        endNanos: OTLPParser.number(span["endTimeUnixNano"]) ?? 0,
                        attributes: OTLPParser.attributes(span["attributes"]),
                        resource: resource))
                }
            }
        }
        return spans(from: raw)
    }

    /// OTLP/HTTP protobuf (ExportTraceServiceRequest); nil when the body is not valid protobuf.
    static func parseTracesProtobuf(_ data: Data) -> [CopilotSpan]? {
        OTLPProtobuf.traceSpans(data).map(spans(from:))
    }

    /// Usage comes from `chat` spans only, one per LLM request: tokens and that request's AI units.
    /// `invoke_agent` spans repeat the same AI units ("summing it across every span double-counts"),
    /// and which one is top-level differs by host (Copilot CLI: no parent; VS Code wraps it in its
    /// own spans), so they are not used. Observed: the chat spans' AI units add up to the top-level
    /// invoke_agent's and to the "AI Credits" Copilot CLI prints.
    static func spans(from raw: [OTLPSpan]) -> [CopilotSpan] {
        raw.compactMap { span in
            let a = span.attributes
            guard !span.spanId.isEmpty, a["gen_ai.operation.name"] == "chat",
                  let sessionId = a["gen_ai.conversation.id"] else { return nil }
            func n(_ k: String) -> Double { a[k].flatMap(Double.init) ?? 0 }
            return CopilotSpan(
                spanId: span.spanId, sessionId: sessionId,
                label: span.resource[OTLPParser.labelAttribute],
                time: span.endNanos > 0 ? Date(timeIntervalSince1970: span.endNanos / 1e9) : Date(),
                model: a["gen_ai.response.model"] ?? a["gen_ai.request.model"] ?? "unknown",
                tokens: CopilotTokens(
                    input: n("gen_ai.usage.input_tokens"), output: n("gen_ai.usage.output_tokens"),
                    cacheRead: n("gen_ai.usage.cache_read.input_tokens"),
                    cacheCreation: n("gen_ai.usage.cache_creation.input_tokens")),
                nanoAIU: n("github.copilot.nano_aiu"),
                startTime: span.startNanos > 0 ? Date(timeIntervalSince1970: span.startNanos / 1e9) : nil)
        }
    }
}

/// Usage accumulated by this app for one Copilot session.
struct CopilotSession: Codable, Identifiable {
    let id: String
    var label: String?
    var lastSeen: Date
    var byModel: [String: CopilotTokens] = [:]
    var nanoAIU: Double = 0

    var name: String { label ?? String(id.prefix(8)) }
    var totalTokens: Double { byModel.values.reduce(0) { $0 + $1.total } }
    /// 1 AI unit = 1 AI credit = $0.01 (see `CopilotStore.usdPerAIUnit`).
    var costUSD: Double { nanoAIU / 1_000_000_000 * CopilotStore.usdPerAIUnit }
}

private struct CopilotState: Codable {
    var sessions: [String: CopilotSession] = [:]
    // Optional so state saved by older builds still decodes.
    /// Periods when Copilot was collected; spans outside them are not counted.
    var periods: [CollectionPeriod]?
    /// Recently counted span IDs, so a re-sent export is not counted twice.
    var recent: RecentKeys?
}

@MainActor
final class CopilotStore: ObservableObject {
    /// "1 AI credit = $0.01 USD" (docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing).
    /// GitHub does not state that an OTel AI unit is one AI credit; observed with Copilot CLI 1.0.91,
    /// the span's AI units matched the "AI Credits" the CLI printed.
    nonisolated static let usdPerAIUnit = 0.01
    @Published private var state = CopilotState()
    @Published private(set) var now = Date()
    private var loaded = false
    private var ticker: Timer?
    private var saveTask: Task<Void, Never>?
    private let fileURL = AppSupport.directory.appendingPathComponent("copilot-state.json")

    var isRunning: Bool { ticker != nil }
    var sessions: [CopilotSession] { Array(state.sessions.values) }
    var totalTokens: Double { sessions.reduce(0) { $0 + $1.totalTokens } }
    var totalCost: Double { sessions.reduce(0) { $0 + $1.costUSD } }
    func isActive(_ s: CopilotSession) -> Bool { now.timeIntervalSince(s.lastSeen) < Activity.window }

    /// Starts or stops this provider. While stopped, no timer runs and no file is read or written.
    func setRunning(_ on: Bool) {
        ticker?.invalidate()
        ticker = nil
        guard on else {
            saveTask?.cancel()
            if loaded { state.periods?.close() }
            saveNow()
            return
        }
        load()
        // Keep a period left open when the app quit while collecting.
        state.periods = state.periods ?? []
        state.periods?.open()
        saveNow()
        now = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: Activity.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }

    func ingest(_ spans: [CopilotSpan]) {
        guard isRunning else { return }
        var recent = state.recent ?? RecentKeys()
        recent.prune()
        let periods = state.periods ?? []
        for span in spans {
            guard periods.covers(start: span.startTime, end: span.time),
                  recent.insertIfNew(span.spanId, time: span.time) else { continue }
            var s = state.sessions[span.sessionId] ?? CopilotSession(id: span.sessionId, lastSeen: span.time)
            if let label = span.label { s.label = label }
            s.lastSeen = max(s.lastSeen, Date())
            var m = s.byModel[span.model] ?? CopilotTokens()
            m.input += span.tokens.input
            m.output += span.tokens.output
            m.cacheRead += span.tokens.cacheRead
            m.cacheCreation += span.tokens.cacheCreation
            s.byModel[span.model] = m
            s.nanoAIU += span.nanoAIU
            state.sessions[span.sessionId] = s
        }
        state.recent = recent
        scheduleSave()
    }

    /// Clears the accumulated usage; counting restarts from now. Recent span IDs are kept.
    func reset() {
        load()
        state.sessions = [:]
        state.periods = isRunning ? [CollectionPeriod(start: Date())] : []
        saveNow()
    }

    /// Called once at launch while Copilot is off: closes a period left open because
    /// collection was turned off while the app was not running.
    func closeOpenPeriod() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        load()
        if state.periods?.close() == true { saveNow() }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(CopilotState.self, from: data) {
            state = saved
            // Span IDs are case-insensitive; older builds saved them as received.
            state.recent?.mapKeys { $0.lowercased() }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard loaded, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
