#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib/compat.sh"

# Check inbox across all teams with cooldown. Skips if last check was < 60 seconds ago.
# Usage: check-inbox.sh <type> <project_path>

TYPE="${1:?Usage: check-inbox.sh <type> <project_path>}"
PROJECT="${2:?Missing project_path}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"  # agmsg_agent_pid, for instance-id derivation
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/type-registry.sh"

# Some Stop-hook runtimes (codex, copilot) want an explicit JSON status object
# even when there is nothing to deliver; others (claude-code) stay silent. This
# is the type's manifest `stop_output=` (data), not a hardcoded type list.
STOP_OUTPUT="$(agmsg_type_get "$TYPE" stop_output 2>/dev/null || true)"
emit_status_json() {
  [ "$STOP_OUTPUT" = "json" ] || return 0
  printf '{\n  "continue": true,\n  "systemMessage": "%s"\n}\n' "$1"
}

# Hook runtimes that pass JSON do so on stdin. Interactive invocations such as
# Gemini's PostToolUse command may inherit a terminal stdin instead; reading
# unconditionally there blocks waiting for input. The `[ ! -t 0 ]` guard just below
# only rules out that TTY case -- a non-TTY stdin whose write end is left
# open (a hook runtime that writes the payload and then simply never closes
# the pipe) still leaves this `cat` waiting for an EOF that never arrives.
# Stop/turn hooks run synchronously, so a `cat` stuck here freezes the whole
# agent pane until the user kills it. Bound the read; a runtime that forgets
# to close its pipe still gets its payload delivered (it's already sitting in
# the command substitution buffer by the time the deadline fires), just a few
# seconds late instead of never. Fails open when `timeout` isn't on PATH
# (stock macOS) -- same unbounded read as before, no regression there. #381
INPUT=""
if [ ! -t 0 ]; then
  if command -v timeout >/dev/null 2>&1; then
    INPUT=$(timeout "${AGMSG_HOOK_STDIN_TIMEOUT:-2}" cat 2>/dev/null || true)
  else
    INPUT=$(cat 2>/dev/null || true)
  fi
fi

# Prevent infinite loop: if stop hook is already active, exit silently
if echo "$INPUT" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true' 2>/dev/null; then
  exit 0
fi

# Defer to the monitor watcher when one is alive for this session.
# Avoids double-delivery when delivery.mode = both. The session id field name
# differs by vendor: Claude Code emits snake_case "session_id"; Grok Build (and
# Cursor) emit camelCase "sessionId". Try snake first (claude-code unaffected),
# then camel, then the GROK_SESSION_ID env Grok injects into every hook.
SESSION_ID=$(printf '%s' "$INPUT" \
  | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -1)
[ -z "$SESSION_ID" ] && SESSION_ID=$(printf '%s' "$INPUT" \
  | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -1)
[ -z "$SESSION_ID" ] && SESSION_ID="${GROK_SESSION_ID:-}"
if [ -n "$SESSION_ID" ]; then
  # The monitor watcher keys its pidfile (and its actas owner, below) on the
  # per-process instance id (#93), not the bare session_id. Normalize to the
  # same token so this Stop-hook defers to a live watcher in `both` mode instead
  # of double-delivering.
  SESSION_ID="$(agmsg_normalize_instance_id "$SESSION_ID" "$TYPE")"
  PIDFILE="$SKILL_DIR/run/watch.$SESSION_ID.pid"
  if [ -f "$PIDFILE" ]; then
    WATCH_PID=$(cat "$PIDFILE" 2>/dev/null || true)
    # EPERM-aware liveness (_agmsg_pid_alive): a sandbox-unsignalable watcher is still alive.
    if [ -n "$WATCH_PID" ] && _agmsg_pid_alive "$WATCH_PID"; then
      exit 0
    fi
  fi
fi

# Identify agent and teams
WHOAMI=$("$SCRIPT_DIR/whoami.sh" "$PROJECT" "$TYPE")
# suggest=true means this identity is registered only under a DIFFERENT
# project, so it is not joined here -> deliver nothing (mirror not_joined).
# Without this the else-branch extracts "agents=" as the agent name.
if echo "$WHOAMI" | grep -Eq "not_joined=true|suggest=true"; then
  exit 0
fi

