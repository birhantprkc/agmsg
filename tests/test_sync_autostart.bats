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
  [[ "$output" == *"started one for"* ]]
  [[ "$output" == *"testteam"* ]]
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
  [[ "$output" == *"disconnected"* ]]
  [ ! -f "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]
}

@test "a start that fails does not fail the caller, and says what the command said" {
  # An agent that will not open because a sync engine refused is worse than a
  # sync engine that is down.
  export AGMSG_NODE="$(write_failing_node)"

  source "$SCRIPTS/lib/sync-autostart.sh"
  run agmsg_sync_autostart "$SCRIPTS/remote.sh" testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected, but not syncing"* ]]
  [[ "$output" == *"The session continues."* ]]
  # The runnable remedy survives from #765 — the person now also knows it was
  # tried.
  [[ "$output" == *"sync start"* ]]
}

@test "no teams, no output, no failure" {
  source "$SCRIPTS/lib/sync-autostart.sh"
  run agmsg_sync_autostart "$SCRIPTS/remote.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
