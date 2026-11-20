#!/bin/bash
# Checks TopLayer's hooks against the real Claude Code on this Mac.
#
#   Scripts/check-claude.sh            run every check
#   Scripts/check-claude.sh --keep     also keep the scratch folder, to look at what Claude sent
#
# The tests (Scripts/test.sh) check TopLayer against what Claude Code is documented to
# send. This runs Claude Code itself, a few short turns, and checks that it still sends
# and accepts what the hooks rely on: after a Claude Code update, run it before trusting
# the overlay again.
#
# What it checks:
#   1. a headless run is not held up by the hook that waits for your replies, and its
#      finished turn reaches the event log, with the fields the overlay reads
#   2. a permission prompt reaches the hook, and Allow lets the command run
#   3. Deny stops the command
#   4. a question (AskUserQuestion) reaches the hook, and the answer written back is the
#      one Claude gets. Skipped while Claude Code keeps that tool from headless runs.
#
# What it leaves alone:
#   - Your Claude settings are not read or changed. The hooks are given to each run with
#     --settings, and your own settings (hooks included) are left out with --setting-sources.
#   - Your ~/.toplayer is not used. The hooks work in a scratch folder (TOPLAYER_HOME),
#     which is removed at the end.
#   - The runs are not saved as sessions, and the overlay does not list them.
# It does use your Claude login and a little of your plan: four short turns on a small
# model, well under a cent in all.
#
# Run it from your own terminal. Started from inside a Claude session it would run as
# that session's child, which is not what your own sessions are.
set -uo pipefail
cd "$(dirname "$0")/.."
repo="$(pwd)"

keep=false
[ "${1:-}" = "--keep" ] && keep=true
model="${TOPLAYER_CHECK_MODEL:-haiku}"
wait_seconds="${TOPLAYER_CHECK_WAIT:-180}"

command -v claude >/dev/null || { echo "claude is not on your PATH." >&2; exit 2; }
[ -x /usr/bin/python3 ] || { echo "/usr/bin/python3 is missing (it comes with Xcode's command line tools)." >&2; exit 2; }
if [ -n "${CLAUDECODE:-}${CLAUDE_CODE_CHILD_SESSION:-}" ]; then
  echo "This shell belongs to a Claude session. Run Scripts/check-claude.sh from your own terminal." >&2
  exit 2
fi

