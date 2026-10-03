# LLM Usage Bar — developer notes

Specification, internals, build, release, and tests. For installing and setting up the app, see
[README.md](README.md).

Native macOS menu bar app (SwiftUI `MenuBarExtra`, macOS 14+) that shows token usage and estimated
API cost per session for Claude Code, the Codex CLI, and GitHub Copilot (CLI and VS Code Chat).

- Menu bar: `<tokens> / $<cost>` (tokens with a unit, e.g. `80.9M / $29.25`; the panel uses the same format), the total of all enabled providers since collection started
  (or since the provider's last reset).
- Panel: the same total, then one section per enabled provider in the order Claude Code, Codex,
  GitHub Copilot CLI. Each section shows its subtotal and its 3 most recent sessions; `… N more`
  shows the rest and `Show less` hides them again. The panel fits its content; the session list
  scrolls only when expanded sections exceed 420pt.
  A session row is `name - <tokens> / $<cost>`; clicking it expands one line per model with its
  token count. A name too long for the panel's width is cut with `…` (the totals stay visible; the
  tooltip shows the full name).
  A green dot marks a session with usage in the last 3 minutes.
- Costs are estimates, not bills. See each provider below.

## Source layout

| File | Role |
| - | - |
| `Sources/LLMUsageBar/App.swift` | App entry, `AppModel` (provider on/off, receiver lifecycle, totals), menu bar label |
| `Sources/LLMUsageBar/UsagePanel.swift` | Panel UI: totals, provider sections, session rows, Settings |
| `Sources/LLMUsageBar/PanelWindowSizer.swift` | Sizes the panel window to its content with a fixed top edge |
| `Sources/LLMUsageBar/Config.swift` | `Source`: which providers are on (user defaults) |
| `Sources/LLMUsageBar/Common.swift` | Data directory, refresh constants, collection periods, recent-key de-duplication |
| `Sources/LLMUsageBar/OTLPServer.swift` | Local HTTP/1.1 OTLP receiver, request routing, request log, HTTP parser |
| `Sources/LLMUsageBar/OTLPParser.swift` | Claude Code metrics (OTLP/JSON) |
| `Sources/LLMUsageBar/OTLPProtobuf.swift` | Protobuf wire reader and OTLP trace decoder |
| `Sources/LLMUsageBar/ClaudeStore.swift` | Claude Code accumulation and persistence; formatting helpers |
| `Sources/LLMUsageBar/ClaudeSessionNames.swift` | Names for local Claude Code sessions |
| `Sources/LLMUsageBar/CopilotStore.swift` | Copilot trace parsing (JSON/protobuf), accumulation, persistence |
| `Sources/LLMUsageBar/CodexScanner.swift` | Codex rollout file reader |
| `Sources/LLMUsageBar/CodexStore.swift` | Codex accumulation, pricing, price table download, persistence |
| `Sources/LLMUsageBar/OpenAIPricing.swift` | OpenAI price table (bundled copy and parser) |
| `Resources/Info.plist` | Bundle ID `local.llm-usage-bar`, version, `LSUIElement` (no Dock icon) |
| `scripts/` | Build, DMG, version, and test scripts; `scripts/support/` holds UI-test helpers |
| `Tests/LLMUsageBarTests/` | Unit, integration, regression, and protobuf tests (Swift Testing) |
| `.github/workflows/release.yml` | Release workflow |

## Settings

| Setting | Effect |
| - | - |
| Collect Claude Code / Collect Codex / Collect GitHub Copilot CLI | Turns each provider on or off. All are off by default. While all are off, Settings opens automatically at launch. |
| Port | Port of the local receiver for Claude Code and Copilot (default 4318). If you change it, use the same port in the Claude Code and Copilot CLI settings below. |
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
| Copilot `chat` span | its start and end lie inside one period | ignored: keyed by span ID (case-insensitive, as OTLP/JSON hex IDs are; saved IDs are lower-cased on load), kept 7 days |
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
| `claude-state.json` | Claude Code totals per session and model, collection periods, cumulative-series readings, recent keys, `formatVersion` (2). State without a version (saved by v0.0.1 or earlier builds) is upgraded on load: its cumulative readings are matched to a series by the current key or the older key without session/resource attributes and moved to the current key on first sight (even if that reading is a stale re-send), so the next increase continues from them |
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
- Claude Code metrics: only `http/json`; `http/protobuf` and compressed bodies get HTTP 415. gRPC
  is not supported. (Protobuf is accepted only for Copilot traces, see below.)
