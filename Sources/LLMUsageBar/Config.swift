import Foundation

/// Sources the app can collect. Each is off until turned on in Settings.
/// The choice is stored in user defaults (`~/Library/Preferences/local.llm-usage-bar.plist`,
/// keys `claude` / `codex` / `copilot`, 1 = collect, 0 = off), so it survives app and Mac restarts.
enum Source: String, CaseIterable {
    case claude, codex, copilot

    var isEnabled: Bool { UserDefaults.standard.integer(forKey: rawValue) == 1 }

    func setEnabled(_ on: Bool) { UserDefaults.standard.set(on ? 1 : 0, forKey: rawValue) }
}
