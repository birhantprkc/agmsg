#!/usr/bin/env bats

load test_helper

# Starting a connected team's engine when an agent turns up (#774).
#
# The case this exists for is SEVERAL SESSIONS AT ONCE on one machine, in one
# team. They race for the per-team lock `cmd_sync_start` takes; one starts the
# engine and the rest are told `already running` and carry on. That behaviour
# belongs to the command, and these tests pin that the auto-start path inherits
# it rather than reproducing it — a second answer to "is it running?" diverges
# exactly under this race.

setup() {
  setup_test_env
  # The trigger tests below run the real scripts, which read these two.
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a

  local cfg="$TEST_SKILL_DIR/teams/testteam/config.json" escaped updated
  escaped="$(sed "s/'/''/g" "$cfg")"
  updated="$(sqlite_mem "
    SELECT json_set('$escaped', '\$.remote_binding', json_object(
      'endpoint', 'https://remote.example',
      'server_instance_id', '018f0000-0000-7000-8000-000000000001',
      'remote_team_id', '018f0000-0000-7000-8000-000000000002',
      'protocol_version', 1,
      'capabilities', json_object('write_allowed_ciphers', json_array('none')),
      'connected_at', '2026-07-30T00:00:00Z',
      'disconnected_at', null
    ));")"
  printf '%s\n' "$updated" > "$cfg"
  mkdir -p "$TEST_SKILL_DIR/run"
  ENGINE_PIDS=""
}

teardown() {
  local pid
  for pid in $ENGINE_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  # The "does not wait" cases leave a `sync start` child running ON PURPOSE —
  # that is the behaviour under test. It must not outlive the test: a CI shard
  # runs many files in one process tree, and a fake that loops forever would
  # then be somebody else's flake (raised in review).
  # BY THE PATH THEY ACTUALLY RUN UNDER. The hanging fake is COPIED over
  # `$SCRIPTS/remote.sh`, so matching the name it was written as reaps nothing
  # and the child outlives the whole file — which is how this suite stopped
  # exiting even with every case green. Both paths are inside the test's own
  # skill dir, so the pattern cannot reach anything else.
  pkill -f "$TEST_SKILL_DIR/" 2>/dev/null || true
  teardown_test_env
}

# A node that becomes READY and then stays up.
#
# `cmd_sync_start` does not return when the process exists — it waits for the
# engine's `startup_nonce` to appear in the logfile, so a fake that only sleeps
# makes the command spin until its own timeout. Same shape as
# test_remote_status_liveness.bats's fake node, which is where this came from.
write_fake_node() {
  local fake_node="$TEST_SKILL_DIR/fake-node"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "${1:-}" = "--version" ]; then' \
    '  echo v23.0.0' \
    '  exit 0' \
    'fi' \
    'echo "{\"event\":\"capabilities\",\"startup_nonce\":\"${AGMSG_SYNC_START_NONCE:-}\"}"' \
    'trap "exit 0" TERM INT' \
    'while :; do sleep 1; done' > "$fake_node"
  chmod +x "$fake_node"
  printf '%s\n' "$fake_node"
}

# A node that fails to start at all.
write_failing_node() {
  local fake_node="$TEST_SKILL_DIR/fake-node-bad"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "${1:-}" = "--version" ]; then echo v23.0.0; exit 0; fi' \
    'echo "engine exploded" >&2' \
    'exit 1' > "$fake_node"
  chmod +x "$fake_node"
  printf '%s\n' "$fake_node"
}

# Register a (team, agent) pair for the test project, as the actas tests do.
fake_register() {
  local team="$1" agent="$2" proj="${3:-/tmp/p1}"
  bash "$SCRIPTS/join.sh" "$team" "$agent" claude-code "$proj" >/dev/null 2>&1 || true
}