# Handle multiple identities: use first agent name
if echo "$WHOAMI" | grep -q "multiple=true"; then
  AGENT=$(echo "$WHOAMI" | sed -n 's/.*agents=\([^,]*\).*/\1/p')
else
  # Anchor on a leading "agent=" so "agents=" (multiple/suggest) cannot match.
  AGENT=$(echo "$WHOAMI" | sed -n 's/^agent=\([^ ]*\).*/\1/p')
fi
TEAMS=$(echo "$WHOAMI" | sed -n 's/.*teams=\([^ ]*\).*/\1/p')

if [ -z "$AGENT" ] || [ -z "$TEAMS" ]; then
  exit 0
fi

# Cooldown check. The marker is hook runtime state, not message storage, so it
# lives in the skill's run dir — independent of AGMSG_STORAGE_PATH. Keeping it
# out of the store means an overridden/sandboxed store still gets delivery even
# when the default db dir doesn't exist.
MARKER="$SKILL_DIR/run/.lastcheck-$AGENT"

if [ -f "$MARKER" ]; then
  last=$(compat_file_mtime "$MARKER")
  now=$(date +%s)
  # Prefer the new delivery.turn.check_interval; fall back to legacy
  # hook.check_interval for users who haven't migrated.
  INTERVAL=$("$SCRIPT_DIR/config.sh" get delivery.turn.check_interval "")
  [ -z "$INTERVAL" ] && INTERVAL=$("$SCRIPT_DIR/config.sh" get hook.check_interval 60)
  case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=60 ;; esac
  if [ $(( now - last )) -lt "$INTERVAL" ]; then
    emit_status_json "agmsg: check skipped (cooldown)"
    exit 0
  fi
fi

mkdir -p "$SKILL_DIR/run"
touch "$MARKER"

# Check for unread messages and mark as read. Ask the active driver whether a
# store exists (driver-level, works for jsonl too) — don't create one on a poll.
# The check is per team, inside the loop below: a store is selected per team
# now, so "this team has no store yet" is a normal state, and answering it
# once for the whole process would silently stop delivery for every OTHER
# team the moment one of them was uninitialized.
agmsg_storage_load

