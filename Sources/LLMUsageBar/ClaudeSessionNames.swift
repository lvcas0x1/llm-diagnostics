import Foundation

/// Best-effort lookup of a human-readable name for a local session ID.
/// Reads files Claude Code writes on this Mac; their formats are undocumented,
/// so every failure falls back to nil.
enum ClaudeSessionNames {
    struct Info { let name: String?; let cwd: String? }

    static func configDirs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            dirs.append(URL(fileURLWithPath: env))
        }
        dirs.append(home.appendingPathComponent(".claude"))
        dirs.append(home.appendingPathComponent(".config/claude"))
        var seen = Set<String>()
        return dirs.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    static func lookup(sessionId: String) -> Info? {
        let fm = FileManager.default
        for dir in configDirs() {
            // Live sessions: <config>/sessions/<pid>.json with sessionId, name, cwd.
            let sessions = dir.appendingPathComponent("sessions")
            for file in (try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      obj["sessionId"] as? String == sessionId else { continue }
                return Info(name: obj["name"] as? String, cwd: obj["cwd"] as? String)
            }
            // Transcripts: <config>/projects/<project>/<sessionId>.jsonl, lines carry "cwd".
            let projects = dir.appendingPathComponent("projects")
            for project in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
                let transcript = project.appendingPathComponent(sessionId + ".jsonl")
                guard let handle = try? FileHandle(forReadingFrom: transcript) else { continue }
                defer { try? handle.close() }
                let head = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
                for line in head.split(separator: UInt8(ascii: "\n")) {
                    if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                       let cwd = obj["cwd"] as? String {
                        return Info(name: nil, cwd: cwd)
                    }
                }
                return Info(name: nil, cwd: nil)
            }
        }
        return nil
    }
}