# Wait briefly for a call to be RECORDED.
#
# The "does not wait" cases give the helper a 1s budget, so it returns while the
# child is still running — and the child records the team name as its first act.
# Grepping immediately is therefore a race with a process the test deliberately
# did not wait for: it passed on an idle machine and went red under load, which
# is a flaky assertion dressed as a strict one. The bound here is generous
# because it is not measuring speed; the SESSION's bound is measured separately,
# from the outside, in the same test.
wait_for_call() {
  local file="$1" needle="$2" i=0
  while [ "$i" -lt 100 ]; do
    grep -q "^$needle\$" "$file" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# A `remote.sh` that answers instantly, for the cases where the SUBJECT is what
# the helper does with an answer — not how long the real command takes.
#
# The real command is kept for the race case below, which is about inheriting
# its lock. Everywhere else it only made the suite slow and timing-coupled:
# raising the budget so a case could not be cut short is the same admission,
# with a worse failure mode (a 60s case that goes red when the machine is busy).
write_answering_remote() {
  local answer="$1" fake="$TEST_SKILL_DIR/fake-remote-answer.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '[ "${1:-}" = "sync" ] || exit 0'
    case "$answer" in
      started)  printf '%s\n' 'echo "Sync engine started for '"'"'$3'"'"' (pid 4242)."; exit 0' ;;
      running)  printf '%s\n' 'echo "Sync engine already running (pid 4242)."; exit 0' ;;
      refused)  printf '%s\n' 'echo "agmsg: team '"'"'$3'"'"' is disconnected; connect or pull it before starting sync" >&2; exit 1' ;;
      broken)   printf '%s\n' 'echo "engine exploded" >&2; exit 1' ;;
    esac
  } > "$fake"
  chmod +x "$fake"
  printf '%s\n' "$fake"
}

collect_engine_pids() {
  local pidfile="$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
  [ -f "$pidfile" ] && ENGINE_PIDS="$ENGINE_PIDS $(cat "$pidfile")"
  return 0
}

@test "starts an engine for a connected team that has none" {
  # THE REAL COMMAND, because this case asserts on the artifact it leaves: a
  # pidfile naming a live process. The sentence is not the evidence.
  export AGMSG_SYNC_AUTOSTART_TIMEOUT_S=60
  export AGMSG_NODE="$(write_fake_node)"
  source "$SCRIPTS/lib/sync-autostart.sh"
  run agmsg_sync_autostart "$SCRIPTS/remote.sh" testteam
  collect_engine_pids
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'started one for'
  printf '%s' "$output" | grep -q 'testteam'
  [ -f "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]
  # Liveness through the shipped helper, not a bare kill -0 (a repo-wide check
  # forbids the latter, and it caught this branch once already).
  run bash -c 'source "'"$SCRIPTS"'/lib/instance-id.sh"; _agmsg_pid_alive "$(cat "'"$TEST_SKILL_DIR"'/run/remote-sync.testteam.pid")"'
  [ "$status" -eq 0 ]
}

@test "says nothing at all when the engine is already running" {
  source "$SCRIPTS/lib/sync-autostart.sh"
  run agmsg_sync_autostart "$(write_answering_remote running)" testteam
  [ "$status" -eq 0 ]
  # Starting is a side effect nobody asked for in this moment; "nothing
  # changed" is not news, and a line here would appear on every session start
  # for the rest of the machine's life.
  [ -z "$output" ]
}

@test "several sessions at once leave exactly one engine, and none of them fails" {
  # THE CASE THIS FEATURE IS FOR. Five callers race for the per-team lock.
  export AGMSG_NODE="$(write_fake_node)"
  source "$SCRIPTS/lib/sync-autostart.sh"

  local i outdir="$TEST_SKILL_DIR/race"
  mkdir -p "$outdir"
  for i in 1 2 3 4 5; do
    (
      agmsg_sync_autostart "$SCRIPTS/remote.sh" testteam > "$outdir/$i.out" 2>&1
      printf '%s\n' "$?" > "$outdir/$i.rc"
    ) &
  done
  wait
  collect_engine_pids

  # Every caller succeeded — the losers of the race are not failures.
  for i in 1 2 3 4 5; do
    [ "$(cat "$outdir/$i.rc")" = "0" ]
  done

  # Exactly one of them reports having started it. The rest say nothing, which
  # is what `already running` produces.
  local started=0 quiet=0
  for i in 1 2 3 4 5; do
    if grep -q "started one for" "$outdir/$i.out"; then
      started=$((started + 1))
    elif [ ! -s "$outdir/$i.out" ]; then
      quiet=$((quiet + 1))
    fi
  done
  [ "$started" -eq 1 ]
  [ "$quiet" -eq 4 ]

  # And one engine exists, not five. Counted from the process table rather than
  # from the pidfile: the pidfile can only ever name one, so asking it would be
  # asking the wrong witness.
  local pidfile="$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
  [ -f "$pidfile" ]
  kill -0 "$(cat "$pidfile")"
  local live
  live="$(pgrep -f "fake-node" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$live" = "1" ]
}

