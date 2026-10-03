import Foundation

/// Token counts in OpenAI usage terms. `input` includes `cachedInput` (observed: total = input + output).
struct CodexTokens: Codable, Sendable {
    var input: Double = 0
    var cachedInput: Double = 0
    var cacheWrite: Double = 0
    var output: Double = 0

    var total: Double { input + output }

    static func + (a: Self, b: Self) -> Self {
        Self(input: a.input + b.input, cachedInput: a.cachedInput + b.cachedInput,
             cacheWrite: a.cacheWrite + b.cacheWrite, output: a.output + b.output)
    }
}

/// One API response's usage as recorded in a rollout file.
struct CodexUsageRecord: Sendable {
    let time: Date
    let model: String
    let tokens: CodexTokens

    var isLongContext: Bool { tokens.input > Double(OpenAIPricing.longContextThreshold) }
}

/// Usage records of one CLI session file, in file order.
struct CodexFile: Sendable {
    let sessionId: String
    let cwd: String?
    let source: String
    let mtime: Date
    let records: [CodexUsageRecord]
}

/// Reads Codex CLI session rollouts under `$CODEX_HOME/sessions` and `archived_sessions`.
/// The rollout format is undocumented; this parses records as observed in codex-cli 0.159:
/// `session_meta`, `turn_context` (model), and per-response `token_usage_record`.
/// Files without `token_usage_record` fall back to deltas of `event_msg`/`token_count` totals,
/// which were observed to miss some responses.
final class CodexScanner: @unchecked Sendable {
    /// Only sessions run by the CLI binary, by `session_meta.originator`: the interactive TUI
    /// ("codex-tui") and `codex exec` ("codex_exec"). `source` is not used because a TUI started
    /// in the VS Code terminal is recorded as source "vscode" (observed in codex-cli 0.159-0.160).
    static let cliOriginators: Set<String> = ["codex-tui", "codex_exec"]

    private struct CacheEntry { let mtime: Date; let size: Int; let file: CodexFile? }
    private var cache: [String: CacheEntry] = [:]
    private let queue = DispatchQueue(label: "LLMUsageBar.CodexScanner")

    static func codexHome() -> URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"] { return URL(fileURLWithPath: env) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// Lists CLI session files. Unchanged files (same mtime and size) are not re-read.
    func scan(completion: @escaping @Sendable ([CodexFile]) -> Void) {
        queue.async { [self] in
            let home = Self.codexHome().resolvingSymlinksInPath()
            let fm = FileManager.default
            var seen = Set<String>()
            var result: [CodexFile] = []
            for dir in ["sessions", "archived_sessions"] {
                let root = home.appendingPathComponent(dir)
                guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
                else { continue }
                for case let url as URL in walker where url.pathExtension == "jsonl" {
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    let mtime = values?.contentModificationDate ?? .distantPast
                    let size = values?.fileSize ?? 0
                    let key = url.path
                    seen.insert(key)
                    if let hit = cache[key], hit.mtime == mtime, hit.size == size {
                        if let f = hit.file { result.append(f) }
                        continue
                    }
                    let file = Self.parse(url, mtime: mtime)
                    cache[key] = CacheEntry(mtime: mtime, size: size, file: file)
                    if let file { result.append(file) }
                }
            }
            cache = cache.filter { seen.contains($0.key) }
            completion(result)
        }
    }

    static func parse(_ url: URL, mtime: Date) -> CodexFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let isoFraction = ISO8601DateFormatter()
        isoFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoSeconds = ISO8601DateFormatter()
        isoSeconds.formatOptions = [.withInternetDateTime]
        func date(_ s: String) -> Date? { isoFraction.date(from: s) ?? isoSeconds.date(from: s) }
        var id: String?
        var cwd: String?
        var source: String?
        var originator: String?
        var model = "unknown"
        var previous = CodexTokens()
        var countRecords: [CodexUsageRecord] = []
        var usageRecords: [CodexUsageRecord] = []

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = obj["type"] as? String,
                  let payload = obj["payload"] as? [String: Any] else { continue }
            let time = (obj["timestamp"] as? String).flatMap(date) ?? mtime
            switch type {
            case "session_meta":
                id = id ?? payload["id"] as? String
                cwd = cwd ?? payload["cwd"] as? String
                source = source ?? payload["source"] as? String
                originator = originator ?? payload["originator"] as? String
            case "turn_context":
                if let m = payload["model"] as? String { model = m }
            case "token_usage_record":
                guard let usage = (payload["usage"] as? [String: Any]).map(tokens), usage.total > 0 else { continue }
                usageRecords.append(CodexUsageRecord(time: time, model: model, tokens: usage))
            case "event_msg" where payload["type"] as? String == "token_count":
                guard let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any] else { continue }
                let now = tokens(total)
                let last = (info["last_token_usage"] as? [String: Any]).map(tokens) ?? CodexTokens()
                var delta = CodexTokens(input: now.input - previous.input,
                                        cachedInput: now.cachedInput - previous.cachedInput,
                                        cacheWrite: now.cacheWrite - previous.cacheWrite,
                                        output: now.output - previous.output)
                // A running total that goes down was reset; count this request's usage instead.
                if delta.input < 0 || delta.output < 0 || delta.cachedInput < 0 || delta.cacheWrite < 0 { delta = last }
                previous = now
                guard delta.total > 0 else { continue }
                countRecords.append(CodexUsageRecord(time: time, model: model, tokens: delta))
            default:
                continue
            }
        }
        guard let id, let originator, cliOriginators.contains(originator) else { return nil }
        return CodexFile(sessionId: id, cwd: cwd, source: source ?? originator, mtime: mtime,
                         records: usageRecords.isEmpty ? countRecords : usageRecords)
    }

    private static func tokens(_ d: [String: Any]) -> CodexTokens {
        func n(_ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
        return CodexTokens(input: n("input_tokens"), cachedInput: n("cached_input_tokens"),
                           cacheWrite: n("cache_write_input_tokens"), output: n("output_tokens"))
    }
}
