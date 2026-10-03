# LLM Usage Bar

A macOS menu bar app that shows how many tokens your AI coding tools use and what it would cost at
API prices: Claude Code, Codex CLI, GitHub Copilot CLI, and Copilot Chat in VS Code.

- Menu bar: total tokens and cost, for example `80.9M / $29.25`.
- Click it to see each session, and click a session to see tokens per model.
- Costs are estimates at API list prices, not bills. Subscription usage is shown at the same rate.

Requires macOS 14 or later on Apple Silicon.

## Install and start

1. Download `LLMUsageBar-<version>.dmg` from
   [Releases](https://github.com/lvcas0x1/llm-diagnostics/releases), open it, and drag
   **LLMUsageBar** to **Applications**.
2. Open **LLMUsageBar** from Applications. The first time, macOS blocks it because it is not
   notarized: open **System Settings > Privacy & Security** and click **Open Anyway**.
3. The app appears in the menu bar (there is no Dock icon). Click it, and in **Settings** turn on
   the tools you use: **Collect Claude Code**, **Collect Codex**, **Collect GitHub Copilot CLI**.
   Usage is counted from that moment on.
4. Optional: to start it at login, add it in **System Settings > General > Login Items**.

To build it yourself instead: `./scripts/build-app.sh`, then `open build/LLMUsageBar.app`.

## Set up each tool

The app receives usage on `http://127.0.0.1:4318`. If you change **Port** in Settings, use the same
port below. Restart each tool after changing its settings.

### Claude Code

Add to `~/.claude/settings.json`:

```json
"env": {
  "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
  "OTEL_METRICS_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL": "http/json",
  "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "http://127.0.0.1:4318/v1/metrics",
  "OTEL_METRIC_EXPORT_INTERVAL": "60000"
}
```

### Codex CLI

Nothing to set up. The app reads Codex's local session files.

### GitHub Copilot CLI

Add to `~/.zshrc`, then open a new terminal:

```sh
copilot() {
  OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 \
  OTEL_RESOURCE_ATTRIBUTES="cc.label=${PWD##*/}" \
  command copilot "$@"
}
```

### Copilot Chat in VS Code

Add to `~/.zshrc`, then quit VS Code (Cmd+Q) and open it again:

```sh
if [[ -n "$VSCODE_RESOLVING_ENVIRONMENT" ]]; then
  export OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
  export OTEL_RESOURCE_ATTRIBUTES=cc.label=vscode
fi
```

VS Code sessions appear in the Copilot section as `vscode`.

### Dev containers

For Claude Code and Copilot CLI running inside a dev container, add to
`.devcontainer/devcontainer.json` (merge into an existing `containerEnv`), then rebuild the container:

```json
"containerEnv": {
  "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
  "OTEL_METRICS_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL": "http/json",
  "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "http://host.docker.internal:4318/v1/metrics",
  "OTEL_METRIC_EXPORT_INTERVAL": "60000",
  "OTEL_EXPORTER_OTLP_ENDPOINT": "http://host.docker.internal:4318",
  "OTEL_RESOURCE_ATTRIBUTES": "cc.label=${localWorkspaceFolderBasename}-devcontainer"
}
```

With Podman, use `host.containers.internal` instead of `host.docker.internal`. Sessions appear as
`<folder>-devcontainer`. Codex inside a dev container is not collected.

Check from inside the container that the app can be reached (`{}` means it works):

```sh
curl -s -X POST -H 'Content-Type: application/json' -d '{}' http://host.docker.internal:4318/v1/metrics
```

The app listens on `127.0.0.1` only; whether a container can reach it has not been verified.

## Good to know

- Usage sent by Claude Code or Copilot while the app is not running is not counted. Codex usage is
  picked up at the next launch.
- **Reset** buttons in Settings set a tool back to 0 immediately.
- Your data stays on your Mac (`~/Library/Application Support/LLMUsageBar/`). The only network
  request the app makes is downloading OpenAI's public price table while Codex is on.

Developer documentation (how it works, build, release, tests): [README-DEV.md](README-DEV.md).