@test "a refusal from the command is repeated, not replaced" {
  # THE SUBJECT IS THE HELPER'S HANDLING of a refusal, so the refusal is given
  # to it directly. Driving the real command here made the case depend on how
  # busy the machine was — it went green alone and red in the full file — and
  # raising the budget only made it slow instead of wrong.
  #
  # The binding check itself belongs to `cmd_sync_start` and is tested where it
  # lives; what is asserted here is that its sentence survives.
  source "$SCRIPTS/lib/sync-autostart.sh"
  run agmsg_sync_autostart "$(write_answering_remote refused)" testteam
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'disconnected'
  printf '%s' "$output" | grep -q 'connected, but not syncing'
}

@test "a start that fails does not fail the caller, and says what the command said" {
  # An agent that will not open because a sync engine refused is worse than a
  # sync engine that is down.
  #
  # The budget is raised for this case on purpose. `cmd_sync_start` does not
  # notice a dead engine immediately — it waits out its readiness loop — so
  # under the default 5s this failure is reported as "still in flight", which
  # is TRUE and is a different sentence. The two outcomes are tested
  # separately rather than folded together: "it failed" and "it has not
  # answered yet" are different facts and the tool says different things.
  source "$SCRIPTS/lib/sync-autostart.sh"
  run agmsg_sync_autostart "$(write_answering_remote broken)" testteam
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'connected, but not syncing'
  printf '%s' "$output" | grep -q 'The session continues.'
  # The runnable remedy survives from #765 — the person now also knows it was
  # tried.
  printf '%s' "$output" | grep -q 'sync start'
}

@test "no teams, no output, no failure" {
  source "$SCRIPTS/lib/sync-autostart.sh"
  run agmsg_sync_autostart "$SCRIPTS/remote.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── the two production triggers, driven for real ─────────────────────────────
#
# Everything above drives `agmsg_sync_autostart` directly, and deleting the
# wiring from either trigger leaves all of it green (raised in review). The
# wiring is the PR's whole point and it is different on each side:
# session-start awks `remote.sh status` for connected teams, actas-claim
# array-ifies `$TEAMS` after the claim. Neither follows from the helper being
# right.

# A `remote.sh` this test controls, standing in for the real one so a trigger
# can be driven without a server. It records every call it was given.
write_fake_remote() {
  local behaviour="$1" fake="$TEST_SKILL_DIR/fake-remote.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'calls="$AGMSG_FAKE_REMOTE_CALLS"'
    printf '%s\n' 'if [ "${1:-}" = "status" ]; then'
    printf '%s\n' '  printf "%s\tconnected (engine stopped — run: x) since 2026-07-30T00:00:00Z\n" testteam'
    printf '%s\n' '  printf "%s\tdisconnected (was connected until 2026-08-01T00:00:00Z)\n" otherteam'
    printf '%s\n' '  exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'if [ "${1:-}" = "sync" ] && [ "${2:-}" = "start" ]; then'
    printf '%s\n' '  printf "%s\n" "$3" >> "$calls"'
    case "$behaviour" in
      starts) printf '%s\n' '  echo "Sync engine started for '"'"'$3'"'"' (pid 4242)."; exit 0' ;;
      hangs)  printf '%s\n' '  while :; do sleep 1; done' ;;
    esac
    printf '%s\n' 'fi'
    printf '%s\n' 'exit 0'
  } > "$fake"
  chmod +x "$fake"
  printf '%s\n' "$fake"
}

