import Foundation
import SwiftUI

struct ClaudeModelUsage: Codable, Equatable {
    var tokens: Double = 0
    var costUSD: Double = 0
}

struct ClaudeSession: Codable, Identifiable, Equatable {
    let id: String
    var label: String?
    var localName: String?
    var cwd: String?
    var isLocal = false
    /// Keyed by token type: input, output, cacheRead, cacheCreation.
    var tokens: [String: Double] = [:]
    var costUSD: Double = 0
    /// Keyed by model ID. Optional so state saved by older builds still decodes.
    var byModel: [String: ClaudeModelUsage]?
    var firstSeen: Date
    var lastSeen: Date

    var totalTokens: Double { tokens.values.reduce(0, +) }

    /// Per-model usage, largest token count first.
    var modelBreakdown: [(model: String, usage: ClaudeModelUsage)] {
        (byModel ?? [:]).map { ($0.key, $0.value) }.sorted { $0.usage.tokens > $1.usage.tokens }
    }

    var displayName: String {
        if let label, !label.isEmpty { return label }
        if let localName, !localName.isEmpty { return localName }
        if let cwd { return (cwd as NSString).lastPathComponent }
        return String(id.prefix(8))
    }

    var origin: String {
        if label != nil { return "remote" }
        return isLocal ? "local" : "unknown host"
    }
}

private struct PersistedState: Codable {
    /// Absent in state saved by v0.0.1, whose series keys lack the session and resource attributes.
    static let currentFormat = 2
    var formatVersion: Int?
    var sessions: [String: ClaudeSession]
    var seriesLast: [String: Double]
    // Optional so state saved by older builds still decodes.
    var seriesLastTime: [String: Date]?
    var periods: [CollectionPeriod]?
    var recent: RecentKeys?
    /// Cumulative readings from unversioned state, used once when that series is seen again.
    var legacySeriesLast: [String: Double]?
    var legacySeriesLastTime: [String: Date]?
}

@MainActor
final class ClaudeStore: ObservableObject {
    @Published private(set) var sessions: [String: ClaudeSession] = [:]
    @Published var serverState: OTLPServer.State = .stopped
    @Published private(set) var now = Date()

    /// Last seen value and time of each cumulative series, to convert cumulative to delta.
    private var seriesLast: [String: Double] = [:]
    private var seriesLastTime: [String: Date] = [:]
    private var legacySeriesLast: [String: Double] = [:]
    private var legacySeriesLastTime: [String: Date] = [:]
    /// Periods when Claude Code was collected; usage outside them is not counted.
    private var periods: [CollectionPeriod] = []
    /// Recently counted delta points, so a re-sent export is not counted twice.
    private var recent = RecentKeys()
    private var saveTask: Task<Void, Never>?
    private var ticker: Timer?
    private let fileURL: URL

    init() {
        fileURL = AppSupport.directory.appendingPathComponent("claude-state.json")
    }

    private var loaded = false
    var isRunning: Bool { ticker != nil }

    /// Starts or stops this source. While stopped, no timer runs and no file is read or written.
    func setRunning(_ on: Bool) {
        ticker?.invalidate()
        ticker = nil
        guard on else {
            saveTask?.cancel()
            if loaded {
                periods.close()
                saveNow()
            }
            return
        }
        if !loaded {
            load()
            loaded = true
        }
        // Keep a period left open when the app quit while collecting.
        periods.open()
        saveNow()
        now = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: Activity.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }

    // MARK: Ingest

    func ingest(_ points: [UsagePoint]) {
        guard isRunning else { return }
        recent.prune()
        pruneLegacySeries()
        for p in points {
            let delta: Double
            if p.isCumulative {
                var last = seriesLast[p.seriesKey], lastTime = seriesLastTime[p.seriesKey]
                // First reading since loading unversioned state: continue from its saved reading,
                // stored under either the current key or the v0.0.1 key.
                // It moves to the current key right away, so a stale reading that is skipped below
                // cannot lose it.
                if last == nil,
                   let k = [p.seriesKey, p.legacySeriesKey].compactMap({ $0 }).first(where: { legacySeriesLast[$0] != nil }) {
                    last = legacySeriesLast[k]
                    lastTime = legacySeriesLastTime[k]
                    seriesLast[p.seriesKey] = last
                    seriesLastTime[p.seriesKey] = lastTime
                    legacySeriesLast[k] = nil
                    legacySeriesLastTime[k] = nil
                }
                if let last, let lastTime {
                    // A reading not newer than the last one is a late or re-sent export.
                    if p.time <= lastTime { continue }
                    // The key includes the series start time, so a process restart starts a new
                    // series; a lower value in the same series is an anomaly, unless the start
                    // time is unknown and the drop can only mean a restart.
                    if p.value < last && p.startTime != nil { continue }
                }
                seriesLast[p.seriesKey] = p.value
                seriesLastTime[p.seriesKey] = p.time
                if let last, let lastTime, p.value >= last, periods.covers(start: lastTime, end: p.time) {
                    delta = p.value - last
                } else {
                    // First value of the series, a gap across an off period, or a reset (process
                    // restart): count the whole value only if the series started while collecting;
                    // otherwise it is just the baseline.
                    delta = periods.covers(start: p.startTime, end: p.time) ? p.value : 0
                }
            } else {
                let at = "@" + String(p.time.timeIntervalSince1970)
                // A re-sent point already counted under its v0.0.1 key is a duplicate too.
                if let lk = p.legacySeriesKey, recent.contains(lk + at) { continue }
                guard periods.covers(start: p.startTime, end: p.time),
                      recent.insertIfNew(p.seriesKey + at, time: p.time)
                else { continue }
                delta = p.value
            }
            guard delta > 0 else { continue }

            var s = sessions[p.sessionId] ?? newSession(id: p.sessionId, at: p.time)
            if let label = p.label { s.label = label }
            s.lastSeen = max(s.lastSeen, Date())
            let model = p.model ?? "unknown"
            var byModel = s.byModel ?? [:]
            switch p.kind {
            case .tokens:
                s.tokens[p.tokenType ?? "other", default: 0] += delta
                byModel[model, default: ClaudeModelUsage()].tokens += delta
            case .cost:
                s.costUSD += delta
                byModel[model, default: ClaudeModelUsage()].costUSD += delta
            }
            s.byModel = byModel
            sessions[p.sessionId] = s
        }
        scheduleSave()
    }

