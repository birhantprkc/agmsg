#!/usr/bin/env bats

load test_helper

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

start_matching_engine() {
  local engine="$SCRIPTS/internal/remote-sync.mjs"
  printf '%s\n' '#!/usr/bin/env bash' \
    'trap "exit 0" TERM INT' \
    'while :; do sleep 1; done' > "$engine"
  chmod +x "$engine"
  bash "$engine" run --team testteam &
  ENGINE_PID=$!
  ENGINE_PIDS="${ENGINE_PIDS:+$ENGINE_PIDS }$ENGINE_PID"
  printf '%s\n' "$ENGINE_PID" > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
}

write_matching_ps_fixture() {
  local fake_bin="$TEST_SKILL_DIR/fake-bin"
  mkdir -p "$fake_bin"
  printf '%s\n' '#!/usr/bin/env bash' \
    "if [[ \" \$* \" == *\" -p $ENGINE_PID \"* ]]; then" \
    "  printf '%s\\n' 'bash $SCRIPTS/internal/remote-sync.mjs run --team testteam'" \
    '  exit 0' \
    'fi' \
    'exec /bin/ps "$@"' > "$fake_bin/ps"
  chmod +x "$fake_bin/ps"
  printf '%s\n' "$fake_bin"
}

write_fake_node() {
  local fake_node="$TEST_SKILL_DIR/fake-node"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "${1:-}" = "--version" ]; then' \
    '  echo v23.0.0' \
    '  exit 0' \
    'fi' \
    'echo '\''{"event":"capabilities"}'\''' \
    'trap "exit 0" TERM INT' \
    'while :; do sleep 1; done' > "$fake_node"
  chmod +x "$fake_node"
  printf '%s\n' "$fake_node"
}

write_fake_node_ps_fixture() {
  local fake_node="$1" foreign_pid="${2:-}" fake_bin="$TEST_SKILL_DIR/fake-node-bin"
  mkdir -p "$fake_bin"
  printf '%s\n' '#!/usr/bin/env bash' \
    'pid=""' \
    'while [ $# -gt 0 ]; do' \
    '  if [ "$1" = "-p" ]; then pid="$2"; shift 2; else shift; fi' \
    'done' \
    "if [ \"\$pid\" = '$foreign_pid' ]; then" \
    "  printf '%s\\n' 'sleep 30'" \
    'else' \
    "  printf '%s\\n' 'bash $SCRIPTS/internal/remote-sync.mjs run --team testteam'" \
    'fi' > "$fake_bin/ps"
  chmod +x "$fake_bin/ps"
  printf '%s\n' "$fake_bin"
}

remember_engine_pid() {
  ENGINE_PID="$(cat "$TEST_SKILL_DIR/run/remote-sync.testteam.pid")"
  ENGINE_PIDS="${ENGINE_PIDS:+$ENGINE_PIDS }$ENGINE_PID"
}

@test "status: reports an active binding whose engine is stopped" {
  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine stopped"* ]]
  [[ "$output" == *"remote.sh sync start testteam"* ]]

  run bash "$SCRIPTS/remote.sh" status testteam --json
  [ "$status" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_state');")" = stopped ]
  [ "$(sqlite_mem "SELECT json_type('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_pid');")" = null ]
}

@test "status: reports a live engine only when argv matches this team" {
  start_matching_engine
  local fake_bin
  fake_bin="$(write_matching_ps_fixture)"

  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine running, pid $ENGINE_PID)"* ]]

  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam --json
  [ "$status" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_state');")" = running ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_pid');")" -eq "$ENGINE_PID" ]
}

@test "status: rejects a live foreign process behind a recycled pidfile" {
  sleep 30 &
  local foreign_pid=$!
  ENGINE_PIDS="${ENGINE_PIDS:+$ENGINE_PIDS }$foreign_pid"
  printf '%s\n' "$foreign_pid" > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine stale"* ]]
  [[ "$output" == *"pidfile $foreign_pid points at a dead or foreign process"* ]]

  run bash "$SCRIPTS/remote.sh" status testteam --json
  [ "$status" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_state');")" = stale ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_pid');")" -eq "$foreign_pid" ]
}

@test "status: reports a dead pidfile as stale without changing exit status" {
  printf '%s\n' 2147483647 > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine stale"* ]]
  [[ "$output" == *"pidfile 2147483647 points at a dead or foreign process"* ]]
}

