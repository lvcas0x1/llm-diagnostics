# LLM Usage Bar

Native macOS menu bar app (SwiftUI `MenuBarExtra`) that shows token usage and estimated API
cost per session for Claude Code, the Codex CLI, and the GitHub Copilot CLI.

- Menu bar: `<tokens>k / $<cost>`, the total of all enabled providers since collection started
  (or since the provider's last reset).
- Panel: the same total, then one section per enabled provider in the order Claude Code, Codex,
  GitHub Copilot CLI. Each section shows its subtotal and its sessions, most recent first.
  A session row is `name - $cost`; clicking it expands one line per model with its token count.
  A green dot marks a session with usage in the last 3 minutes.
- Costs are estimates, not bills. See each provider below.

## Settings

| Setting | Effect |
| - | - |
| Collect Claude Code / Collect Codex / Collect GitHub Copilot CLI | Turns each provider on or off. All are off by default. While all are off, Settings opens automatically at launch. |
| Port | Port of the local receiver for Claude Code and Copilot (default 4318). |
| Copy local settings.json env block | Copies the Claude Code `env` block below, with the current port. |
| Update OpenAI prices daily | Daily download of the OpenAI price table while Codex is on (default on). |
| Update prices now | Downloads the OpenAI price table immediately (Codex on only). |
| Reset Claude Code / Reset Codex / Reset Copilot | Sets that provider to 0 immediately, without confirmation; counting restarts from that moment. |

Settings are stored in `~/Library/Preferences/local.llm-usage-bar.plist` (`claude`, `codex`,
`copilot`: 1 = on, 0 = off; `port`; `openAIPricingAutoUpdate`) and survive app and Mac restarts.

### What runs while a provider is off

- Claude Code off: `/v1/metrics` payloads are not parsed; no timer. Telemetry sent meanwhile is
  not recorded.
- Copilot off: `/v1/traces` payloads are not parsed; no timer.
- The receiver port is shared by Claude Code and Copilot; it is closed only when both are off.
- Codex off: no file scanning, no timer, no price download, the cached price table is not read.
- At launch, each provider that is off reads its state file once, and writes it only to close
  a collection period left open (when it was turned off while the app was not running).

## Accumulation and reset

Usage accumulates from the moment a provider is turned on; usage from before is not counted.
Each provider records the periods when it was on:

| Data | Counted when | Re-sent or re-read data |
| - | - | - |
| Claude Code delta point | its interval (`startTimeUnixNano`..`timeUnixNano`) lies inside one period | ignored: keyed by series (session, resource and point attributes, start time) and end time, kept 7 days |
| Claude Code cumulative point | the increase since the previous reading, if both readings are inside one period. The first reading of a series counts in full only if the series (the Claude Code process) started inside the period; otherwise it is only a baseline | a reading not newer than the last one, or lower within the same series, is ignored |
| Copilot CLI span | its start and end lie inside one period | ignored: keyed by span ID, kept 7 days |
| Codex record | its timestamp lies inside a period | each record is processed once (processed count per session) |

- OTLP delivery is at-least-once ("may result in duplicate data on the server side",
  https://opentelemetry.io/docs/specs/otlp/). Claude Code delta points and Copilot spans older
  than 7 days cannot be checked for duplicates and are not counted.
- Not counted by design: a Claude Code export interval or a Copilot span that started before
  collection was turned on (for Claude Code at most one export interval, 60 seconds by default),
  and a Claude Code cumulative increase spanning an off period.
- Totals persist across app and Mac restarts. Codex usage while the app is not running but Codex
  is on is picked up at the next launch; Claude Code and Copilot telemetry sent while the app is
  not running is lost.

Data files, in `~/Library/Application Support/LLMUsageBar/`:

| File | Content |
| - | - |
| `claude-state.json` | Claude Code totals per session and model, collection periods, cumulative-series readings, recent keys |
| `codex-state.json` | Codex totals per session and model, collection periods, processed counts |
| `copilot-state.json` | Copilot totals per session and model, AI units, collection periods, recent span IDs |
| `openai-pricing.md` | Downloaded OpenAI price table |

Claude Code and Copilot data are added when received. Codex files are scanned every 60 seconds.
The green dot is re-evaluated every 60 seconds.

## Claude Code

Claude Code exports OpenTelemetry metrics. The app receives OTLP/HTTP JSON on `127.0.0.1:<port>`
and aggregates two metrics per `session.id` and `model`:

| Metric | Used for |
| - | - |
| `claude_code.token.usage` (attribute `type`: input, output, cacheRead, cacheCreation) | Tokens: the sum of all four types |
| `claude_code.cost.usage` | Cost: Claude Code's own estimate in USD |

Source: https://code.claude.com/docs/en/monitoring-usage

- Delta (the default) and cumulative temporality are both handled.
- Claude Code computes the cost from token counts at list price, unless an administrator sets
  `modelPricing` in managed settings. On a Pro/Max subscription or Amazon Bedrock it is the
  API-list-price equivalent, not what you are billed. Source: https://code.claude.com/docs/en/costs
- Session name: the `cc.label` attribute if set; otherwise, for a session on this Mac, the name or
  working directory from `sessions/*.json` or `projects/*/<session-id>.jsonl` in `~/.claude`,
  `~/.config/claude`, or `$CLAUDE_CONFIG_DIR` (undocumented formats, best effort); otherwise the
  first 8 characters of the session ID.
- Only `http/json` is supported: `http/protobuf` and compressed bodies get HTTP 415; gRPC is not supported.
- Requests with a malformed, negative, or oversized `Content-Length` or chunk size, or a body over
  16 MB, get HTTP 400.

### Configure local sessions

Add to `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`), then start new sessions;
running sessions do not pick it up. OTel variables in a repository's `.claude/settings.json` or
`.claude/settings.local.json` are ignored by design
(https://code.claude.com/docs/en/settings-reference#variables-claude-code-ignores-in-env).

```json
"env": {
  "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
  "OTEL_METRICS_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL": "http/json",
  "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "http://127.0.0.1:4318/v1/metrics",
  "OTEL_METRIC_EXPORT_INTERVAL": "60000"
}
```

`OTEL_METRIC_EXPORT_INTERVAL` is in milliseconds; 60000 is the default.

### Configure dev containers

Add to `.devcontainer/devcontainer.json` and rebuild the container. With Podman use
`host.containers.internal` instead of `host.docker.internal`.

```json
"containerEnv": {
  "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
  "OTEL_METRICS_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL": "http/json",
  "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "http://host.docker.internal:4318/v1/metrics",
  "OTEL_METRIC_EXPORT_INTERVAL": "60000",
  "OTEL_RESOURCE_ATTRIBUTES": "cc.label=${localWorkspaceFolderBasename}-devcontainer"
}
```

- `host.docker.internal`: https://docs.docker.com/desktop/features/networking/networking-how-tos/
- `host.containers.internal`: https://docs.podman.io/en/latest/markdown/podman-run.1.html
- Not verified: whether a container can reach the app, which listens on `127.0.0.1` only.
- An egress firewall in the container (such as the reference `init-firewall.sh`) must allow the
  host address and port.
- These variables replace any other OTel collector the container was sending to.

## Codex CLI

The app reads Codex CLI session files; Codex needs no configuration. Not supported: Codex inside
dev containers (its files are not on the Mac).

- Record time: the line's `timestamp` (RFC 3339, with or without fractional seconds); the file's
  modification time if it is missing or unreadable.
- Files: `$CODEX_HOME/sessions/**/*.jsonl` and `$CODEX_HOME/archived_sessions/**/*.jsonl`
  (`CODEX_HOME` defaults to `~/.codex`). Only changed files are re-read.
- CLI sessions only, by `session_meta.originator`: `codex-tui` (interactive) or `codex_exec`
  (`codex exec`). `source` is not used, because a CLI session in the VS Code terminal is recorded
  as `source: "vscode"`.
- Tokens: per-response `token_usage_record.usage`, input + output. Input includes cached input
  (observed: `total_tokens` = input + output).
  Files without it fall back to deltas of `token_count.total_token_usage`. The file format is
  undocumented (observed in codex-cli 0.159–0.160).
- Cost: OpenAI API list price, Standard tier, fixed when each record is added.
  Source: https://developers.openai.com/api/docs/pricing
  - Short or long context per request: long when its input exceeds 272K tokens.
  - Uncached input, cached input, and output at their rates. Assumption: cache-write tokens are
    part of input and priced at the cache-write rate.
  - A copy of the price table from 2026-10-03 is built in. While Codex is on and daily update is
    on, the app downloads `https://developers.openai.com/api/docs/pricing.md` when the cached copy
    is older than 24 hours (at most one attempt per hour). This is the app's only outbound request;
    it sends no usage data.
  - Tokens of models missing from the table are counted, excluded from the cost, and the model
    is listed in the panel.
  - Not reflected: Batch/Flex/Fast tiers, the regional processing uplift, ChatGPT plan billing.

## GitHub Copilot CLI

Copilot CLI exports OpenTelemetry traces (`http/json` by default). The app reads usage from
traces on `/v1/traces`. Source:
https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference#opentelemetry-monitoring

| Span | Attributes used |
| - | - |
| `chat` (one per LLM request) | `gen_ai.conversation.id` (session), `gen_ai.response.model` (or `gen_ai.request.model`), `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens` |
| `invoke_agent` with `server.address` (top-level only) | `gen_ai.conversation.id`, `github.copilot.nano_aiu` |

- Tokens: input + output. Per the OTel GenAI conventions, input tokens include cached tokens
  (https://github.com/open-telemetry/semantic-conventions-genai).
- Cost: AI units from top-level `invoke_agent` spans only (GitHub: summing every span
  double-counts) × $0.01. GitHub states "1 AI credit = $0.01 USD"
  (https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing).
  **Assumption (not stated by GitHub):** one OTel AI unit equals one AI credit. Check against the
  AI credits that `/usage` shows in Copilot CLI. Usage inside a plan's monthly allowance is shown
  at the same rate.
- Session name: `cc.label` from `OTEL_RESOURCE_ATTRIBUTES` if set, otherwise the first 8
  characters of the session ID.
- **Not verified with a real Copilot CLI**: tested only with OTLP payloads built from the documented
  span and attribute names.

### Configure Copilot CLI

Setting `OTEL_EXPORTER_OTLP_ENDPOINT` enables Copilot CLI's OTel export. To limit it to Copilot,
add a shell function to `~/.zshrc`:

```sh
copilot() {
  OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 \
  OTEL_RESOURCE_ATTRIBUTES="cc.label=${PWD##*/}" \
  command copilot "$@"
}
```

Per the OTel specification, `/v1/traces` is appended to this base URL for traces
(https://opentelemetry.io/docs/specs/otel/protocol/exporter/). In a dev container, use
`http://host.docker.internal:4318` (Docker) or `http://host.containers.internal:4318` (Podman).

## Build

Requires macOS 14+ and the Swift toolchain (Command Line Tools are enough; Xcode is not needed).

```sh
./scripts/build-app.sh      # builds build/LLMUsageBar.app (ad-hoc signed)
open build/LLMUsageBar.app
```

To start at login: System Settings > General > Login Items > Open at Login > `+` >
`build/LLMUsageBar.app`. The build is for the Mac's own architecture; release DMGs are Apple Silicon only.

## Release

`.github/workflows/release.yml` runs on every push to `main`, except pushes that change only
Markdown files (`paths-ignore: '**.md'`), and manually from the Actions tab:

1. On a GitHub-hosted `macos-26` runner: runs `scripts/test.sh`.
2. Builds the app for Apple Silicon (arm64, macOS 14 or later) with `scripts/build-app.sh`.
   Version from `scripts/next-version.sh`: `Resources/Info.plist`'s major.minor, with the patch one
   above the highest released `v<major>.<minor>.<patch>` (never below Info.plist's patch). The first
   release is Info.plist's version, `0.0.1`; then `0.0.2`, `0.0.3`, … To start `0.1.x`, set
   Info.plist to `0.1.0`.
3. Packages it with `scripts/make-dmg.sh` as `LLMUsageBar-<version>.dmg` (app + Applications link):
   `diskutil image create from`, compressed read-only (ULFO), APFS volume. `hdiutil` is not used;
   it prints a deprecation warning on macOS 27.
4. Publishes a GitHub release `v<version>` with the DMG attached, using the preinstalled `gh` CLI
   and the workflow's `GITHUB_TOKEN` (`contents: write` for this job only).

The app is ad-hoc signed and not notarized (that needs an Apple Developer ID). On first launch,
macOS blocks it: open System Settings > Privacy & Security and click "Open Anyway"
(https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac).

Local equivalent:

```sh
APP_VERSION=0.1.0 ./scripts/build-app.sh
./scripts/make-dmg.sh 0.1.0      # -> build/LLMUsageBar-0.1.0.dmg
```

## Tests

```sh
./scripts/test.sh          # unit, integration, and regression tests, 45 tests, about 2 seconds
./scripts/system-test.sh   # end-to-end test of the built app, 20 checks, about 2 minutes
./scripts/ui-test.sh       # UI test of the menu bar panel, 10 checks, about 30 seconds
```

| Level | Covers |
| - | - |
| Regression (`Tests/LLMUsageBarTests/RegressionTests.swift`) | Reported defects: negative/oversized/non-numeric `Content-Length` and chunk sizes, series keys for resource-level session IDs, Codex timestamps without fractional seconds (plus integration tests for out-of-order cumulative readings and colliding sessions) |
| Unit (`Tests/LLMUsageBarTests/UnitTests.swift`) | OTLP metrics and trace parsing, HTTP request parsing (Content-Length, chunked, pipelined), OpenAI price table parsing, Codex file parsing, collection periods, recent keys, formatting |
| Integration (`Tests/LLMUsageBarTests/IntegrationTests.swift`) | Each provider's store with files in a temporary directory: accumulation, cumulative series, exclusion of usage from before collection and from off periods, de-duplication of re-sent data, Codex pricing, reset, persistence, providers that are off; the receiver over a real socket, routing by provider, toggling providers with open connections |
| System (`scripts/system-test.sh`) | A copy of the built app (bundle ID `local.llm-usage-bar.systemtest`, port 4319, temporary data directory and `CODEX_HOME`): all-off defaults, all providers on, restart persistence, providers off, no price download while Codex is off |
| UI (`scripts/ui-test.sh`) | A copy of the app (bundle ID `local.llm-usage-bar.uitest`, port 4319) opened with a real mouse click: Settings shown/hidden, a session expanded/collapsed, closed and reopened; after each step the window height must match the content and the top edge must not move. Screenshots in `build/ui-test/` |

- `scripts/test.sh` passes the Swift Testing macro plugin path, which Command Line Tools keep
  outside the default search path; plain `swift test` does not compile the tests.
- Tests use `LLM_USAGE_BAR_SUPPORT_DIR` (data directory) and `CODEX_HOME`, so real data is not
  touched. The system test downloads the OpenAI price table once. Claude Code session-name lookup
  reads the real `~/.claude` read-only.
- The UI test needs Accessibility and Screen & System Audio Recording permission for the terminal
  app that runs it, and the menu bar item must be visible (not behind the notch, the frontmost
  app's menus, or a menu bar organizer); otherwise it stops after the first step. It quits the
  real app while running and relaunches it afterwards; Claude Code and Copilot telemetry sent
  during that time is lost.