# Messages are marked read inside this loop; the whole batch is emitted after
# it. Under `set -e` an unguarded command substitution ends the script the
# moment it fails -- and a failure while processing a LATER team lands after
# an EARLIER team's rows were already stamped read_at, before either emit
# point. Those messages are read, undelivered, and never offered again.
# Measured on 8a2fe623: first_deliveries=0 first_read=1 second_unread=1 rc=5.
#
# So every substitution in here records the status and stops the loop instead
# of ending the script. Whatever was already accumulated is emitted below, and
# the failure is still propagated afterwards -- the run is not pretended to
# have succeeded, it just stops taking messages down with it.
OUTPUT=""
LOOP_RC=0
LOOP_FAILED_TEAM=""
IFS=',' read -ra TEAM_LIST <<< "$TEAMS"
for team in "${TEAM_LIST[@]}"; do
  storage_store_exists "$team" || continue

  # ONE guarded boundary for everything that reads or formats.
  #
  # The first attempt listed the substitutions and guarded each -- and missed
  # one (`_arr`), which is the whole failure mode this file is about: an
  # enumeration is short by one and the one it is short by is the defect. A
  # subshell with its own errexit does not need the list. Anything in here that
  # fails ends the subshell, and the status arrives at the `||` below instead of
  # ending the script.
  #
  # 97 and 98 are the two ordinary reasons to skip a team, carried as statuses
  # because a subshell cannot `continue` its caller's loop.
  RESULT=$(
    set -euo pipefail
    # Honor actas exclusivity locks. If (team, AGENT) is held by another live
    # session, that session owns that role's inbox — don't deliver here.
    # Mirrors watch.sh's per-pair filtering (#62).
    #
    # AGENT comes from whoami.sh: the first registered agent for
    # (project, type), NOT the session's in-memory actas role — the Codex
    # caveat documented in README.
    state=$(actas_lock_state "$team" "$AGENT" "${SESSION_ID:-}")
    case "$state" in other:*) exit 97 ;; esac

    # Unread via the storage facade (§2.1 storage_list_unread = events ∪ legacy),
    # JSONL parsed in one pass with sqlite's JSON funcs (no jq; cf. lib/hooks-json.sh).
    # id is kept so the mark step below targets exactly the rows shown.
    UNREAD_JSONL=$(storage_list_unread "$team" "$AGENT")
    [ -n "$UNREAD_JSONL" ] || exit 98
    _arr="[$(printf '%s' "$UNREAD_JSONL" | paste -sd, -)]"
    agmsg_sqlite ':memory:' "
      SELECT json_extract(value,'\$.from') || char(31) ||
             replace(replace(json_extract(value,'\$.body'), char(10), '\n'), char(9), '\t') || char(31) ||
             json_extract(value,'\$.at') || char(31) ||
             json_extract(value,'\$.id')
      FROM json_each('$(printf '%s' "$_arr" | sed "s/'/''/g")');
    "
  ) || {
    _rc=$?
    case "$_rc" in
      97|98) continue ;;
      *) LOOP_RC=$_rc; LOOP_FAILED_TEAM="$team"; break ;;
    esac
  }

  COUNT=$(printf '%s\n' "$RESULT" | grep -c . || true)
  OUTPUT+="$COUNT new message(s) in $team:"$'\n'
  IDS=()
  while IFS=$'\x1f' read -r from body ts id; do
    [ -n "$id" ] || continue
    OUTPUT+="  [$ts] $from: $body"$'\n'
    IDS+=("$id")
  done <<< "$RESULT"
  OUTPUT+=$'\n'
  # Test seam: a two-file barrier that lets the race regression test land a
  # message deterministically between display and mark. No-op unless set.
  if [ -n "${AGMSG_TEST_MARK_BARRIER:-}" ]; then
    : > "$AGMSG_TEST_MARK_BARRIER.reached"
    _agmsg_barrier_waited=0
    while [ ! -e "$AGMSG_TEST_MARK_BARRIER.release" ]; do
      sleep 0.05
      _agmsg_barrier_waited=$((_agmsg_barrier_waited + 1))
      [ "$_agmsg_barrier_waited" -ge 200 ] && break # 10s safety cap
    done
  fi
  # Mark read via the facade (§2.1 storage_mark_read_batch): recipient-scoped,
  # idempotent; a legacy id records a message_read event without mutating the
  # legacy row (§2.4). Only the ids collected from the rows actually displayed
  # above — never a blanket match — so a message that arrives after the SELECT
  # can never be marked read unseen.
  if [ "${#IDS[@]}" -gt 0 ]; then
    storage_mark_read_batch "$team" "$AGENT" "${IDS[@]}" >/dev/null 2>&1 || true
  fi
done

# The exit code cannot carry both the delivery and the failure report.
#
# The hook runtimes read stdout as control JSON only when the process exits 0;
# a non-zero exit is logged as a hook failure and the output is discarded. So
# emitting the messages and THEN exiting non-zero delivers nothing — on exactly
# the path where messages were already marked read. The first version of this
# fix did that, and was therefore inert on the only path that was broken.
#
# Delivery and the report are separated: the messages go out with exit 0, and
# the partial failure is stated inside the payload the operator actually reads.
# Nothing upstream sees a partial poll as a complete one, because the text says
# so.
if [ -n "$OUTPUT" ]; then
  if [ "$LOOP_RC" -ne 0 ]; then
    OUTPUT+="agmsg: this poll stopped early — team '$LOOP_FAILED_TEAM' could not be read (status $LOOP_RC)."$'\n'
    OUTPUT+="agmsg: teams after it were not checked; their messages stay unread and will be offered again."$'\n'
  fi
  # Escape for JSON: backslash, double-quote, newlines, tabs (macOS/Linux compatible)
  ESCAPED=$(printf '%s' "$OUTPUT" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | awk '{if(NR>1) printf "\\n"; printf "%s",$0}')
  cat <<ENDJSON
{
  "decision": "block",
  "reason": "$ESCAPED"
}
ENDJSON
  # Exit 0 even when the poll failed part-way: this is the delivering path, and
  # a non-zero status here throws the delivery away.
  exit 0
fi

# Nothing was accumulated. There is no delivery to protect, so the status is
# free to carry the failure — and it must, because "no new messages" here would
# claim something this run never established.
[ "$LOOP_RC" -eq 0 ] || exit "$LOOP_RC"
emit_status_json "agmsg: no new messages"
exit 0