- Requests with a malformed, negative, or oversized `Content-Length` or chunk size, chunk data not
  followed by CRLF, or a body over 16 MB, get HTTP 400.

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
  "OTEL_EXPORTER_OTLP_ENDPOINT": "http://host.docker.internal:4318",
  "OTEL_RESOURCE_ATTRIBUTES": "cc.label=${localWorkspaceFolderBasename}-devcontainer"
}
```

- `OTEL_EXPORTER_OTLP_ENDPOINT` also covers Copilot CLI run inside the container (traces).
- Reachability check from inside the container; `{}` means the app answered:
  `curl -s -X POST -H 'Content-Type: application/json' -d '{}' http://host.docker.internal:4318/v1/metrics`
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

Copilot CLI and the Copilot SDK behind VS Code's Chat export OpenTelemetry traces as `http/json`.
The app reads usage from traces on `/v1/traces` in JSON or protobuf (`application/x-protobuf`);
sessions from both appear in the "GitHub Copilot CLI" section. Source:
https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference#opentelemetry-monitoring

Protobuf bodies are decoded with a built-in reader for the OTLP trace messages
(`ExportTraceServiceRequest` → `ResourceSpans` → `ScopeSpans` → `Span`, `KeyValue`, `AnyValue`;
field numbers from opentelemetry-proto). Unknown fields are skipped; malformed bodies (including
varints longer than 64 bits) get HTTP 400.
The reply to a protobuf request is an empty `ExportTraceServiceResponse` (`application/x-protobuf`).

| Span | Attributes used |
| - | - |
| `chat` (one per LLM request) | `gen_ai.conversation.id` (session), `gen_ai.response.model` (or `gen_ai.request.model`), `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `github.copilot.nano_aiu` |

Other spans (`invoke_agent`, `execute_tool`, VS Code's own spans) are ignored.

- Tokens: input + output. Per the OTel GenAI conventions, input tokens include cached tokens
  (https://github.com/open-telemetry/semantic-conventions-genai).
- Cost: the `chat` spans' AI units, summed, × $0.01. GitHub's reference warns that summing the
  attribute "across every span double-counts" and points to the top-level `invoke_agent`; which
  span is top-level differs by host (Copilot CLI: no parent; VS Code: under its own span), while
  each `chat` span carries its own request's units. Observed: the chat spans' sum equals the
  top-level `invoke_agent` value (Copilot CLI, 2 requests: 155,944,000) and the sum of all
  `invoke_agent` values (VS Code, 18 requests in 4 invocations: 4.19123 AIU). GitHub states "1 AI credit = $0.01 USD"
  (https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing). GitHub does
  not state that one OTel AI unit is one AI credit; observed with Copilot CLI 1.0.91, the span's
  `nano_aiu` matched the "AI Credits" the CLI printed (220,880,000 nano AIU = "AI Credits 0.22").
  Usage inside a plan's monthly allowance is shown at the same rate.
- Session name: `cc.label` from `OTEL_RESOURCE_ATTRIBUTES` if set, otherwise the first 8
  characters of the session ID.
- Verified with Copilot CLI 1.0.91: tokens and AI units in the app matched the CLI's own summary
  (`AI Credits 0.09`, `↑ 12.2k (8.3k cached) • ↓ 5`). Verified with VS Code Chat as described below.

### Configure Copilot CLI

Setting `OTEL_EXPORTER_OTLP_ENDPOINT` enables Copilot CLI's OTel export (`http/json` by default).
To limit it to Copilot, add this shell function to `~/.zshrc`, then open a new terminal; the
session name in the panel is the current folder name:

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

### Configure Copilot in VS Code

VS Code's current Chat (Agent mode) runs on the Copilot SDK in VS Code's agent host. The SDK sends
usage only when the OTel environment variables are set; the `github.copilot.chat.otel.*` settings
do not affect it (observed).

When VS Code is started from the Dock or a launcher, it runs your shell startup files once to
read the environment (https://code.visualstudio.com/docs/supporting/faq). Add this to `~/.zshrc`
so only that run sets the variables, then quit VS Code (Cmd+Q) and start it again:

```sh
# Only while VS Code reads the shell environment at startup: send Copilot usage to LLM Usage Bar.
if [[ -n "$VSCODE_RESOLVING_ENVIRONMENT" ]]; then
  export OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
  export OTEL_RESOURCE_ATTRIBUTES=cc.label=vscode
