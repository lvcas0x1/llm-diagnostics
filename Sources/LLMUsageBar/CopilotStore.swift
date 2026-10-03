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

/// One span from a GitHub Copilot CLI trace export that carries usage.
struct CopilotSpan: Sendable {
    enum Kind: Sendable {
        /// One LLM request: tokens per model.
        case chat(model: String, tokens: CopilotTokens)
        /// Top-level agent invocation: AI units for the whole invocation, subagents included.
        case topLevelAgent(nanoAIU: Double)
    }

    let spanId: String
    let sessionId: String
    let label: String?
    /// Span end (`endTimeUnixNano`).
    let time: Date
    let kind: Kind
    /// Span start (`startTimeUnixNano`).
    var startTime: Date? = nil
}

/// Parses OTLP/HTTP JSON trace exports (ExportTraceServiceRequest) from Copilot CLI.
/// Span and attribute names: https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference#opentelemetry-monitoring
enum CopilotParser {
    static func parseTraces(_ data: Data) -> [CopilotSpan] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resourceSpans = root["resourceSpans"] as? [[String: Any]] else { return [] }
        var out: [CopilotSpan] = []
        for rs in resourceSpans {
            let resource = OTLPParser.attributes((rs["resource"] as? [String: Any])?["attributes"])
            for ss in rs["scopeSpans"] as? [[String: Any]] ?? [] {
                for span in ss["spans"] as? [[String: Any]] ?? [] {
                    let a = OTLPParser.attributes(span["attributes"])
                    guard let spanId = span["spanId"] as? String,
                          let sessionId = a["gen_ai.conversation.id"],
                          let op = a["gen_ai.operation.name"] else { continue }
                    func n(_ k: String) -> Double { a[k].flatMap(Double.init) ?? 0 }
                    let kind: CopilotSpan.Kind
                    switch op {
                    case "chat":
                        let model = a["gen_ai.response.model"] ?? a["gen_ai.request.model"] ?? "unknown"
                        kind = .chat(model: model, tokens: CopilotTokens(
                            input: n("gen_ai.usage.input_tokens"), output: n("gen_ai.usage.output_tokens"),
                            cacheRead: n("gen_ai.usage.cache_read.input_tokens"),
                            cacheCreation: n("gen_ai.usage.cache_creation.input_tokens")))
                    // Only top-level sessions carry server.address; read AI units there only,
                    // because child spans repeat them ("summing it across every span double-counts").
                    case "invoke_agent" where a["server.address"] != nil:
                        kind = .topLevelAgent(nanoAIU: n("github.copilot.nano_aiu"))
                    default:
                        continue
                    }
                    let nanos = OTLPParser.number(span["endTimeUnixNano"]) ?? 0
                    let startNanos = OTLPParser.number(span["startTimeUnixNano"]) ?? 0
                    out.append(CopilotSpan(
                        spanId: spanId, sessionId: sessionId,
                        label: resource[OTLPParser.labelAttribute],
                        time: nanos > 0 ? Date(timeIntervalSince1970: nanos / 1e9) : Date(),
                        kind: kind,
                        startTime: startNanos > 0 ? Date(timeIntervalSince1970: startNanos / 1e9) : nil))
                }
            }
        }
        return out
    }
}

/// Usage accumulated by this app for one Copilot CLI session.
struct CopilotSession: Codable, Identifiable {
    let id: String
    var label: String?
    var lastSeen: Date
    var byModel: [String: CopilotTokens] = [:]
    var nanoAIU: Double = 0

    var name: String { label ?? String(id.prefix(8)) }
    var totalTokens: Double { byModel.values.reduce(0) { $0 + $1.total } }
    /// Assumption (not stated in GitHub docs): 1 AI unit = 1 AI credit = $0.01.
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
    /// Treating an OTel AI unit as one AI credit is an unverified assumption.
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
            switch span.kind {
            case .chat(let model, let t):
                var m = s.byModel[model] ?? CopilotTokens()
                m.input += t.input
                m.output += t.output
                m.cacheRead += t.cacheRead
                m.cacheCreation += t.cacheCreation
                s.byModel[model] = m
            case .topLevelAgent(let nanoAIU):
                s.nanoAIU += nanoAIU
            }
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