@test "session-start starts the engine for a connected team, and still emits the directive" {
  local fake calls="$TEST_SKILL_DIR/calls.txt"
  fake="$(write_fake_remote starts)"
  cp "$fake" "$SCRIPTS/remote.sh"
  : > "$calls"
  fake_register testteam alice
  echo "sid-current" > "$RUN_DIR/cc-instance.$$"

  run env AGMSG_FAKE_REMOTE_CALLS="$calls" bash -c \
    'printf "{\"session_id\":\"sid-current\"}" | bash "$1" claude-code /tmp/p1' _ \
    "$SCRIPTS/session-start.sh"

  # The connected team was started...
  grep -q '^testteam$' "$calls"
  # ...and the disconnected one was never offered to the command.
  #
  # `refute`, not `! grep`. A leading `!` does not trip errexit on either
  # interpreter, so in a non-last position it reports ok whatever it finds —
  # I removed five of those from this file and introduced this one in the same
  # head (raised in review).
  refute grep -q '^otherteam$' "$calls"
  # ...and the thing the session actually needs still came out.
  printf '%s' "$output" | grep -q 'AGMSG'
  [ "$status" -eq 0 ]
}

@test "session-start does not wait for a start that hangs" {
  local fake calls="$TEST_SKILL_DIR/calls.txt" began ended
  fake="$(write_fake_remote hangs)"
  cp "$fake" "$SCRIPTS/remote.sh"
  : > "$calls"
  fake_register testteam alice
  echo "sid-current" > "$RUN_DIR/cc-instance.$$"

  began=$SECONDS
  run env AGMSG_FAKE_REMOTE_CALLS="$calls" AGMSG_SYNC_AUTOSTART_TIMEOUT_S=1 bash -c \
    'printf "{\"session_id\":\"sid-current\"}" | bash "$1" claude-code /tmp/p1' _ \
    "$SCRIPTS/session-start.sh"
  ended=$SECONDS

  # THAT IT WAS TRIED. Without this the case passes when the invocation is
  # DELETED — nothing to wait for is also fast — so it would be measuring the
  # absence of the feature and calling it a bound (found by the deletion
  # mutation; the actas twin below had the same hole).
  wait_for_call "$calls" testteam
  # The bound, from the outside: a session that waits on a hung child is the
  # release-blocker fix blocking a release.
  [ $((ended - began)) -lt 10 ]
  # It said a start is in flight rather than pretending nothing happened.
  printf '%s' "$output" | grep -q 'still in flight'
  [ "$status" -eq 0 ]
}

@test "actas-claim starts the engine and still prints status=ok" {
  local fake calls="$TEST_SKILL_DIR/calls.txt"
  fake="$(write_fake_remote starts)"
  cp "$fake" "$SCRIPTS/remote.sh"
  : > "$calls"
  fake_register testteam alice

  run env AGMSG_FAKE_REMOTE_CALLS="$calls" bash "$SCRIPTS/actas-claim.sh" \
    /tmp/project-a claude-code alice sid-actas
  # The claim is what the caller is waiting on, and it still arrives.
  printf '%s' "$output" | grep -q 'status=ok'
  grep -q '^testteam$' "$calls"
  [ "$status" -eq 0 ]
}

@test "actas-claim does not wait for a start that hangs" {
  local fake calls="$TEST_SKILL_DIR/calls.txt" began ended
  fake="$(write_fake_remote hangs)"
  cp "$fake" "$SCRIPTS/remote.sh"
  : > "$calls"
  fake_register testteam alice

  began=$SECONDS
  run env AGMSG_FAKE_REMOTE_CALLS="$calls" AGMSG_SYNC_AUTOSTART_TIMEOUT_S=1 \
    bash "$SCRIPTS/actas-claim.sh" /tmp/project-a claude-code alice sid-actas
  ended=$SECONDS

  # THAT IT WAS TRIED — see the session-start twin. Deleting the invocation
  # made this case pass, which is the check measuring its own absence.
  wait_for_call "$calls" testteam
  [ $((ended - began)) -lt 10 ]
  printf '%s' "$output" | grep -q 'status=ok'
  [ "$status" -eq 0 ]
}

# --- #773: a team the server has refused is not started ---------------------
#
# Auto-start plus an engine that exits on a refusal is a restart loop: start,
# refuse, exit, start again next session. #773 kept the engine up and put the
# refusal where a reader can find it; this is the reader, at the one moment a
# start would otherwise be attempted.

