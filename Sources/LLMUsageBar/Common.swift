import Foundation

enum AppSupport {
    /// `~/Library/Application Support/LLMUsageBar`, created on first use.
    /// `LLM_USAGE_BAR_SUPPORT_DIR` replaces it, so tests never touch real data.
    static var directory: URL {
        let dir = ProcessInfo.processInfo.environment["LLM_USAGE_BAR_SUPPORT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LLMUsageBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

enum Activity {
    /// A session counts as active when it reported usage within this window.
    static let window: TimeInterval = 3 * 60
    /// How often providers refresh: Codex file scans and the active-session indicator.
    static let refreshInterval: TimeInterval = 60
}

/// A span of time during which a provider was being collected.
struct CollectionPeriod: Codable {
    var start: Date
    var end: Date?

    func contains(_ t: Date) -> Bool { t >= start && (end.map { t <= $0 } ?? true) }
}

extension Array where Element == CollectionPeriod {
    /// True when the usage interval [start, end] lies inside a single collection period, so usage
    /// from before collection started (or from while it was off) is never counted. A missing
    /// start checks the end only.
    func covers(start: Date?, end: Date) -> Bool {
        contains { $0.contains(end) && (start.map($0.contains) ?? true) }
    }

    var isOpen: Bool { last.map { $0.end == nil } ?? false }

    mutating func open(at date: Date = Date()) {
        if !isOpen { append(CollectionPeriod(start: date)) }
    }

    /// Returns true when a period was open and is now closed.
    @discardableResult
    mutating func close(at date: Date = Date()) -> Bool {
        guard isOpen else { return false }
        self[count - 1].end = date
        return true
    }
}

/// Keys of recently counted data, kept for a fixed time window instead of a fixed count, so a
/// re-sent export (OTLP delivery is at-least-once) is never counted twice within the window.
/// Data older than the window cannot be checked and is not counted.
struct RecentKeys: Codable {
    static let window: TimeInterval = 7 * 24 * 60 * 60

    private(set) var seen: [String: Date] = [:]

    /// Returns true and remembers the key when the data is new and inside the window.
    mutating func insertIfNew(_ key: String, time: Date, now: Date = Date()) -> Bool {
        guard time >= now.addingTimeInterval(-Self.window), seen[key] == nil else { return false }
        seen[key] = time
        return true
    }

    mutating func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.window)
        seen = seen.filter { $0.value >= cutoff }
    }
}
