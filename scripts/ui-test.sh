#!/bin/zsh
# UI test of the menu bar panel: opens it with a real mouse click, toggles Settings and a session
# row, and checks the window size and top edge after each step. Screenshots go to build/ui-test/.
#
# Needs, for the terminal app that runs this script (System Settings > Privacy & Security):
#   Accessibility (to read the window frame) and Screen & System Audio Recording (screenshots).
#
# Uses a copy of the app with its own bundle ID, data directory, and port 4319. The real app is
# quit during the test (only one "LLMUsageBar" process can be driven by name) and relaunched after.
set -uo pipefail
cd "$(dirname "$0")/.."

DOMAIN=local.llm-usage-bar.uitest
PORT=4319
APP=build/LLMUsageBarUITest.app
OUT=build/ui-test
TMP=$(mktemp -d)
CLICK=build/click
PID=""
pass=0; fail=0
real_was_running=false
pgrep -x LLMUsageBar >/dev/null && real_was_running=true

check() {
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then echo "  PASS  $desc"; ((pass++)); else echo "  FAIL  $desc"; ((fail++)); fi
}
cleanup() {
    [[ -n "$PID" ]] && kill "$PID" 2>/dev/null && while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
    defaults delete $DOMAIN >/dev/null 2>&1
    rm -rf "$TMP" "$APP"
    $real_was_running && open build/LLMUsageBar.app
}
trap cleanup EXIT

frame() {  # prints "x y w h" of the panel window, or nothing when closed
    osascript -e 'tell application "System Events" to tell process "LLMUsageBar" to if (count of windows) > 0 then get {position of window 1, size of window 1}' 2>/dev/null | tr -d ' ' | tr ',' ' '
}
step() {  # step name: records frame into X Y W H and saves a screenshot
    sleep 1.2
    local f; f=$(frame)
    read -r X Y W H <<< "$f"
    echo "  $1: ${f:-closed}"
    [[ -n "$f" ]] && screencapture -x -R $((X - 10)),$((Y - 10)),$((W + 20)),$((H + 20)) "$OUT/$1.png"
}

echo "== Prepare"
./scripts/build-app.sh >/dev/null || { echo "build failed"; exit 1; }
swiftc -O scripts/support/click.swift -o $CLICK || exit 1
rm -rf "$APP" "$OUT"; mkdir -p "$OUT"
cp -R build/LLMUsageBar.app "$APP"
plutil -replace CFBundleIdentifier -string $DOMAIN "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1
defaults delete $DOMAIN >/dev/null 2>&1
defaults write $DOMAIN port -int $PORT
defaults write $DOMAIN claude -int 1
pkill -x LLMUsageBar; while pgrep -x LLMUsageBar >/dev/null; do sleep 0.2; done
LLM_USAGE_BAR_SUPPORT_DIR="$TMP" CODEX_HOME="$TMP/codex" "$APP/Contents/MacOS/LLMUsageBar" >/dev/null 2>&1 &
PID=$!
sleep 3
# One Claude Code session with two models, so there is a row to expand.
for m in claude-opus-5-5 claude-haiku-4-5; do
    curl -s -o /dev/null -X POST -H 'Content-Type: application/json' "http://127.0.0.1:$PORT/v1/metrics" -d "{\"resourceMetrics\":[{\"scopeMetrics\":[{\"metrics\":[{\"name\":\"claude_code.token.usage\",\"sum\":{\"aggregationTemporality\":1,\"dataPoints\":[{\"attributes\":[{\"key\":\"session.id\",\"value\":{\"stringValue\":\"ui-1\"}},{\"key\":\"model\",\"value\":{\"stringValue\":\"$m\"}},{\"key\":\"type\",\"value\":{\"stringValue\":\"input\"}}],\"asDouble\":1000}]}}]}]}]}"
done
# The longer label can make macOS collapse the menu bar items; leave time to expand them first.
sleep 2
item=$(osascript -e 'tell application "System Events" to tell process "LLMUsageBar" to get position of menu bar item 1 of menu bar 2' 2>/dev/null | tr -d ' ')
[[ -z "$item" ]] && { echo "Cannot read the menu bar item: grant Accessibility to this terminal app."; exit 1; }
ITEM_X=$(( ${item%,*} + 40 ))

echo "== Steps"
$CLICK $ITEM_X 19; step 1-open;          OPEN_H=$H; TOP=$Y
if [[ -z "$OPEN_H" ]]; then
    echo "  FAIL  panel did not open: the menu bar item is probably hidden (behind the notch,"
    echo "        under the frontmost app's menus, or collapsed by a menu bar organizer)."
    echo "        Make the item visible and run again."
    exit 1
fi
check "panel opened" test -n "$OPEN_H"
check "screenshot captured (Screen Recording granted)" test -s "$OUT/1-open.png"
$CLICK $((X + 45)) $((Y + H - 22)); step 2-settings
check "Settings: taller, same top" test -n "$H" -a "$H" -gt "$OPEN_H" -a "$Y" = "$TOP"
$CLICK $((X + 60)) $((Y + H - 22)); step 3-hidden
check "Hide settings: back to open height, same top" test -n "$H" -a "$H" = "$OPEN_H" -a "$Y" = "$TOP"
$CLICK $((X + 17)) $((Y + 132)); step 4-expanded
check "Expand session: taller, same top" test -n "$H" -a "$H" -gt "$OPEN_H" -a "$Y" = "$TOP"
EXP_H=$H
$CLICK $((X + 45)) $((Y + H - 22)); step 5-expanded-settings
check "Settings while expanded: taller, same top" test -n "$H" -a "$H" -gt "$EXP_H" -a "$Y" = "$TOP"
$CLICK $((X + 60)) $((Y + H - 22)); step 6-expanded-hidden
check "Hide while expanded: back to expanded height" test -n "$H" -a "$H" = "$EXP_H" -a "$Y" = "$TOP"
$CLICK $((X + 17)) $((Y + 132)); step 7-collapsed
check "Collapse: back to open height" test -n "$H" -a "$H" = "$OPEN_H" -a "$Y" = "$TOP"
$CLICK 20 600; sleep 0.8
check "click outside closes the panel" test -z "$(frame)"
$CLICK $ITEM_X 19; step 8-reopen
check "Reopen: open height, same top" test -n "$H" -a "$H" = "$OPEN_H" -a "$Y" = "$TOP"
$CLICK 20 600

echo
echo "Screenshots: $OUT"
echo "Result: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