# A `remote.sh` that reports a refusal from `status`, and RECORDS whether it was
# ever asked to start anything. The record is the point: "did not start it" is
# the claim, and an output check alone cannot tell "not started" from "started
# and said nothing".
write_refusing_status_remote() {
  local line="$1" fake="$TEST_SKILL_DIR/fake-remote-refusal.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'case "${1:-}" in'
    printf '%s\n' "  status) printf '%s\\n' \"  $line\"; exit 0 ;;"
    printf '%s\n' '  sync)   printf "%s\n" "$3" >> "$AGMSG_TEST_START_CALLS"; echo "Sync engine started for '"'"'$3'"'"' (pid 4242)."; exit 0 ;;'
    printf '%s\n' 'esac'
    printf '%s\n' 'exit 0'
  } > "$fake"
  chmod +x "$fake"
  printf '%s\n' "$fake"
}

@test "autostart: a team the server has refused is never offered to sync start (#773)" {
  source "$SCRIPTS/lib/sync-autostart.sh"
  export AGMSG_TEST_START_CALLS="$TEST_SKILL_DIR/start-calls"
  : > "$AGMSG_TEST_START_CALLS"
  local fake; fake="$(write_refusing_status_remote 'refused: the server answered 402 payment_required (sync.example.test)')"

  run agmsg_sync_autostart "$fake" testteam
  [ "$status" -eq 0 ]

  # The claim is "it was not started", so the call record is what is asserted.
  [ ! -s "$AGMSG_TEST_START_CALLS" ]
  # And the reason reaches the operator, in the server's words.
  printf '%s' "$output" | grep -q 'the server refused'
  printf '%s' "$output" | grep -q '402 payment_required'
  printf '%s' "$output" | grep -q 'sync.example.test'
  # Nothing invented about what it MEANS. Each of these is a sentence only the
  # operator of that server may write.
  refute grep -qi 'subscri' <<<"$output"
  refute grep -qi 'upgrade' <<<"$output"
  refute grep -qi 'billing' <<<"$output"
  refute grep -qi 'plan'    <<<"$output"
}

@test "autostart: a status this client never enumerated still stops the start (#773)" {
  # BY THE LINE, NOT BY THE NUMBER. A self-hosted server refuses for its own
  # reasons with codes nothing here has heard of.
  source "$SCRIPTS/lib/sync-autostart.sh"
  export AGMSG_TEST_START_CALLS="$TEST_SKILL_DIR/start-calls"
  : > "$AGMSG_TEST_START_CALLS"
  local fake; fake="$(write_refusing_status_remote 'refused: the server answered 451 tenant_suspended_by_operator (sync.example.test)')"

  run agmsg_sync_autostart "$fake" testteam
  [ ! -s "$AGMSG_TEST_START_CALLS" ]
  printf '%s' "$output" | grep -q '451 tenant_suspended_by_operator'
}

@test "autostart: with no refusal recorded, the team IS started (#773 negative control)" {
  # Without this, the two cases above are satisfied by a helper that never
  # starts anything at all.
  source "$SCRIPTS/lib/sync-autostart.sh"
  export AGMSG_TEST_START_CALLS="$TEST_SKILL_DIR/start-calls"
  : > "$AGMSG_TEST_START_CALLS"
  local fake="$TEST_SKILL_DIR/fake-remote-clean.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'case "${1:-}" in'
    printf '%s\n' '  status) printf "%s\n" "  testteam  connected since 2026-08-01"; exit 0 ;;'
    printf '%s\n' '  sync)   printf "%s\n" "$3" >> "$AGMSG_TEST_START_CALLS"; echo "Sync engine started for '"'"'$3'"'"' (pid 4242)."; exit 0 ;;'
    printf '%s\n' 'esac'
    printf '%s\n' 'exit 0'
  } > "$fake"
  chmod +x "$fake"

  run agmsg_sync_autostart "$fake" testteam
  [ "$status" -eq 0 ]
  grep -q '^testteam$' "$AGMSG_TEST_START_CALLS"
  printf '%s' "$output" | grep -q 'started one for'
  refute grep -q 'the server refused' <<<"$output"
}

