#!/bin/zsh
# End-to-end test of the built app. Runs a copy with its own bundle ID (own preferences),
# its own data directory, its own CODEX_HOME, and port 4319, so the real app and data are untouched.
set -uo pipefail
cd "$(dirname "$0")/.."

DOMAIN=local.llm-usage-bar.systemtest
PORT=4319
APP=build/LLMUsageBarSystemTest.app
BIN="$APP/Contents/MacOS/LLMUsageBar"
TMP=$(mktemp -d)
SUP="$TMP/support"
CODEX="$TMP/codex"
PID=""
pass=0; fail=0

check() {  # check "description" command...
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then echo "  PASS  $desc"; ((pass++)); else echo "  FAIL  $desc"; ((fail++)); fi
}
listening() { lsof -nP -a -p "$PID" -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; }
not_listening() { ! listening; }
json_eq() {  # json_eq file python-expression expected: compares numbers, rounded to 8 places
    [[ -f "$1" ]] && python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
v = $2
v = v if isinstance(v, tuple) else (v,)
exp = tuple(float(x) for x in sys.argv[2].strip('()').split(','))
sys.exit(0 if tuple(round(float(x), 8) for x in v) == tuple(round(x, 8) for x in exp) else 1)
" "$1" "$3"
}
cpu_seconds() { ps -o time= -p "$PID" | awk -F: '{print $1 * 60 + $2}'; }
start_app() {
    LLM_USAGE_BAR_SUPPORT_DIR="$SUP" CODEX_HOME="$CODEX" "$BIN" >/dev/null 2>&1 &
    PID=$!
    sleep 3
}
stop_app() {
    [[ -n "$PID" ]] && kill "$PID" 2>/dev/null && while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
    PID=""
}
set_providers() { defaults write $DOMAIN claude -int $1; defaults write $DOMAIN codex -int $2; defaults write $DOMAIN copilot -int $3; }
cleanup() { stop_app; defaults delete $DOMAIN >/dev/null 2>&1; rm -rf "$TMP" "$APP"; }
trap cleanup EXIT

post() {  # post path json -> HTTP status, or 000 when refused
    curl -s -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d "$2" "http://127.0.0.1:$PORT$1"
}
attr() { echo "{\"key\":\"$1\",\"value\":{\"$2\":$3}}"; }
claude_metrics() {  # delta: 1000 input tokens and $0.05 for session sys-1
    local tok="{\"name\":\"claude_code.token.usage\",\"sum\":{\"aggregationTemporality\":1,\"dataPoints\":[{\"attributes\":[$(attr session.id stringValue '"sys-1"'),$(attr model stringValue '"claude-opus-5-5"'),$(attr type stringValue '"input"')],\"asDouble\":1000}]}}"
    local cost="{\"name\":\"claude_code.cost.usage\",\"sum\":{\"aggregationTemporality\":1,\"dataPoints\":[{\"attributes\":[$(attr session.id stringValue '"sys-1"'),$(attr model stringValue '"claude-opus-5-5"')],\"asDouble\":0.05}]}}"
    echo "{\"resourceMetrics\":[{\"scopeMetrics\":[{\"metrics\":[$tok,$cost]}]}]}"
}
copilot_traces() {  # chat 2000+100 tokens with 3 AIU ($0.03); the invoke_agent repeats 3 AIU and must not add
    local chat="{\"spanId\":\"$1-chat\",\"attributes\":[$(attr gen_ai.operation.name stringValue '"chat"'),$(attr gen_ai.conversation.id stringValue '"cp-1"'),$(attr gen_ai.response.model stringValue '"claude-sonnet-5"'),$(attr gen_ai.usage.input_tokens intValue '"2000"'),$(attr gen_ai.usage.output_tokens intValue '"100"'),$(attr github.copilot.nano_aiu intValue '"3000000000"')]}"
    local agent="{\"spanId\":\"$1-agent\",\"attributes\":[$(attr gen_ai.operation.name stringValue '"invoke_agent"'),$(attr gen_ai.conversation.id stringValue '"cp-1"'),$(attr server.address stringValue '"api.githubcopilot.com"'),$(attr github.copilot.nano_aiu intValue '"3000000000"')]}"
    echo "{\"resourceSpans\":[{\"scopeSpans\":[{\"spans\":[$chat,$agent]}]}]}"
}
codex_line() {  # codex_line iso-timestamp input output
    echo "{\"timestamp\":\"$1\",\"type\":\"token_usage_record\",\"payload\":{\"usage\":{\"input_tokens\":$2,\"cached_input_tokens\":0,\"cache_write_input_tokens\":0,\"output_tokens\":$3,\"reasoning_output_tokens\":0,\"total_tokens\":$(($2+$3))}}}"
}
now_iso() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }

