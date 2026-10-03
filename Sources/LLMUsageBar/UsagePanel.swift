import AppKit
import SwiftUI

/// One session row, independent of the tool it came from.
struct SessionRowItem: Identifiable {
    let id: String
    let name: String
    let cost: Double?
    let isActive: Bool
    let help: String
    /// Model name and token count, largest first.
    let models: [(name: String, tokens: Double)]

    var tokens: Double { models.reduce(0) { $0 + $1.tokens } }
}

struct UsagePanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var claude: ClaudeStore
    @EnvironmentObject private var codex: CodexStore
    @EnvironmentObject private var copilot: CopilotStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            sessionList
            Divider()
            if model.showSettings { settings; Divider() }
            footer
        }
        .padding(12)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in
            Color.clear.preference(key: PanelHeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(PanelHeightKey.self) { h in
            MainActor.assumeIsolated { model.panelHeight = h }
        }
        .background(PanelWindowSizer(height: model.panelHeight))
        .onAppear {
            claude.refreshNames()
            codex.refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Format.tokens(model.totalTokens)) Token - \(Format.usd(model.totalCost))")
                    .font(.system(size: 20, weight: .semibold)).monospacedDigit()
                Spacer()
                serverBadge
            }
            Text("All time. Claude Code: its own estimate. Codex: OpenAI API list price (Standard, prices as of \(codex.pricingDate)). Copilot: AI units × $0.01 (assumed). Not a billing statement.\(offSources)")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var offSources: String {
        let off = [model.claudeEnabled ? nil : "Claude Code", model.codexEnabled ? nil : "Codex",
                   model.copilotEnabled ? nil : "Copilot"].compactMap { $0 }
        return off.isEmpty ? "" : " Off: " + off.joined(separator: ", ") + "."
    }

    @ViewBuilder private var serverBadge: some View {
        switch claude.serverState {
        case .listening(let port):
            Label(":\(String(port))", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption).foregroundStyle(.green)
        case .failed(let msg):
            Label("error", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red).help(msg)
        case .stopped:
            Label("stopped", systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var claudeRows: [SessionRowItem] {
        claude.sortedSessions.map { s in
            SessionRowItem(
                id: "claude:" + s.id, name: s.displayName, cost: s.costUSD, isActive: claude.isActive(s),
                help: "\(s.origin) · \(s.id)" + (s.cwd.map { "\n\($0)" } ?? ""),
                models: s.modelBreakdown.map { ($0.model, $0.usage.tokens) })
        }
    }

    private var codexRows: [SessionRowItem] {
        codex.sessions.sorted { $0.lastActivity > $1.lastActivity }.map { s in
            SessionRowItem(
                id: "codex:" + s.id, name: s.name, cost: s.costUSD, isActive: codex.isActive(s),
                help: "codex \(s.source) · \(s.id)" + (s.cwd.map { "\n\($0)" } ?? ""),
                models: s.byModel.map { ($0.key, $0.value.tokens.total) }.sorted { $0.1 > $1.1 })
        }
    }

    private var copilotRows: [SessionRowItem] {
        copilot.sessions.sorted { $0.lastSeen > $1.lastSeen }.map { s in
            SessionRowItem(
                id: "copilot:" + s.id, name: s.name, cost: s.costUSD, isActive: copilot.isActive(s),
                help: "copilot · \(s.id)",
                models: s.byModel.map { ($0.key, $0.value.total) }.sorted { $0.1 > $1.1 })
        }
    }

    private static let maxListHeight: CGFloat = 420

    /// Plain content while it fits, so there is no scroll view chrome; a scroll view only when
    /// the measured content is taller than the cap.
    private var sessionList: some View {
        Group {
            if model.sessionListHeight > Self.maxListHeight {
                ScrollView { sessionContent }
                    .frame(height: Self.maxListHeight)
            } else {
                sessionContent
            }
        }
        .onPreferenceChange(ContentHeightKey.self) { h in
            MainActor.assumeIsolated { model.sessionListHeight = h }
        }
    }

    private var sessionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.claudeEnabled {
                SectionHeader(title: "Claude Code", tokens: claude.totalTokens, cost: claude.totalCost)
                if claudeRows.isEmpty {
                    Text("No Claude Code usage since collection started. Telemetry must point at this app (see README).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SessionList(provider: "claude", rows: claudeRows)
            }
            if model.codexEnabled {
                SectionHeader(title: "Codex", tokens: codex.totalTokens, cost: codex.totalCost)
                    .padding(.top, model.claudeEnabled ? 6 : 0)
                if codexRows.isEmpty {
                    Text("No Codex CLI usage since collection started.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SessionList(provider: "codex", rows: codexRows)
                if !codex.unpricedModels.isEmpty {
                    Text("No price for: \(codex.unpricedModels.joined(separator: ", ")) (not counted in cost)")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            if model.copilotEnabled {
                SectionHeader(title: "GitHub Copilot CLI", tokens: copilot.totalTokens, cost: copilot.totalCost)
                    .padding(.top, model.claudeEnabled || model.codexEnabled ? 6 : 0)
                if copilotRows.isEmpty {
                    Text("No Copilot CLI usage since collection started. Telemetry must point at this app (see README).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SessionList(provider: "copilot", rows: copilotRows)
            }
            if !model.anyEnabled {
                Text("Nothing is collected. Turn on a provider in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { g in
            Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
        })
    }

    private func sourceToggle(_ source: Source, _ title: String, isOn: Bool) -> some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { model.setEnabled(source, $0) }))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            sourceToggle(.claude, "Collect Claude Code", isOn: model.claudeEnabled)
            sourceToggle(.codex, "Collect Codex", isOn: model.codexEnabled)
            sourceToggle(.copilot, "Collect GitHub Copilot CLI", isOn: model.copilotEnabled)
            Divider()
            HStack {
                Text("Port")
                TextField("4318", value: $model.port, format: .number.grouping(.never))
                    .frame(width: 70)
            }
            Toggle("Update OpenAI prices daily from developers.openai.com", isOn: $codex.autoUpdatePricing)
                .disabled(!model.codexEnabled)
            HStack {
                Button("Update prices now") { codex.updatePricingNow() }
                    .disabled(!model.codexEnabled)
                Text("Prices as of \(codex.pricingDate)").font(.caption).foregroundStyle(.secondary)
            }
            if let err = codex.pricingError {
                Text("Price update failed: \(err)").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Reset Claude Code", role: .destructive) { claude.reset() }
                Button("Reset Codex", role: .destructive) { codex.reset() }
                Button("Reset Copilot", role: .destructive) { copilot.reset() }
            }
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack {
            Button(model.showSettings ? "Hide settings" : "Settings") { model.showSettings.toggle() }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A provider's sessions: the most recent `collapsedCount` rows, and a row to show or hide the rest.
struct SessionList: View {
    static let collapsedCount = 3

    @EnvironmentObject private var model: AppModel
    let provider: String
    let rows: [SessionRowItem]

    private var showsAll: Bool { model.expandedProviders.contains(provider) }

    var body: some View {
        ForEach(showsAll ? rows : Array(rows.prefix(Self.collapsedCount))) { SessionRow(item: $0) }
        if rows.count > Self.collapsedCount {
            Button {
                if showsAll { model.expandedProviders.remove(provider) } else { model.expandedProviders.insert(provider) }
            } label: {
                Text(showsAll ? "Show less" : "… \(rows.count - Self.collapsedCount) more")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, SessionRow.nameInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
    }
}

struct SectionHeader: View {
    let title: String
    let tokens: Double
    let cost: Double

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Text("\(Format.tokens(tokens)) / \(Format.usd(cost))")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

struct SessionRow: View {
    @EnvironmentObject private var model: AppModel
    let item: SessionRowItem

    // Fixed widths so the model lines start exactly under the session name.
    private static let chevronWidth: CGFloat = 10
    private static let dotWidth: CGFloat = 7
    private static let spacing: CGFloat = 6
    static let nameInset = chevronWidth + dotWidth + spacing * 2

    private var isExpanded: Bool { model.expandedSessions.contains(item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if isExpanded { model.expandedSessions.remove(item.id) }
                else { model.expandedSessions.insert(item.id) }
            } label: {
                HStack(spacing: Self.spacing) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.chevronWidth)
                    Circle()
                        .fill(item.isActive ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: Self.dotWidth, height: Self.dotWidth)
                    // A long name is cut with "…"; the totals after it always stay visible.
                    HStack(spacing: 0) {
                        Text(item.name).lineLimit(1).truncationMode(.tail)
                        Text(" - \(Format.tokens(item.tokens)) / \(item.cost.map(Format.usd) ?? "$?")")
                            .lineLimit(1).fixedSize()
                    }
                    .fontWeight(.medium).monospacedDigit()
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The panel focuses its first button on open; hide that focus ring on session rows.
            .focusEffectDisabled()
            .help("\(item.name)\n\(item.help)")

            if isExpanded {
                ForEach(item.models, id: \.name) { m in
                    HStack(spacing: 0) {
                        Text("└ \(m.name)").lineLimit(1).truncationMode(.tail)
                        Text(" - \(Format.tokens(m.tokens)) Token").lineLimit(1).fixedSize()
                    }
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.leading, Self.nameInset)
            }
        }
    }
}
