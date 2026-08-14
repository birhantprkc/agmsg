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

collect_engine_pids() {
  local pidfile="$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
  [ -f "$pidfile" ] && ENGINE_PIDS="$ENGINE_PIDS $(cat "$pidfile")"
  return 0
}

@test "starts an engine for a connected team that has none" {
  export AGMSG_NODE="$(write_fake_node)"
  source "$SCRIPTS/lib/sync-autostart.sh"
  run agmsg_sync_autostart "$SCRIPTS/remote.sh" testteam
  collect_engine_pids
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'started one for'
  printf '%s' "$output" | grep -q 'testteam'
  # The artifact, not the sentence: a pidfile naming a live process.
  [ -f "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]
  kill -0 "$(cat "$TEST_SKILL_DIR/run/remote-sync.testteam.pid")"
}

@test "says nothing at all when the engine is already running" {
  export AGMSG_NODE="$(write_fake_node)"
  bash "$SCRIPTS/remote.sh" sync start testteam
  collect_engine_pids
  source "$SCRIPTS/lib/sync-autostart.sh"
  run agmsg_sync_autostart "$SCRIPTS/remote.sh" testteam
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

@test "a team that is disconnected is not started, and the refusal is shown" {
  export AGMSG_NODE="$(write_fake_node)"
  local cfg="$TEST_SKILL_DIR/teams/testteam/config.json" escaped updated
  escaped="$(sed "s/'/''/g" "$cfg")"
  updated="$(sqlite_mem "
    SELECT json_set('$escaped', '\$.remote_binding.disconnected_at', '2026-08-01T00:00:00Z');")"
  printf '%s\n' "$updated" > "$cfg"

  source "$SCRIPTS/lib/sync-autostart.sh"
  run agmsg_sync_autostart "$SCRIPTS/remote.sh" testteam
  [ "$status" -eq 0 ]
  # The binding check is the COMMAND's, inherited: it refuses by name before it
  # starts anything, and the reason it gave is repeated rather than replaced.
  printf '%s' "$output" | grep -q 'disconnected'
  [ ! -f "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]
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
  export AGMSG_SYNC_AUTOSTART_TIMEOUT_S=60
  export AGMSG_NODE="$(write_failing_node)"

  source "$SCRIPTS/lib/sync-autostart.sh"
  run agmsg_sync_autostart "$SCRIPTS/remote.sh" testteam
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
  ! grep -q '^otherteam$' "$calls"
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
