#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" testteam bob claude-code /tmp/project-a
  BARRIER="$TEST_SKILL_DIR/mark-barrier"
}

teardown() {
  teardown_test_env
}

# Counts unread via the storage facade (send.sh now writes the event log, not
# the legacy messages table's read_at column — a raw "read_at IS NULL" count
# would silently always read 0 post-flip and never catch a real regression).
unread_count() {
  bash -c '
    source "'"$SCRIPTS"'/lib/storage.sh"
    agmsg_storage_load
    storage_list_unread testteam "$1"
  ' _ "$1" | grep -c .
}

# Wait until the script under test has displayed and is paused before its
# mark UPDATE (barrier .reached appears), with a bounded wait.
await_barrier_reached() {
  for _ in $(seq 1 100); do
    [ -e "$BARRIER.reached" ] && return 0
    sleep 0.05
  done
  return 1
}

# --- inbox.sh -----------------------------------------------------------

@test "inbox: displays unread messages and marks exactly those as read" {
  bash "$SCRIPTS/send.sh" testteam bob alice "first"
  bash "$SCRIPTS/send.sh" testteam bob alice "second"
  run bash "$SCRIPTS/inbox.sh" testteam alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 new message(s):"* ]]
  [[ "$output" == *"first"* ]]
  [[ "$output" == *"second"* ]]
  [ "$(unread_count alice)" -eq 0 ]
}

@test "inbox: --quiet is silent when there is nothing unread" {
  run bash "$SCRIPTS/inbox.sh" testteam alice --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "inbox: a message arriving between display and mark is NOT marked read unseen" {
  bash "$SCRIPTS/send.sh" testteam bob alice "early"
  # Pause the run between display and mark, land a message inside the window,
  # then release. With the old blanket "WHERE read_at IS NULL" mark, the late
  # message was silently marked read without ever having been displayed.
  AGMSG_TEST_MARK_BARRIER="$BARRIER" bash "$SCRIPTS/inbox.sh" testteam alice \
    </dev/null > "$TEST_SKILL_DIR/first-run.out" 3>&- &
  bg_pid=$!
  await_barrier_reached
  bash "$SCRIPTS/send.sh" testteam bob alice "late"
  : > "$BARRIER.release"
  wait "$bg_pid"
  run cat "$TEST_SKILL_DIR/first-run.out"
  [[ "$output" == *"early"* ]]
  [[ "$output" != *"late"* ]]
  # The late message must still be unread…
  [ "$(unread_count alice)" -eq 1 ]
  # …and surface on the next check
  run bash "$SCRIPTS/inbox.sh" testteam alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"late"* ]]
  [ "$(unread_count alice)" -eq 0 ]
}


# Make ONE team's store unreadable without touching any other team's.
#
# Teams share a single store until they are partitioned, so corrupting the file
# a team resolves to by default breaks every team at once -- and then the FIRST
# team fails, which is the harmless case, not the one under test. Switching this
# team to its own partition first is what makes the failure land where the
# defect needs it: after an earlier team has already been marked read.
_break_only_this_teams_store() {
  local team="$1" cfg="$TEST_SKILL_DIR/teams/$1/config.json" updated db
  updated="$(sqlite_mem "SELECT json_set(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.drivers.partition', 'per-team');")"
  printf '%s' "$updated" > "$cfg"
  db="$(cd "$TEST_SKILL_DIR" && bash -c '. scripts/lib/storage.sh; agmsg_storage_load; agmsg_db_path '"$team" 2>/dev/null)"
  [ -n "$db" ] || return 1
  mkdir -p "$(dirname "$db")"
  printf 'not a database' > "$db"
}

# --- check-inbox.sh ------------------------------------------------------

# What the hook runtimes actually do with a Stop-hook run, applied to a real
# invocation of check-inbox.sh.
#
# The contract is theirs, not ours: stdout is read as control JSON only when
# the process exits 0. A non-zero exit is logged as a hook failure and the
# output is DISCARDED. Asserting on the shell's stdout alone cannot see that —
# and the first version of this fix emitted the messages and then exited
# non-zero, so it was inert on the only path that was broken while its tests
# passed.
#
# Prints what the operator would actually receive, or nothing.
delivered_to_operator() {
  local out status
  out="$(bash "$SCRIPTS/check-inbox.sh" claude-code /tmp/project-a </dev/null 2>/dev/null)" && status=0 || status=$?
  # The runtime's rule, in one line.
  [ "$status" -eq 0 ] || return 0
  printf '%s' "$out"
}

@test "check-inbox: a later team's failure still DELIVERS the earlier team's messages (#637)" {
  # Marking happens inside the loop; emitting happens after it. A failure on a
  # later team lands after an earlier team's rows were stamped read_at — so
  # whatever this run fails to deliver is lost for good.
  #
  # Measured through the runtime's rule, not the shell's stdout: the point is
  # that the message REACHES someone, and an exit code that discards the
  # payload does not achieve that however well-formed the payload is.
  bash "$SCRIPTS/join.sh" zzlastteam alice claude-code /tmp/project-a >/dev/null
  bash "$SCRIPTS/send.sh" testteam bob alice "first team message" >/dev/null
  _break_only_this_teams_store zzlastteam

  run delivered_to_operator
  [[ "$output" == *"first team message"* ]]
  # And the operator is told the poll was partial, so a short answer is not
  # read as a complete one.
  [[ "$output" == *"stopped early"* ]]
  [[ "$output" == *"zzlastteam"* ]]
}

@test "check-inbox: a failure with nothing accumulated does not report 'no new messages' (#637)" {
  # The other half. With nothing to deliver there is no payload to protect, so
  # the status is free to carry the failure — and it must, because claiming
  # "no new messages" states something this run never established.
  bash "$SCRIPTS/join.sh" zzlastteam alice claude-code /tmp/project-a >/dev/null
  _break_only_this_teams_store zzlastteam

  run bash "$SCRIPTS/check-inbox.sh" claude-code /tmp/project-a </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" != *"no new messages"* ]]
}

@test "check-inbox: a message arriving between display and mark is NOT marked read unseen" {
  bash "$SCRIPTS/send.sh" testteam bob alice "early"
  AGMSG_TEST_MARK_BARRIER="$BARRIER" bash "$SCRIPTS/check-inbox.sh" claude-code /tmp/project-a \
    </dev/null > "$TEST_SKILL_DIR/check-run.out" 2>/dev/null 3>&- &
  bg_pid=$!
  await_barrier_reached
  bash "$SCRIPTS/send.sh" testteam bob alice "late"
  : > "$BARRIER.release"
  wait "$bg_pid" || true
  run cat "$TEST_SKILL_DIR/check-run.out"
  [[ "$output" == *"early"* ]]
  [[ "$output" != *"late"* ]]
  # The late message was not silently marked read by the first run
  [ "$(unread_count alice)" -eq 1 ]
}