echo "== Build test copy"
./scripts/build-app.sh >/dev/null || { echo "build failed"; exit 1; }
rm -rf "$APP"; cp -R build/LLMUsageBar.app "$APP"
plutil -replace CFBundleIdentifier -string $DOMAIN "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1
defaults delete $DOMAIN >/dev/null 2>&1
defaults write $DOMAIN port -int $PORT
mkdir -p "$SUP" "$CODEX/sessions/2026/10/03"
ROLLOUT="$CODEX/sessions/2026/10/03/rollout-system-test.jsonl"
{
    echo '{"timestamp":"2026-10-01T00:00:00.000Z","type":"session_meta","payload":{"id":"cx-1","cwd":"/tmp/sys","source":"cli","originator":"codex-tui"}}'
    echo '{"timestamp":"2026-10-01T00:00:01.000Z","type":"turn_context","payload":{"model":"gpt-6-luna"}}'
    codex_line 2026-10-01T00:00:02.000Z 999000 999   # before collection started: must not count
} > "$ROLLOUT"

echo "== 1. Defaults: every provider off"
start_app
check "no listening port" not_listening
check "Claude metrics refused (port closed)" test "$(post /v1/metrics "$(claude_metrics)")" = 000
sleep 2
check "no data files created" test -z "$(ls "$SUP")"
cpu1=$(cpu_seconds); sleep 10; cpu2=$(cpu_seconds)
check "idle: under 0.05s CPU in 10s (${cpu1}s -> ${cpu2}s)" python3 -c "import sys; sys.exit(0 if $cpu2 - $cpu1 < 0.05 else 1)"
stop_app

echo "== 2. All providers on"
set_providers 1 1 1
start_app
check "listening on $PORT" listening
check "Claude metrics accepted" test "$(post /v1/metrics "$(claude_metrics)")" = 200
check "Copilot traces accepted" test "$(post /v1/traces "$(copilot_traces a)")" = 200
check "Copilot re-sent export accepted" test "$(post /v1/traces "$(copilot_traces a)")" = 200
codex_line "$(now_iso)" 1000 100 >> "$ROLLOUT"
sleep 4
check "Claude: 1000 tokens, \$0.05" json_eq "$SUP/claude-state.json" \
    "sum(sum(s['tokens'].values()) for s in d['sessions'].values()), sum(s['costUSD'] for s in d['sessions'].values())" "(1000.0, 0.05)"
check "Copilot: 2100 tokens, 3 AIU (re-send not double counted)" json_eq "$SUP/copilot-state.json" \
    "sum(t['input']+t['output'] for s in d['sessions'].values() for t in s['byModel'].values()), sum(s['nanoAIU'] for s in d['sessions'].values())/1e9" "(2100.0, 3.0)"
check "OpenAI price table downloaded (Codex on)" test -f "$SUP/openai-pricing.md"
echo "  ...waiting 62s for the next Codex scan"
sleep 62
check "Codex: only the new record, 1100 tokens, \$0.00015" json_eq "$SUP/codex-state.json" \
    "sum(u['tokens']['input']+u['tokens']['output'] for s in d['sessions'].values() for u in s['byModel'].values()), round(sum(u['costUSD'] for s in d['sessions'].values() for u in s['byModel'].values()), 8)" "(1100.0, 0.00015)"
stop_app

echo "== 3. Restart: totals persist"
start_app
check "listening again" listening
sleep 2
check "Claude total unchanged" json_eq "$SUP/claude-state.json" "sum(sum(s['tokens'].values()) for s in d['sessions'].values())" "1000.0"
check "Copilot total unchanged" json_eq "$SUP/copilot-state.json" "sum(s['nanoAIU'] for s in d['sessions'].values())/1e9" "3.0"
check "Codex total unchanged (no recount after restart)" json_eq "$SUP/codex-state.json" \
    "sum(u['tokens']['input']+u['tokens']['output'] for s in d['sessions'].values() for u in s['byModel'].values())" "1100.0"
stop_app

echo "== 4. Claude Code and Copilot off, Codex on"
set_providers 0 1 0
start_app
check "port closed" not_listening
check "Claude metrics refused" test "$(post /v1/metrics "$(claude_metrics)")" = 000
stop_app

echo "== 5. Codex off: no price download, off-period usage excluded later"
set_providers 0 0 0
rm -f "$SUP/openai-pricing.md"
start_app
codex_line "$(now_iso)" 5000 500 >> "$ROLLOUT"   # written while Codex is off
sleep 3
check "no price download while Codex is off" test ! -f "$SUP/openai-pricing.md"
stop_app
set_providers 0 1 0
start_app
sleep 3
check "Codex: off-period record not counted" json_eq "$SUP/codex-state.json" \
    "sum(u['tokens']['input']+u['tokens']['output'] for s in d['sessions'].values() for u in s['byModel'].values())" "1100.0"
stop_app

echo
echo "Result: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