@test "status: rejects a malformed pidfile without interpreting it as a process" {
  printf '%s\n' 0123 > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  run bash "$SCRIPTS/remote.sh" status testteam --json
  [ "$status" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_state');")" = stale ]
  [ "$(sqlite_mem "SELECT json_type('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_pid');")" = null ]
}

@test "sync start: starts a stopped engine and status reports it running" {
  local fake_node fake_bin first_pid
  fake_node="$(write_fake_node)"
  fake_bin="$(write_fake_node_ps_fixture "$fake_node")"

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sync engine started for 'testteam' (pid "* ]]
  remember_engine_pid
  kill -0 "$ENGINE_PID"

  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine running, pid $ENGINE_PID)"* ]]

  first_pid="$ENGINE_PID"
  kill "$first_pid"
  wait_for_pid_exit "$first_pid"
  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine stale"* ]]

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -eq 0 ]
  remember_engine_pid
  [ "$ENGINE_PID" -ne "$first_pid" ]
  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine running, pid $ENGINE_PID)"* ]]
}

@test "sync start: is a no-op when the verified engine is already running" {
  local fake_node fake_bin original_pid
  fake_node="$(write_fake_node)"
  fake_bin="$(write_fake_node_ps_fixture "$fake_node")"
  env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam
  remember_engine_pid
  original_pid="$ENGINE_PID"

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" \
    bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -eq 0 ]
  [ "$output" = "Sync engine already running (pid $original_pid)." ]
  [ "$(cat "$TEST_SKILL_DIR/run/remote-sync.testteam.pid")" = "$original_pid" ]
  kill -0 "$original_pid"
}

@test "sync start: replaces stale ownership without signalling a foreign process" {
  local fake_node fake_bin foreign_pid
  fake_node="$(write_fake_node)"
  sleep 30 &
  foreign_pid=$!
  fake_bin="$(write_fake_node_ps_fixture "$fake_node" "$foreign_pid")"
  ENGINE_PIDS="${ENGINE_PIDS:+$ENGINE_PIDS }$foreign_pid"
  printf '%s\n' "$foreign_pid" > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -eq 0 ]
  kill -0 "$foreign_pid"
  remember_engine_pid
  [ "$ENGINE_PID" -ne "$foreign_pid" ]

  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine running, pid $ENGINE_PID)"* ]]
}

@test "disconnect removes stale ownership without signalling a foreign process" {
  sleep 30 &
  local foreign_pid=$!
  ENGINE_PIDS="${ENGINE_PIDS:+$ENGINE_PIDS }$foreign_pid"
  printf '%s\n' "$foreign_pid" > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  run bash "$SCRIPTS/remote.sh" disconnect testteam
  [ "$status" -eq 0 ]
  kill -0 "$foreign_pid"
  [ ! -e "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]
}

@test "concurrent sync start serializes ownership to one engine" {
  local fake_node fake_bin first_out second_out first_status=0 second_status=0
  fake_node="$(write_fake_node)"
  fake_bin="$(write_fake_node_ps_fixture "$fake_node")"
  first_out="$(mktemp)"
  second_out="$(mktemp)"

  env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam >"$first_out" 2>&1 &
  local first_start=$!
  env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam >"$second_out" 2>&1 &
  local second_start=$!
  wait "$first_start" || first_status=$?
  wait "$second_start" || second_status=$?
  [ "$first_status" -eq 0 ]
  [ "$second_status" -eq 0 ]
  [ "$(grep -h -c 'Sync engine started' "$first_out" "$second_out" | awk '{s += $1} END {print s}')" -eq 1 ]
  [ "$(grep -h -c 'Sync engine already running' "$first_out" "$second_out" | awk '{s += $1} END {print s}')" -eq 1 ]

  remember_engine_pid
  kill -0 "$ENGINE_PID"
  rm -f "$first_out" "$second_out"
}

@test "sync start reaps a ready-timeout child before releasing ownership" {
  local fake_node="$TEST_SKILL_DIR/fake-node-timeout" fake_bin lock
  printf '%s\n' '#!/usr/bin/env bash' \
    'trap "" TERM' \
    'while :; do sleep 1; done' > "$fake_node"
  chmod +x "$fake_node"
  fake_bin="$(write_fake_node_ps_fixture "$fake_node")"

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" \
    bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not become ready"* ]]
  [ ! -e "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]
  lock="$TEST_SKILL_DIR/teams/testteam/.config.lock"
  [ ! -d "$lock" ]
}

@test "sync start: rejects a team whose binding is not active" {
  local cfg="$TEST_SKILL_DIR/teams/testteam/config.json" escaped updated
  escaped="$(sed "s/'/''/g" "$cfg")"
  updated="$(sqlite_mem \
    "SELECT json_set('$escaped', '\$.remote_binding.disconnected_at', '2026-07-30T01:00:00Z');")"
  printf '%s\n' "$updated" > "$cfg"

  run bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"team 'testteam' is disconnected"* ]]
  [ ! -e "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]
}
