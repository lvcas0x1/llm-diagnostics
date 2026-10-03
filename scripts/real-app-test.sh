#!/bin/zsh
# Functional test of the installed app through its real panel: presses every control in Settings,
# alone and in combination, and checks the effect (preferences, data files, receiver port,
# panel contents, menu bar label).
#
# Data safety: the data directory and the preferences are backed up first and restored at the
# end (the app is quit, restored, and relaunched). Claude Code and Copilot telemetry received
# during the test is therefore not kept.
#
# Needs Accessibility permission for the terminal app. Usage: scripts/real-app-test.sh [app path]
set -uo pipefail
cd "$(dirname "$0")/.."

APP=${1:-/Applications/LLMUsageBar.app}
DOMAIN=local.llm-usage-bar
SUP="$HOME/Library/Application Support/LLMUsageBar"
AX=build/ax; CLICK=build/click
mkdir -p build
swiftc -O scripts/support/ax.swift -o $AX || exit 1
swiftc -O scripts/support/click.swift -o $CLICK || exit 1

pid_of() { pgrep -f "^$APP/Contents/MacOS/LLMUsageBar" | head -1; }
PID=$(pid_of)
[[ -z "$PID" ]] && { echo "$APP is not running"; exit 1; }

pass=0; fail=0
check() {  # check "description" command...
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then echo "  PASS  $desc"; ((pass++)); else echo "  FAIL  $desc"; ((fail++)); fi
}
eq() { [[ "$1" == "$2" ]]; }
pref() { defaults read $DOMAIN "$1" 2>/dev/null; }
http_code() { curl -s -o /dev/null -m 3 -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d "${2:-{\}}" "http://127.0.0.1:$1${3:-/v1/metrics}"; }
listening() { lsof -nP -a -p "$PID" -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
json() {  # json <file> <python expression over d>
    python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" "$SUP/$1" 2>/dev/null
}
json_num() {  # json_num <file> <expression> <expected numbers, comma-separated>: numeric comparison
    python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
v = $2
v = v if isinstance(v, tuple) else (v,)
exp = [float(x) for x in sys.argv[2].split(',')]
sys.exit(0 if [round(float(x), 8) for x in v] == [round(x, 8) for x in exp] else 1)
" "$SUP/$1" "$3" 2>/dev/null
}
press() { $AX press $PID "$1"; sleep 1.2; }
# Presses a checkbox and waits until its value actually flips (one retry), then gives the provider
# time to start/stop and save.
toggle() {
    local before; before=$($AX value $PID "$1")
    for attempt in 1 2; do
        $AX press $PID "$1"
        for _ in {1..10}; do
            [[ "$($AX value $PID "$1")" != "$before" ]] && { sleep 1.5; return 0; }
            sleep 0.3
        done
    done
    echo "  (toggle '$1' did not change)"; return 1
}
has() { $AX hastext $PID "$1"; }
not_has() { ! $AX hastext $PID "$1"; }
enabled() { [[ "$($AX enabled $PID "$1")" == "$2" ]]; }
nanos() { python3 -c "import time; print(int(time.time() * 1e9))"; }
until_ok() {  # until_ok <command...>: retries for up to 5 seconds (the panel updates asynchronously)
    for _ in {1..10}; do "$@" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1
}
model_rows() { $AX tree $PID | grep -q "└"; }
no_model_rows() { ! model_rows; }

claude_metrics() {  # one delta point of 1000 input tokens and $0.05 for session "live-test"
    local s=$(nanos) e=$(( $(nanos) + 1000000 ))
    local a='[{"key":"session.id","value":{"stringValue":"live-test"}},{"key":"model","value":{"stringValue":"claude-test"}},{"key":"type","value":{"stringValue":"input"}}]'
    local c='[{"key":"session.id","value":{"stringValue":"live-test"}},{"key":"model","value":{"stringValue":"claude-test"}}]'
    echo "{\"resourceMetrics\":[{\"scopeMetrics\":[{\"metrics\":[{\"name\":\"claude_code.token.usage\",\"sum\":{\"aggregationTemporality\":1,\"dataPoints\":[{\"attributes\":$a,\"startTimeUnixNano\":\"$s\",\"timeUnixNano\":\"$e\",\"asDouble\":1000}]}},{\"name\":\"claude_code.cost.usage\",\"sum\":{\"aggregationTemporality\":1,\"dataPoints\":[{\"attributes\":$c,\"startTimeUnixNano\":\"$s\",\"timeUnixNano\":\"$e\",\"asDouble\":0.05}]}}]}]}]}"
}
copilot_traces() {  # chat 2000+100 tokens with 3 AI units for "cp-live"; the invoke_agent repeats them and must not add
    local s=$(nanos) e=$(( $(nanos) + 1000000 )) id=$RANDOM
    local at() { echo "{\"key\":\"$1\",\"value\":{\"$2\":$3}}"; }
    echo "{\"resourceSpans\":[{\"scopeSpans\":[{\"spans\":[
      {\"spanId\":\"chat$id\",\"startTimeUnixNano\":\"$s\",\"endTimeUnixNano\":\"$e\",\"attributes\":[$(at gen_ai.operation.name stringValue '"chat"'),$(at gen_ai.conversation.id stringValue '"cp-live"'),$(at gen_ai.response.model stringValue '"copilot-test"'),$(at gen_ai.usage.input_tokens intValue '"2000"'),$(at gen_ai.usage.output_tokens intValue '"100"'),$(at github.copilot.nano_aiu intValue '"3000000000"')]},
      {\"spanId\":\"agent$id\",\"startTimeUnixNano\":\"$s\",\"endTimeUnixNano\":\"$e\",\"attributes\":[$(at gen_ai.operation.name stringValue '"invoke_agent"'),$(at gen_ai.conversation.id stringValue '"cp-live"'),$(at server.address stringValue '"api.githubcopilot.com"'),$(at github.copilot.nano_aiu intValue '"3000000000"')]}]}]}]}"
}

# ---- Backup and restore ------------------------------------------------------------------------
BK=$(mktemp -d)
cp -R "$SUP" "$BK/support"
defaults export $DOMAIN "$BK/prefs.plist"
restore() {
    echo "== Restore"
    local p; p=$(pid_of)
    [[ -n "$p" ]] && kill "$p" && while kill -0 "$p" 2>/dev/null; do sleep 0.2; done
    rm -rf "$SUP" && cp -R "$BK/support" "$SUP"
    defaults delete $DOMAIN >/dev/null 2>&1; defaults import $DOMAIN "$BK/prefs.plist"
    open "$APP"
    sleep 3
    PID=$(pid_of)
    echo "  data and preferences restored; app relaunched (pid $PID)"
    rm -rf "$BK"
}
trap restore EXIT

open_panel() {
    $AX hastext $PID "Quit" && return
    read -r MX MY <<< "$($AX menuitem $PID)"
    $CLICK "$MX" "$MY"; sleep 1.2
}
show_settings() { has "Hide settings" || press "Settings"; }

echo "== 0. Start: panel open, Settings shown, every provider on"
open_panel
if ! has "Quit"; then
    echo "  FAIL  panel did not open: the menu bar item is probably hidden (behind the notch,"
    echo "        under the frontmost app's menus, or collapsed by a menu bar organizer)."
    echo "        Make the item visible and run again."
    exit 1
fi
check "panel is open" has "Quit"
show_settings
check "Settings shown" has "Hide settings"
for p in "Collect Claude Code" "Collect Codex" "Collect GitHub Copilot CLI"; do
    [[ "$($AX value $PID "$p")" == 1 ]] || toggle "$p"
done
[[ "$($AX value $PID "Update OpenAI prices daily from developers.openai.com")" == 1 ]] || toggle "Update OpenAI prices daily from developers.openai.com"
check "all providers on" eq "$(pref claude)$(pref codex)$(pref copilot)" 111
check "port 4318 listening" listening 4318

echo "== 1. Settings / Hide settings, expand / collapse"
press "Hide settings"; check "Hide settings -> Settings button, no toggles" eval 'has Settings && not_has "Collect Codex"'
press "Settings";      check "Settings -> toggles shown" has "Collect Codex"
$AX pressprefix $PID "claude-code-diagnostics"; sleep 1
check "expand Claude session -> model rows" until_ok model_rows
$AX pressprefix $PID "claude-code-diagnostics"; sleep 1
check "collapse -> no model rows" until_ok no_model_rows

echo "== 2. Claude Code off (Copilot still on)"
toggle "Collect Claude Code"
check "pref claude = 0" eq "$(pref claude)" 0
check "checkbox off" eq "$($AX value $PID "Collect Claude Code")" 0
check "Claude Code section hidden" until_ok not_has "Claude Code"
check "port stays open for Copilot" listening 4318
check "Claude metrics answered 200" eq "$(http_code 4318 "$(claude_metrics)")" 200
sleep 3
check "... but not recorded" eval '! json claude-state.json "list(d[\"sessions\"])" | grep -q live-test'

echo "== 3. Copilot off too (Claude Code off): receiver closed"
toggle "Collect GitHub Copilot CLI"
check "pref copilot = 0" eq "$(pref copilot)" 0
check "Copilot section hidden" until_ok not_has "GitHub Copilot CLI"
check "port 4318 closed" eval '! listening 4318'
check "requests refused" eq "$(http_code 4318)" 000

echo "== 4. Codex off too: nothing collected"
toggle "Collect Codex"
check "pref codex = 0" eq "$(pref codex)" 0
check "Codex section hidden" until_ok not_has "Codex"
check "empty-state message" until_ok has "Nothing is collected. Turn on a provider in Settings."
check "menu bar shows 0k / \$0" eq "$($AX menutitle $PID)" '0k / $0'
check "'Update prices now' disabled" enabled "Update prices now" 0
check "'Update OpenAI prices daily' disabled" enabled "Update OpenAI prices daily from developers.openai.com" 0

echo "== 5. Codex on"
toggle "Collect Codex"
check "pref codex = 1" eq "$(pref codex)" 1
check "Codex section shown" until_ok has "Codex"
check "'Update prices now' enabled" enabled "Update prices now" 1
check "port still closed (Codex does not use it)" eval '! listening 4318'

echo "== 6. Copilot on: receiver open, traces recorded"
toggle "Collect GitHub Copilot CLI"
check "pref copilot = 1" eq "$(pref copilot)" 1
check "port 4318 listening" listening 4318
sleep 1
check "Copilot traces answered 200" eq "$(http_code 4318 "$(copilot_traces)" /v1/traces)" 200
sleep 3
check "Copilot: 2100 tokens, 3 AI units recorded" json_num copilot-state.json 'sum(t["input"]+t["output"] for t in d["sessions"]["cp-live"]["byModel"].values()), d["sessions"]["cp-live"]["nanoAIU"]/1e9' 2100,3
check "Copilot row shows cp-live - \$0.03" until_ok has 'cp-live - $0.03'

echo "== 7. Claude Code on: metrics recorded"
toggle "Collect Claude Code"
check "pref claude = 1" eq "$(pref claude)" 1
sleep 1
check "Claude metrics answered 200" eq "$(http_code 4318 "$(claude_metrics)")" 200
sleep 3
check "Claude: live-test session with 1000 tokens, \$0.05" json_num claude-state.json 'sum(d["sessions"]["live-test"]["tokens"].values()), d["sessions"]["live-test"]["costUSD"]' 1000,0.05

echo "== 8. Port 4318 -> 4320 -> 4318"
$AX setvalue $PID 4318 4320; sleep 2
check "pref port = 4320" eq "$(pref port)" 4320
check "listening on 4320" listening 4320
check "green status shows :4320" has ":4320"
check "4318 closed" eval '! listening 4318'
$AX setvalue $PID 4318 4318; sleep 2
check "pref port = 4318" eq "$(pref port)" 4318
check "listening on 4318 again" listening 4318
check "green status shows :4318" has ":4318"
check "4320 closed" eval '! listening 4320'

check "no Copy button in Settings" not_has "Copy local settings.json env block"

echo "== 10. Update OpenAI prices daily / Update prices now"
toggle "Update OpenAI prices daily from developers.openai.com"
check "pref openAIPricingAutoUpdate = 0" eq "$(pref openAIPricingAutoUpdate)" 0
toggle "Update OpenAI prices daily from developers.openai.com"
check "pref openAIPricingAutoUpdate = 1" eq "$(pref openAIPricingAutoUpdate)" 1
before=$(stat -f %m "$SUP/openai-pricing.md" 2>/dev/null || echo 0)
sleep 1
press "Update prices now"
for i in {1..20}; do [[ $(stat -f %m "$SUP/openai-pricing.md" 2>/dev/null || echo 0) -gt $before ]] && break; sleep 1; done
check "price table downloaded again" test "$(stat -f %m "$SUP/openai-pricing.md")" -gt "$before"
check "'Prices as of' shows today" has "Prices as of $(date +%Y-%m-%d)"

echo "== 11. Reset one provider at a time"
codex_n=$(json codex-state.json 'len(d["sessions"])')
press "Reset Copilot"; sleep 1
check "Reset Copilot: Copilot empty" eq "$(json copilot-state.json 'len(d["sessions"])')" 0
check "... Claude live-test kept" eq "$(json claude-state.json '"live-test" in d["sessions"]')" True
check "... Codex kept" eq "$(json codex-state.json 'len(d["sessions"])')" "$codex_n"
press "Reset Codex"; sleep 1
check "Reset Codex: Codex empty" eq "$(json codex-state.json 'len(d["sessions"])')" 0
check "... Claude live-test kept" eq "$(json claude-state.json '"live-test" in d["sessions"]')" True
press "Reset Claude Code"; sleep 1
check "Reset Claude Code: live-test removed" eq "$(json claude-state.json '"live-test" in d["sessions"]')" False
check "after Reset Claude Code, new Claude data is recorded again" eq "$(http_code 4318 "$(claude_metrics)")" 200
sleep 3
check "... live-test back with 1000 tokens" json_num claude-state.json 'sum(d["sessions"]["live-test"]["tokens"].values())' 1000

echo "== 12. Quit and relaunch: settings and data persist"
claude_total=$(json claude-state.json 'sum(sum(s["tokens"].values()) for s in d["sessions"].values())')
press "Quit"; sleep 2
check "Quit: process ended" eval '[[ -z "$(pid_of)" ]]'
check "Quit: port closed" eq "$(http_code 4318)" 000
open "$APP"; sleep 3; PID=$(pid_of)
check "relaunched" test -n "$PID"
check "providers still on" eq "$(pref claude)$(pref codex)$(pref copilot)" 111
check "port 4318 listening" listening 4318
check "Copilot still empty after relaunch" eq "$(json copilot-state.json 'len(d["sessions"])')" 0
check "Claude total kept (>= before quit)" python3 -c "import sys; sys.exit(0 if $(json claude-state.json 'sum(sum(s["tokens"].values()) for s in d["sessions"].values())') >= $claude_total else 1)"

echo
echo "Result: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