fi
```

- `VSCODE_RESOLVING_ENVIRONMENT` is set by VS Code during that run; it is not in VS Code's
  documentation (source: https://github.com/pingdotgg/t3code/pull/13952). Your regular terminals
  are not affected.
- Verified: VS Code started from the Dock with this setting sent Chat usage (tokens and AI units);
  its sessions appear in the "GitHub Copilot CLI" section, named `vscode`.
- VS Code's integrated terminal inherits these variables, so `copilot` run there is collected too.
- Alternative without editing `~/.zshrc`: start VS Code from a terminal with
  `open -a "Visual Studio Code" --env OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 --env OTEL_RESOURCE_ATTRIBUTES=cc.label=vscode`.
- The SDK sends OTLP/JSON. VS Code's own `github.copilot.chat.otel.*` exporter
  (https://code.visualstudio.com/docs/agents/guides/monitoring-agents) sends `http/protobuf` by
  default; the app accepts that too, but in testing it carried no `chat` spans with usage.

## Diagnostics: request log

Start the app with `LLM_USAGE_BAR_REQUEST_LOG` to append one line per received request (time, method,
path, content type, user agent, body size, what was parsed, response status). For traces it also
lists each span's attribute names and the values the app reads (the session ID only as `<set>`);
prompt and response content is never written. Off by default.

```sh
open --env LLM_USAGE_BAR_REQUEST_LOG="$HOME/Library/Logs/LLMUsageBar-requests.tsv" build/LLMUsageBar.app
```

## Build

Requires macOS 14+ and the Swift toolchain (Command Line Tools are enough; Xcode is not needed).

```sh
./scripts/build-app.sh      # builds build/LLMUsageBar.app (ad-hoc signed)
open build/LLMUsageBar.app
```

To start at login: System Settings > General > Login Items > Open at Login > `+` >
`build/LLMUsageBar.app`. The build is for the Mac's own architecture; release DMGs are Apple Silicon only.

## Release

`.github/workflows/release.yml` runs on a push to `main` only when the push changes at least one
file that affects the app or its packaging: `Sources/**`, `Resources/**`, `Package.swift`,
`Package.resolved`, `scripts/build-app.sh`, `scripts/make-dmg.sh`, `scripts/next-version.sh`, or the
workflow itself. Pushes that change only the README, tests, test scripts, or `.gitignore` do not
build. It can also be run manually from the Actions tab:

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
./scripts/test.sh          # unit, integration, and regression tests, 61 tests, about 2 seconds
./scripts/system-test.sh   # end-to-end test of the built app, 20 checks, about 2 minutes
./scripts/ui-test.sh       # UI test of the menu bar panel, 10 checks, about 30 seconds
./scripts/real-app-test.sh # every Settings control on the installed app, 64 checks, about 2 minutes
```

| Level | Covers |
| - | - |
| Regression (`Tests/LLMUsageBarTests/RegressionTests.swift`) | Reported defects: negative/oversized/non-numeric `Content-Length` and chunk sizes, series keys for resource-level session IDs, Codex timestamps without fractional seconds, Copilot AI units from `chat` spans whatever the parents (VS Code's wrapped `invoke_agent`), multiple chat spans adding up, chunk data not ending in CRLF, protobuf varints over 64 bits, span IDs differing only in case (plus integration tests for HTTP requests pipelined on one connection, out-of-order cumulative readings, colliding sessions, and cumulative series saved by v0.0.1 or unversioned state) |
| Protobuf (`Tests/LLMUsageBarTests/ProtobufTests.swift`) | OTLP protobuf trace decoding against a payload encoded by the official `opentelemetry-proto` package, equivalence with the JSON path, truncated and malformed bodies, unknown fields and negative integers; the receiver accepting protobuf traces (200, empty protobuf reply), ignoring them while Copilot is off, rejecting malformed ones (400), and unchanged JSON and metrics behavior |
| Unit (`Tests/LLMUsageBarTests/UnitTests.swift`) | OTLP metrics and trace parsing, HTTP request parsing (Content-Length, chunked, pipelined), OpenAI price table parsing, Codex file parsing, collection periods, recent keys, formatting |
| Integration (`Tests/LLMUsageBarTests/IntegrationTests.swift`) | Each provider's store with files in a temporary directory: accumulation, cumulative series, exclusion of usage from before collection and from off periods, de-duplication of re-sent data, Codex pricing, reset, persistence, providers that are off; the receiver over a real socket, routing by provider, toggling providers with open connections |
| System (`scripts/system-test.sh`) | A copy of the built app (bundle ID `local.llm-usage-bar.systemtest`, port 4319, temporary data directory and `CODEX_HOME`): all-off defaults, all providers on, restart persistence, providers off, no price download while Codex is off |
| Functional, real app (`scripts/real-app-test.sh`) | The installed app (`/Applications/LLMUsageBar.app` by default) through its panel: Settings/Hide settings, expand/collapse, each Collect toggle alone and combined (receiver open/closed, payloads recorded or ignored, sections shown/hidden, `0 / $0` when all off, price controls disabled while Codex is off), Port change 4318→4320→4318 (listening port and green status text), price auto-update toggle, Update prices now, each Reset alone (others untouched), Quit and relaunch (settings and data persist). Backs up and restores the data directory and preferences; telemetry received during the test is not kept |
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