    private func newSession(id: String, at time: Date) -> ClaudeSession {
        var s = ClaudeSession(id: id, firstSeen: time, lastSeen: time)
        if let info = ClaudeSessionNames.lookup(sessionId: id) {
            s.isLocal = true
            s.localName = info.name
            s.cwd = info.cwd
        }
        return s
    }

    /// Re-resolve names of sessions that had no local match when first seen
    /// (the transcript may not have existed yet).
    func refreshNames() {
        guard isRunning else { return }
        for (id, s) in sessions where !s.isLocal && s.label == nil {
            guard let info = ClaudeSessionNames.lookup(sessionId: id) else { continue }
            sessions[id]?.isLocal = true
            sessions[id]?.localName = info.name
            sessions[id]?.cwd = info.cwd
        }
    }

    // MARK: Queries

    var totalCost: Double { sessions.values.reduce(0) { $0 + $1.costUSD } }
    var totalTokens: Double { sessions.values.reduce(0) { $0 + $1.totalTokens } }

    /// Most recently active first.
    var sortedSessions: [ClaudeSession] { sessions.values.sorted { $0.lastSeen > $1.lastSeen } }

    func isActive(_ s: ClaudeSession) -> Bool { now.timeIntervalSince(s.lastSeen) < Activity.window }

    /// Clears the accumulated usage; counting restarts from now. Cumulative marks and recent
    /// keys are kept so data from before the reset is never counted.
    func reset() {
        if !loaded {
            load()
            loaded = true
        }
        sessions = [:]
        periods = isRunning ? [CollectionPeriod(start: Date())] : []
        saveNow()
    }

    /// Called once at launch while Claude Code is off: closes a period left open because
    /// collection was turned off while the app was not running.
    func closeOpenPeriod() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        load()
        loaded = true
        if periods.close() { saveNow() }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        sessions = state.sessions
        periods = state.periods ?? []
        recent = state.recent ?? RecentKeys()
        if state.formatVersion == nil {
            // Saved before format versions: keys may be v0.0.1's or current. Readings are kept aside
            // and matched by either key when each series is seen again.
            legacySeriesLast = state.seriesLast
            legacySeriesLastTime = state.seriesLastTime ?? [:]
        } else {
            seriesLast = state.seriesLast
            seriesLastTime = state.seriesLastTime ?? [:]
            legacySeriesLast = state.legacySeriesLast ?? [:]
            legacySeriesLastTime = state.legacySeriesLastTime ?? [:]
        }
    }

    /// A v0.0.1 reading not seen again within the de-duplication window is no longer useful.
    private func pruneLegacySeries() {
        let cutoff = Date().addingTimeInterval(-RecentKeys.window)
        for (k, t) in legacySeriesLastTime where t < cutoff {
            legacySeriesLast[k] = nil
            legacySeriesLastTime[k] = nil
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
        guard loaded else { return }
        let state = PersistedState(formatVersion: PersistedState.currentFormat, sessions: sessions,
                                   seriesLast: seriesLast, seriesLastTime: seriesLastTime, periods: periods,
                                   recent: recent, legacySeriesLast: legacySeriesLast,
                                   legacySeriesLastTime: legacySeriesLastTime)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

enum Format {
    /// Local calendar day, yyyy-MM-dd.
    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func usd(_ v: Double) -> String {
        if v == 0 { return "$0" }
        return v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
    }

    /// Whole thousands with a lowercase k, e.g. "0k", "23k", "1,234k".
    static func kTokens(_ v: Double) -> String {
        (v / 1000).formatted(.number.precision(.fractionLength(0))) + "k"
    }

    static func tokens(_ v: Double) -> String {
        switch v {
        case 1_000_000_000...: String(format: "%.1fB", v / 1e9)
        case 1_000_000...: String(format: "%.1fM", v / 1e6)
        case 1_000...: String(format: "%.1fK", v / 1e3)
        default: String(format: "%.0f", v)
        }
    }
}
