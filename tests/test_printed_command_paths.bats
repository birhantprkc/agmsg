#!/usr/bin/env bats

# A printed command is one someone pastes (#667).
#
# `key.sh` and `remote.sh` are not on PATH — they live inside the install
# directory, whose name is chosen at install time — so a printed `key.sh show
# ...` cannot be run as printed, and on a machine with more than one install
# the reader cannot guess which one printed it.
#
# The heaviest instance was the key-backup notice: it sits directly under
# "losing this key makes every message permanently unreadable" as the only
# offered way to prevent that, and it produced `command not found`.
#
# These assert the printed line names a path that EXISTS, not that it contains
# some spelling. A line naming the wrong directory would satisfy a substring
# check and still not run.
#
# `[ ]` rather than `[[ ]]` throughout, deliberately: on bash 3.2 — which is
# what the macOS shards run — a failing `[[ ]]` does not trip errexit unless it
# is the body's last statement, so `[[ ]]` assertions in the middle of a test
# are enforced on ubuntu only (#670). Substring checks go through `grep -q`,
# which does trip it.

load test_helper

setup() {
  setup_test_env
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a
}

teardown() {
  teardown_test_env
}

skip_if_no_age() {
  command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 || skip "age/age-keygen not installed"
}

# The first path inside a printed `bash '<path>' ...` line naming <script>.
printed_path() {
  printf '%s\n' "$output" | sed -n "s/.*bash '\([^']*$1\)'.*/\1/p" | head -1
}

@test "printed commands: the key-backup notice names a key.sh that exists" {
  skip_if_no_age
  run bash "$SCRIPTS/key.sh" generate testteam
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'Back this up now'
  path="$(printed_path 'key\.sh')"
  # Non-empty first: an empty path would make every check below vacuous, and
  # "no printed command at all" is the state this issue was about.
  [ -n "$path" ]
  [ -f "$path" ]
}

@test "printed commands: that notice is still the --reveal-secret route" {
  # Paired with the test above. A path pointing at a real file proves nothing
  # if the subcommand stopped being the one that shows the secret.
  skip_if_no_age
  run bash "$SCRIPTS/key.sh" generate testteam
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -- "--reveal-secret"
}

@test "printed commands: 'no key yet' names both routes with a path" {
  run bash "$SCRIPTS/key.sh" show testteam
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'has no key yet'
  # Both offered commands, each with a path that exists. Counted rather than
  # matched once: the message offers generate AND import, and a fix that
  # repaired only the first would pass a single check.
  n="$(printf '%s\n' "$output" | grep -c "bash '$SCRIPTS/key.sh' ")"
  [ "$n" -eq 2 ]
}

@test "printed commands: 'already has a key' names a key.sh that exists" {
  skip_if_no_age
  run bash "$SCRIPTS/key.sh" generate testteam
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/key.sh" generate testteam
  [ "$status" -ne 0 ]
  path="$(printed_path 'key\.sh')"
  [ -n "$path" ]
  [ -f "$path" ]
}

@test "printed commands: the guidance gate still withholds the backup route" {
  # The path work must not have turned a withheld route into a printed one.
  # A caller that owns the next step gets the FACT and not the command.
  skip_if_no_age
  AGMSG_OPERATOR_GUIDANCE=caller run bash "$SCRIPTS/key.sh" generate testteam
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'permanently unreadable'
  run_output_has_backup=0
  printf '%s\n' "$output" | grep -q 'Back this up now' && run_output_has_backup=1
  [ "$run_output_has_backup" -eq 0 ]
}