@test "autostart: a status that hangs does not hold the session (#773 under the same budget)" {
  # The refusal lookup asks the same command the rest of this file drives, and
  # it runs in the session's critical path. An unbounded call there is the
  # defect the background start exists to prevent, one line above it.
  #
  # Bound checked from the OUTSIDE, by wall clock, because a bound that only
  # exists in the source is not a bound.
  source "$SCRIPTS/lib/sync-autostart.sh"
  export AGMSG_TEST_START_CALLS="$TEST_SKILL_DIR/start-calls"
  : > "$AGMSG_TEST_START_CALLS"
  local fake="$TEST_SKILL_DIR/fake-remote-hanging-status.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'case "${1:-}" in'
    printf '%s\n' '  status) while :; do sleep 1; done ;;'
    printf '%s\n' '  sync)   printf "%s\n" "$3" >> "$AGMSG_TEST_START_CALLS"; echo "Sync engine started for '"'"'$3'"'"' (pid 4242)."; exit 0 ;;'
    printf '%s\n' 'esac'
    printf '%s\n' 'exit 0'
  } > "$fake"
  chmod +x "$fake"

  local began=$SECONDS
  AGMSG_SYNC_AUTOSTART_TIMEOUT_S=2 run agmsg_sync_autostart "$fake" testteam
  local took=$((SECONDS - began))

  [ "$status" -eq 0 ]
  # The budget is 2s; anything near the fake's forever is the bound missing.
  [ "$took" -lt 10 ]

  # AND NOTHING IS LEFT BEHIND. Bounding the caller while the probe runs for
  # ever adds a process and two temp paths to every session and every actas,
  # which is a leak measured in machine uptime rather than in one run. A
  # `status` reads, so there is nothing half-made to protect by leaving it.
  # Matched by the path THIS TEST'S fake actually runs under, not by its bare
  # name. A bare name matches a stray from any other run in the same process
  # tree -- a CI shard runs many files in one -- and this assertion then goes
  # red for somebody else's leftover. It did exactly that here, against a
  # leftover from an earlier experiment of my own, and passed under `--filter`
  # while failing in the full file: the same coupling this suite already fixed
  # in the other direction.
  local i alive=1
  for i in $(seq 1 50); do
    pgrep -f "$TEST_SKILL_DIR/fake-remote-hanging-status" >/dev/null 2>&1 || { alive=0; break; }
    sleep 0.1
  done
  [ "$alive" -eq 0 ]
}

@test "autostart: with several teams, a hanging status leaves nothing behind for any of them (#773)" {
  # What this DOES measure: a call over several teams spends one budget, not
  # one per team, and leaves nothing running afterwards.
  #
  # What it does NOT measure, stated because a reader will assume otherwise:
  # it does not catch the two clocks drifting apart. Giving the probe's own
  # watchdog the full budget while this side allows only the remainder leaves
  # this test green — with a `status` that never returns, the FIRST team
  # consumes the whole budget, every later team gets zero remaining and starts
  # no probe at all, so there is no second probe for the two clocks to disagree
  # about. Measured, not assumed: that mutation was run and stayed green.
  #
  # The shared deadline is therefore justified by reading the code, not by this
  # control. A control that does discriminate would need a first team that is
  # slow-but-finishing and a second that hangs, which is a timing construction
  # of exactly the kind this file has twice been told not to build.
  source "$SCRIPTS/lib/sync-autostart.sh"
  export AGMSG_TEST_START_CALLS="$TEST_SKILL_DIR/start-calls"
  : > "$AGMSG_TEST_START_CALLS"
  local fake="$TEST_SKILL_DIR/fake-remote-hanging-status.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'case "${1:-}" in'
    printf '%s\n' '  status) while :; do sleep 1; done ;;'
    printf '%s\n' '  sync)   printf "%s\n" "$3" >> "$AGMSG_TEST_START_CALLS"; echo "Sync engine started for '"'"'$3'"'"' (pid 4242)."; exit 0 ;;'
    printf '%s\n' 'esac'
    printf '%s\n' 'exit 0'
  } > "$fake"
  chmod +x "$fake"

  local began=$SECONDS
  AGMSG_SYNC_AUTOSTART_TIMEOUT_S=2 run agmsg_sync_autostart "$fake" teamone teamtwo teamthree
  local took=$((SECONDS - began))
  [ "$status" -eq 0 ]
  # One budget for the whole call, not one per team.
  [ "$took" -lt 10 ]

  local i alive=1
  for i in $(seq 1 50); do
    pgrep -f "$TEST_SKILL_DIR/fake-remote-hanging-status" >/dev/null 2>&1 || { alive=0; break; }
    sleep 0.1
  done
  [ "$alive" -eq 0 ]
}