# The folder's name is how the overlay knows these runs are not threads of yours.
work="$(mktemp -d "${TMPDIR:-/tmp}/toplayer-check.XXXXXX")"
top="$work/toplayer"
project="$work/project"
seen="$work/requests"
mkdir -p "$top/permissions" "$project" "$seen"
responder=""
cleanup() {
  [ -n "$responder" ] && kill "$responder" 2>/dev/null
  # Listeners the hook left waiting for replies in the scratch folder.
  for pidfile in "$top"/inbox/*/listener.pid; do
    [ -f "$pidfile" ] && kill "$(cat "$pidfile")" 2>/dev/null
  done
  if $keep; then echo "Kept: $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

# The same entries TopLayer registers (ClaudeHooks.wanted in Sources/TopLayer/Setup.swift),
# pointing at this checkout's scripts.
/usr/bin/python3 - "$repo/Hooks" > "$work/settings.json" <<'EOF'
import json, sys
hook = sys.argv[1] + "/toplayer-hook.sh"
rewake = {"type": "command", "command": hook, "asyncRewake": True, "timeout": 604800}
background = {"type": "command", "command": hook, "async": True}
ask = {"type": "command", "command": sys.argv[1] + "/toplayer-permission.sh", "timeout": 330}
events = {"Stop": rewake, "SessionStart": rewake, "UserPromptSubmit": rewake, "PostToolUse": rewake,
          "Notification": background, "SessionEnd": background, "PermissionRequest": ask}
print(json.dumps({"hooks": {name: [{"hooks": [entry]}] for name, entry in events.items()}}))
EOF

# Stands in for the overlay: keeps the heartbeat fresh and answers what the permission
# hook asks, the way the overlay does, by writing a decision file next to the request.
#   $1 = allow | deny | answer:<label>
respond() {
  while :; do
    touch "$top/overlay.alive"
    for request in "$top"/permissions/*.json; do
      [ -f "$request" ] || continue
      decision="${request%.json}.decision"
      [ -f "$decision" ] && continue
      cp "$request" "$seen/$(basename "$request")"
      case "$1" in
        answer:*) /usr/bin/python3 "$work/answer.py" "$request" "${1#answer:}" > "$decision.tmp" ;;
        *) printf '%s' "$1" > "$decision.tmp" ;;
      esac
      mv "$decision.tmp" "$decision"
    done
    sleep 0.2
  done
}

# What the overlay writes for a question: the whole reply Claude Code documents for
# this hook, with the original input and the answers keyed by each question's text.
# (ClaudeBridge.questionReply builds the same thing.) Anything that is not a question
# is denied.
cat > "$work/answer.py" <<'EOF'
import json, sys
request = json.load(open(sys.argv[1]))
tool_input = request.get("tool_input") or {}
questions = tool_input.get("questions") or []
if request.get("tool_name") != "AskUserQuestion" or not questions:
    print("deny")
    sys.exit(0)
answers = {q["question"]: sys.argv[2] for q in questions}
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {
    "behavior": "allow", "updatedInput": dict(tool_input, answers=answers)}}}, separators=(",", ":")))
EOF

# Runs one turn. $1 = name, $2 = how to answer the hook, $3 = prompt, the rest = extra flags.
run() {
  local name="$1" mode="$2" prompt="$3"
  shift 3
  rm -f "$seen"/*.json
  respond "$mode" &
  responder=$!
  ( cd "$project" && TOPLAYER_HOME="$top" TOPLAYER_PERMISSION_WAIT=60 claude -p "$prompt" \
      --model "$model" --output-format json --max-turns 6 --no-session-persistence --strict-mcp-config \
      --setting-sources project,local --settings "$work/settings.json" "$@" \
      < /dev/null > "$work/$name.json" 2> "$work/$name.err" ) &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$wait_seconds" ]; then kill "$pid" 2>/dev/null; echo "    (stopped after $wait_seconds seconds)"; break; fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null
  kill "$responder" 2>/dev/null
  wait "$responder" 2>/dev/null
  responder=""
}

failures=0
skipped=0
ok() { echo "  ok       $1"; }
fail() { echo "  FAILED   $1"; failures=$((failures + 1)); }
skip() { echo "  skipped  $1"; skipped=$((skipped + 1)); }
# check "<what>" <python expression over: result, events, requests, text>
check() {
  local what="$1" name="$2" expression="$3"
  if /usr/bin/python3 - "$work/$name.json" "$top/events.jsonl" "$seen" "$expression" <<'EOF'
import glob, json, os, sys
def load(path):
    try: return json.load(open(path))
    except Exception: return {}
result = load(sys.argv[1])
session = result.get("session_id", "")
text = result.get("result") or ""
events = []
if os.path.exists(sys.argv[2]):
    for line in open(sys.argv[2]):
        try: event = json.loads(line)
        except Exception: continue
        if event.get("session_id") == session: events.append(event)
stops = [e for e in events if e.get("hook_event_name") == "Stop"]
requests = [load(p) for p in sorted(glob.glob(sys.argv[3] + "/*.json"))]
sys.exit(0 if eval(sys.argv[4]) else 1)
EOF
  then ok "$what"; else fail "$what"; fi
}

echo "Claude Code $(claude --version 2>/dev/null), model $model"

echo "1. A finished turn"
run turn allow "Reply with exactly this and nothing else: toplayer-check-ok"
check "the reply listener did not hold the run up" turn 'session != ""'
check "Claude answered" turn '"toplayer-check-ok" in text'
check "the turn's end reached the event log" turn 'len(stops) >= 1'
check "it carries Claude's last message" turn 'any("toplayer-check-ok" in (e.get("last_assistant_message") or "") for e in stops)'
check "it lists background work (how the overlay tells a real finish)" turn 'all(isinstance(e.get("background_tasks"), list) for e in stops) and len(stops) >= 1'
check "the session's start reached the event log" turn 'any(e.get("hook_event_name") == "SessionStart" for e in events)'
session="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("session_id",""))' "$work/turn.json" 2>/dev/null)"
if [ -n "$session" ] && grep -qs "$session" "$HOME/.toplayer/events.jsonl"; then
  fail "your own hooks stayed out of it"
  echo "Your real TopLayer hooks ran for this check as well, so the remaining checks would put"
  echo "prompts in your real overlay. Stopping here."
  exit 1
else
  ok "your own hooks stayed out of it"
fi

echo "2. A permission prompt, allowed"
run allow allow "Use the Bash tool to run exactly this command: touch allowed.txt
Then reply with exactly: done"
check "the prompt reached the hook" allow 'any(r.get("tool_name") == "Bash" and "allowed.txt" in (r.get("tool_input") or {}).get("command", "") for r in requests)'
check "it names its session" allow 'all(r.get("session_id") == session for r in requests) and len(requests) >= 1'
if [ -f "$project/allowed.txt" ]; then ok "Allow let the command run"; else fail "Allow let the command run"; fi

echo "3. A permission prompt, denied"
run deny deny "Use the Bash tool to run exactly this command: touch denied.txt
If you are not allowed to, reply with exactly: refused"
check "the prompt reached the hook" deny 'any("denied.txt" in (r.get("tool_input") or {}).get("command", "") for r in requests)'
if [ -f "$project/denied.txt" ]; then fail "Deny stopped the command"; else ok "Deny stopped the command"; fi

echo "4. A question"
# Claude Code 2.1 does not give a headless run the question tool, so this one is skipped
# there and questions are checked by hand (ask Claude to ask you two questions, and
# answer them in the overlay). It runs by itself if a later version does offer the tool.
run question "answer:Amber" "Use the AskUserQuestion tool to ask me exactly one question, \"Which colour?\", with header \"Colour\" and two options labelled \"Teal\" and \"Amber\". Then reply with exactly: chosen=<the label I picked>
If you do not have that tool, reply with exactly: no-question-tool"
if grep -qs "no-question-tool" "$work/question.json" || ! ls "$seen"/*.json >/dev/null 2>&1; then
  skip "Claude Code gives a headless run no question tool. Check questions by hand, in the overlay"
else
  check "the question reached the hook, with its options" question 'any(r.get("tool_name") == "AskUserQuestion" and [o.get("label") for o in r["tool_input"]["questions"][0]["options"]][:2] == ["Teal", "Amber"] for r in requests)'
  check "it says whether several answers are allowed" question 'any("multiSelect" in q for r in requests for q in (r.get("tool_input") or {}).get("questions", []))'
  check "Claude got the answer written back" question '"chosen=Amber" in text'
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures failed. Run again with --keep to look at what Claude sent."
  exit 1
fi
[ "$skipped" -gt 0 ] && echo "All that ran passed; $skipped skipped." || echo "All passed."
