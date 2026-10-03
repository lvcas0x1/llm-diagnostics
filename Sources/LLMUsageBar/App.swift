import AppKit
import SwiftUI

@main
struct LLMUsageBarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            UsagePanel()
                .environmentObject(model)
                .environmentObject(model.claude)
                .environmentObject(model.codex)
                .environmentObject(model.copilot)
        } label: {
            MenuBarLabel(model: model, claude: model.claude, codex: model.codex, copilot: model.copilot)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppModel: ObservableObject {
    let claude = ClaudeStore()
    let codex = CodexStore()
    let copilot = CopilotStore()
    private var server: OTLPServer!

    @Published var showSettings = false
    @Published var expandedSessions: Set<String> = []
    /// Measured height of the session list content, used to size its scroll view.
    @Published var sessionListHeight: CGFloat = 0
    /// Measured height of the whole panel, used to size its window.
    @Published var panelHeight: CGFloat = 0
    @AppStorage("port") var port: Int = 4318 { didSet { restart() } }
    @Published private(set) var claudeEnabled = Source.claude.isEnabled
    @Published private(set) var codexEnabled = Source.codex.isEnabled
    @Published private(set) var copilotEnabled = Source.copilot.isEnabled

    var anyEnabled: Bool { claudeEnabled || codexEnabled || copilotEnabled }

    var totalTokens: Double {
        (claudeEnabled ? claude.totalTokens(.all) : 0) + (codexEnabled ? codex.totalTokens : 0)
            + (copilotEnabled ? copilot.totalTokens : 0)
    }

    var totalCost: Double {
        (claudeEnabled ? claude.totalCost(.all) : 0) + (codexEnabled ? codex.totalCost : 0)
            + (copilotEnabled ? copilot.totalCost : 0)
    }

    init() {
        let claude = claude, copilot = copilot
        server = OTLPServer(
            onPoints: { points in Task { @MainActor in claude.ingest(points) } },
            onSpans: { spans in Task { @MainActor in copilot.ingest(spans) } },
            onState: { state in Task { @MainActor in claude.serverState = state } }
        )
        // Open Settings on first use, when nothing is collected yet.
        showSettings = !anyEnabled
        // A provider that is off reads its state file once to close a period left open.
        if claudeEnabled { claude.setRunning(true) } else { claude.closeOpenPeriod() }
        if copilotEnabled { copilot.setRunning(true) } else { copilot.closeOpenPeriod() }
        restart()
        if codexEnabled { codex.setRunning(true) } else { codex.closeOpenPeriod() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [codex] _ in
            MainActor.assumeIsolated {
                claude.saveNow()
                codex.saveNow()
                copilot.saveNow()
            }
        }
    }

    /// The OTLP receiver runs while Claude Code or Copilot CLI is collected, and parses
    /// only the payloads of the providers that are on.
    func restart() {
        if claudeEnabled || copilotEnabled {
            server.start(port: UInt16(clamping: port), metrics: claudeEnabled, traces: copilotEnabled)
        } else {
            server.stop()
        }
    }

    func setEnabled(_ source: Source, _ on: Bool) {
        source.setEnabled(on)
        switch source {
        case .claude:
            claudeEnabled = source.isEnabled
            claude.setRunning(claudeEnabled)
            restart()
        case .codex:
            codexEnabled = source.isEnabled
            codex.setRunning(codexEnabled)
        case .copilot:
            copilotEnabled = source.isEnabled
            copilot.setRunning(copilotEnabled)
            restart()
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var claude: ClaudeStore
    @ObservedObject var codex: CodexStore
    @ObservedObject var copilot: CopilotStore

    var body: some View {
        Text("\(Format.kTokens(model.totalTokens)) / \(Format.usd(model.totalCost))")
            .monospacedDigit()
    }
}
