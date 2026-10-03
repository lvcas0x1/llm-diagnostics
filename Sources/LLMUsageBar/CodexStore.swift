import Foundation
import SwiftUI

/// Usage accumulated by this app for one Codex session.
struct CodexSession: Codable, Identifiable {
    struct ModelUsage: Codable {
        var tokens = CodexTokens()
        var costUSD: Double = 0
        /// Tokens counted while the model had no price; not included in `costUSD`.
        var unpricedTokens: Double = 0
    }

    let id: String
    var cwd: String?
    var source: String
    var lastActivity: Date
    var byModel: [String: ModelUsage] = [:]

    var name: String { cwd.map { ($0 as NSString).lastPathComponent } ?? String(id.prefix(8)) }
    var totalTokens: Double { byModel.values.reduce(0) { $0 + $1.tokens.total } }
    var costUSD: Double { byModel.values.reduce(0) { $0 + $1.costUSD } }
}

/// Persisted Codex state. Usage is counted only for records whose timestamp falls inside
/// a period when collection was on, and each record is counted once.
private struct CodexState: Codable {
    var periods: [CollectionPeriod] = []
    /// Number of usage records already processed per session ID (files are append-only).
    var processed: [String: Int] = [:]
    var sessions: [String: CodexSession] = [:]
}

@MainActor
final class CodexStore: ObservableObject {
    @Published private var state = CodexState()
    @Published private(set) var pricing = OpenAIPricing.bundled
    /// Date of the price table in use: the bundled copy's date, or when it was fetched.
    @Published private(set) var pricingDate = OpenAIPricing.bundledDate
    @Published private(set) var pricingError: String?
    @AppStorage("openAIPricingAutoUpdate") var autoUpdatePricing = true {
        didSet { if autoUpdatePricing && isRunning { updatePricingIfStale() } }
    }

    private let scanner = CodexScanner()
    private var timer: Timer?
    private var loaded = false
    private var saveTask: Task<Void, Never>?
    private let pricingFile: URL
    private let stateFile: URL
    private static let pricingMaxAge: TimeInterval = 24 * 60 * 60

    init() {
        pricingFile = AppSupport.directory.appendingPathComponent("openai-pricing.md")
        stateFile = AppSupport.directory.appendingPathComponent("codex-state.json")
    }

    var sessions: [CodexSession] { Array(state.sessions.values) }
    var isRunning: Bool { timer != nil }

    /// Starts or stops collection. While stopped, no timer runs, no file is read, nothing is downloaded.
    func setRunning(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else {
            if loaded, let last = state.periods.indices.last, state.periods[last].end == nil {
                state.periods[last].end = Date()
                saveNow()
            }
            return
        }
        loadState()
        // Open a collection period unless one is still open (the app quit while collecting).
        if state.periods.last.map({ $0.end != nil }) ?? true {
            state.periods.append(.init(start: Date()))
            saveNow()
        }
        loadCachedPricing()
        timer = Timer.scheduledTimer(withTimeInterval: Activity.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.updatePricingIfStale()
            }
        }
        refresh()
        updatePricingIfStale()
    }

    /// Called once at launch while Codex is off: closes a period left open because collection
    /// was turned off while the app was not running. Reads and writes the state file once.
    func closeOpenPeriod() {
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return }
        loadState()
        if let last = state.periods.indices.last, state.periods[last].end == nil {
            state.periods[last].end = Date()
            saveNow()
        }
    }

    /// Clears the accumulated usage and starts counting from now (if collecting).
    func reset() {
        loadState()
        let processed = state.processed
        state = CodexState()
        // Keep the processed marks so earlier records are never counted again.
        state.processed = processed
        if isRunning { state.periods.append(.init(start: Date())) }
        saveNow()
    }

    func refresh() {
        guard isRunning else { return }
        scanner.scan { [weak self] files in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.accumulate(files)
            }
        }
    }

    func accumulate(_ files: [CodexFile]) {
        var changed = false
        for file in files {
            let done = min(state.processed[file.sessionId] ?? 0, file.records.count)
            guard file.records.count > done else { continue }
            for record in file.records[done...] where state.periods.contains(where: { $0.contains(record.time) }) {
                var s = state.sessions[file.sessionId]
                    ?? CodexSession(id: file.sessionId, cwd: file.cwd, source: file.source, lastActivity: record.time)
                s.lastActivity = max(s.lastActivity, record.time)
                var usage = s.byModel[record.model] ?? .init()
                usage.tokens = usage.tokens + record.tokens
                if let cost = cost(record) { usage.costUSD += cost } else { usage.unpricedTokens += record.tokens.total }
                s.byModel[record.model] = usage
                state.sessions[file.sessionId] = s
            }
            state.processed[file.sessionId] = file.records.count
            changed = true
        }
        if changed { scheduleSave() }
    }

    // MARK: Cost

    /// Price of one response at the current list price. Nil when the model is not in the table.
    private func cost(_ r: CodexUsageRecord) -> Double? {
        guard let price = pricing.price(for: r.model) else { return nil }
        let rates = r.isLongContext ? price.long : price.short
        let t = r.tokens
        // Assumption: cache writes are part of input, like cached input.
        let uncached = max(0, t.input - t.cachedInput - t.cacheWrite)
        return (uncached * rates.input + t.cachedInput * rates.cachedInput
                + t.cacheWrite * rates.cacheWrite + t.output * rates.output) / 1_000_000
    }

    var unpricedModels: [String] {
        Set(sessions.flatMap { s in s.byModel.filter { $0.value.unpricedTokens > 0 }.keys }).sorted()
    }

    var totalCost: Double { sessions.reduce(0) { $0 + $1.costUSD } }
    var totalTokens: Double { sessions.reduce(0) { $0 + $1.totalTokens } }

    func isActive(_ s: CodexSession) -> Bool { Date().timeIntervalSince(s.lastActivity) < Activity.window }

    // MARK: Persistence

    private func loadState() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: stateFile),
           let saved = try? JSONDecoder().decode(CodexState.self, from: data) {
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
        try? data.write(to: stateFile, options: .atomic)
    }

    // MARK: Pricing updates

    private func loadCachedPricing() {
        guard let text = try? String(contentsOf: pricingFile, encoding: .utf8),
              let parsed = OpenAIPricing.parse(markdown: text) else { return }
        pricing = parsed
        if let date = (try? pricingFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            pricingDate = Format.dayKey(date)
        }
    }

    private var pricingFetchedAt: Date? {
        (try? pricingFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func updatePricingIfStale() {
        guard autoUpdatePricing, isRunning else { return }
        if let at = pricingFetchedAt, Date().timeIntervalSince(at) < Self.pricingMaxAge { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < 60 * 60 { return }
        updatePricingNow()
    }

    private var lastAttempt: Date?

    /// Downloads the official pricing page. Sends no usage data; it is a plain GET of a public page.
    func updatePricingNow() {
        guard isRunning else { return }
        lastAttempt = Date()
        let url = OpenAIPricing.sourceURL
        let file = pricingFile
        Task.detached {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let text = String(data: data, encoding: .utf8),
                      let parsed = OpenAIPricing.parse(markdown: text) else {
                    throw URLError(.cannotParseResponse)
                }
                try data.write(to: file, options: .atomic)
                await MainActor.run { [weak self] in
                    guard self?.isRunning == true else { return }
                    self?.pricing = parsed
                    self?.pricingDate = Format.dayKey(Date())
                    self?.pricingError = nil
                }
            } catch {
                await MainActor.run { [weak self] in self?.pricingError = error.localizedDescription }
            }
        }
    }
}
