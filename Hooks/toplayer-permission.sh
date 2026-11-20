#!/bin/bash
# TopLayer permission hook for Claude Code, registered on PermissionRequest.
#
# When Claude asks for permission (run a command, edit a file), this hands the
# request to the TopLayer overlay and waits for you to click Allow or Deny there.
# A question Claude asks you (its AskUserQuestion tool) arrives the same way; for
# those the overlay writes out the whole answer, and this prints it as it is.
#
# It gets out of the way whenever the overlay can't answer:
#   - overlay not running (no fresh heartbeat)      -> exit at once
#   - you click "Ask in Claude" in the overlay      -> exit
#   - no answer within the wait window              -> exit
# Exiting with no output leaves the decision to Claude's normal permission prompt.
#
# Note: while this hook is waiting, the Claude app has not shown its own prompt
# yet, so the overlay is the only place to answer until the wait ends.

# TOPLAYER_HOME moves it, for Scripts/check-claude.sh, which must not touch the real one.
ROOT="${TOPLAYER_HOME:-$HOME/.toplayer}"
PERM="$ROOT/permissions"
HEARTBEAT="$ROOT/overlay.alive"
WAIT_SECONDS="${TOPLAYER_PERMISSION_WAIT:-300}"

input=$(cat)

overlay_alive() {
  [ -f "$HEARTBEAT" ] || return 1
  [ $(( $(date +%s) - $(stat -f %m "$HEARTBEAT") )) -le 15 ]
}
overlay_alive || exit 0

sid=$(printf '%s' "$input" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
  | /usr/bin/sed 's/^[^:]*:[[:space:]]*"\(.*\)"$/\1/')
case "$sid" in ""|*[!A-Za-z0-9-]*) exit 0 ;; esac

mkdir -p "$PERM" && chmod 700 "$ROOT" "$PERM" 2>/dev/null
id="$sid.$(date +%s)-$$"
request="$PERM/$id.json"
answer="$PERM/$id.decision"
printf '%s' "$input" > "$request.tmp" && mv "$request.tmp" "$request"
cleanup() { rm -f "$request" "$answer"; }
trap cleanup EXIT

deadline=$(( $(date +%s) + WAIT_SECONDS ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -f "$answer" ]; then
    decision="$(cat "$answer")"
    case "$decision" in
      \{*)
        # Your answers to a question, as the complete reply Claude Code expects.
        printf '%s\n' "$decision"
        ;;
      allow)
        echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
        ;;
      deny)
        echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied by the user from their TopLayer overlay."}}}'
        ;;
    esac
    exit 0
  fi
  overlay_alive || exit 0
  sleep 0.3
done
exit 0
