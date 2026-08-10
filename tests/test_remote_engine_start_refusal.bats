#!/usr/bin/env bats

# What a sync engine that cannot start is allowed to leave behind (#730).
#
# It used to leave nothing: no message, no exit code the operator saw, and a
# claim from the caller that the engine was running. `_remote_sync_engine_start`
# ended in `disown … || true`, so it always returned 0; the one caller that
# checked used `if ! …`, where `set -e` is suspended, so a failed pidfile write
# was stepped over and the command died later at `cat "$pidfile"` with nothing
# printed. Measured on a codex-like sandbox shape: the run dir was not writable,
# and `sync start` exited without a word of its own.
#
# These tests pin the three things that has to produce instead: a non-zero exit,
# a message naming the path and the way out, and NO half-started engine.

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
}

teardown() {
  # Restore before the harness removes the tree, or the unwritable dir defeats
  # its own cleanup.
  chmod u+w "$TEST_SKILL_DIR/run" 2>/dev/null || true
  chmod u+w "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" 2>/dev/null || true
  chmod u+w "$TEST_SKILL_DIR" 2>/dev/null || true
  # The control case starts a real engine. cmd_sync_start reaps it when it does
  # not become ready, but a test file about leaked engines should not be the one
  # leaking them if that reap ever stops working.
  local pidfile="$TEST_SKILL_DIR/run/remote-sync.testteam.pid" pid=""
  [ -f "$pidfile" ] && pid="$(cat "$pidfile" 2>/dev/null || true)"
  # 0 and 1 are never ours: `kill 0` signals the whole process group (measured:
  # it killed the bats run) and 1 is init.
  case "$pid" in
    ''|*[!0-9]*|0|1) ;;
    *) kill "$pid" 2>/dev/null || true ;;
  esac
  teardown_test_env
}

# Refuse to run as root: chmod is the whole mechanism here and root ignores it,
# so the tests would pass without ever reaching the branch they are about.
skip_if_root() {
  [ "$(id -u)" -ne 0 ] || skip "chmod does not restrict root, so the refusal path is unreachable"
}

@test "sync start: an unwritable run dir is refused out loud, not in silence (#730)" {
  skip_if_root
  chmod a-w "$TEST_SKILL_DIR/run"

  run bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -ne 0 ]
  # The path, so the operator knows what to fix rather than what to suspect.
  grep -qF "remote-sync.testteam.pid" <<<"$output"
  # What is not happening, in the operator's terms rather than the engine's.
  grep -qF "Nothing is syncing for this team" <<<"$output"
  # And the way back. A refusal that names no next step leaves the operator to
  # invent one, which is how a tunnel got invented for #717.
  grep -qF "remote.sh sync start" <<<"$output"
}

@test "sync start: the refusal leaves no engine and no pidfile behind (#730)" {
  skip_if_root
  chmod a-w "$TEST_SKILL_DIR/run"

  run bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -ne 0 ]
  # Companion, not the discriminator: the broken form ALSO leaves no pidfile —
  # that is exactly what its failed write produces. Measured against the
  # original body, this assertion stays green. It is here so a future change
  # cannot start writing a pidfile for a start that was refused; the test below
  # is the one that separates "refused" from "orphaned".
  refute test -f "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
}

# NOT COVERED, deliberately: "a refused start leaves no engine process".
#
# Proving the orphan-prevention half needs an input where the broken code
# spawns and then fails to record the pid. Two were tried and neither reaches
# it. Making the run dir unwritable kills the child at its own log redirection
# (`>> run/remote-sync.<team>.log`) before node starts. Making only the pidfile
# read-only lets the spawn happen, but the test could not observe a surviving
# engine either -- both were measured green against the original function body,
# which is the definition of a test that does not test its subject.
#
# So the guard that proves writability BEFORE the spawn is in the code without
# a test that would notice its removal. Said here rather than left implicit:
# the other four tests below and above cover the audible-failure half only.

@test "sync start: the command the refusal prints is the command that works (#730)" {
  skip_if_root
  # Not "the refusal mentions a real command" -- that is satisfied by any real
  # command. The remedy is LIFTED OUT of the refusal and run, so the two cannot
  # drift apart: change the printed string alone and this fails on whatever it
  # now prints. A printed route has to be run, not read.
  printf '%s\n' 2147483647 > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
  chmod a-w "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  run bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -ne 0 ]

  # Captured before the next `run`, which overwrites $output.
  local remedy
  remedy="$(grep -oE 'remote\.sh [a-z].*' <<<"$output" | tail -1)"
  [ -n "$remedy" ]
  # Only the arguments are lifted: the leading path is whatever the operator's
  # install puts there, and the test has its own.
  local args="${remedy#remote.sh }"

  chmod u+w "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
  rm -f "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  # Run through a shell, not by word-splitting. The remedy is written for a
  # person to paste into one, so the team name arrives shell-quoted by
  # agmsg_shq; splitting it here passes the quotes through as characters and the
  # command fails on a team literally named "'testteam'" -- measured, that is
  # what the first version of this test did. A printed route has to be run the
  # way it is meant to be run.
  run bash -c "bash '$SCRIPTS/remote.sh' $args"
  # "not refused" is not enough: a remedy that no longer parses is answered with
  # a usage line, which is also not a refusal. Measured -- changing only the
  # printed verb (start -> begin) left this test green until the two assertions
  # below were added. What has to be true is that the lifted command REACHED the
  # engine-start path, so it must say what became of the engine.
  refute grep -q "^Usage:" <<<"$output"
  grep -qE "Sync engine (already running|started)|did not become ready" <<<"$output"
}

@test "sync start: a run dir that cannot be created is refused the same way (#730)" {
  skip_if_root
  # The other half. `mkdir -p … || true` tolerated this and left the failure to
  # the unguarded write below it, which could not explain itself.
  rmdir "$TEST_SKILL_DIR/run"
  chmod a-w "$TEST_SKILL_DIR"

  run bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -ne 0 ]
  grep -qF "could not start the sync engine" <<<"$output"
  grep -qF "run" <<<"$output"
}

@test "sync start: a writable run dir still starts an engine (#730)" {
  # The control. Without it, every assertion above is satisfied by a
  # `sync start` that refuses unconditionally.
  run bash "$SCRIPTS/remote.sh" sync start testteam
  # The engine is real here and will fail to reach https://remote.example, so
  # this does not assert success -- only that the refusal above is not what
  # happened, and that the pidfile path was reachable.
  refute grep -qF "Nothing is syncing for this team" <<<"$output"
  refute grep -qF "could not start the sync engine" <<<"$output"
}
