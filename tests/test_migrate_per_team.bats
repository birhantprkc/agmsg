#!/usr/bin/env bats

load test_helper

# setup_test_env runs init-db.sh, which creates the pre-split store with only
# the legacy `messages` table — the exact shape a real upgrading install has.
setup() {
  setup_test_env
  SHARED="$TEST_SKILL_DIR/db/messages.db"
  export SKILL_DIR="$TEST_SKILL_DIR"
}

teardown() { teardown_test_env; }

seed() {
  sqlite3 "$SHARED" \
    "INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('$1','$2','$3','$4');"
}

migrate() { bash "$SCRIPTS/internal/migrate-per-team.sh"; }

store_of() {
  ( # shellcheck disable=SC1091
    source "$SCRIPTS/lib/storage.sh"; agmsg_db_path "$1" )
}

count_in() { sqlite3 "$1" "SELECT COUNT(*) FROM messages;" | tr -d '\r'; }

@test "migrate: each team's rows land in that team's store, and only there" {
  seed alpha ann bob alpha-one
  seed alpha ann bob alpha-two
  seed bravo cid dee bravo-one
  run migrate
  [ "$status" -eq 0 ]

  [ "$(count_in "$(store_of alpha)")" -eq 2 ]
  [ "$(count_in "$(store_of bravo)")" -eq 1 ]
  # Not merely filtered on read — the other team's body is not in the file.
  ! grep -q bravo-one "$(store_of alpha)"
  ! grep -q alpha-one "$(store_of bravo)"
}

@test "migrate: the pre-split store is left intact" {
  seed alpha ann bob keep-me
  migrate
  [ -f "$SHARED" ]
  [ "$(sqlite3 "$SHARED" "SELECT COUNT(*) FROM messages;" | tr -d '\r')" -eq 1 ]
}

@test "migrate: running it again copies nothing and changes nothing" {
  seed alpha ann bob once
  migrate
  local before; before=$(cksum "$(store_of alpha)")
  run migrate
  [ "$status" -eq 0 ]
  [[ "$output" =~ "0 team(s), 0 row(s) copied" ]]
  [ "$(cksum "$(store_of alpha)")" = "$before" ]
}

@test "migrate: history is readable through the normal commands afterwards" {
  bash "$SCRIPTS/join.sh" alpha ann claude-code /tmp/proj-a >/dev/null
  bash "$SCRIPTS/join.sh" alpha bob claude-code /tmp/proj-b >/dev/null
  seed alpha ann bob "from before the split"
  migrate
  run bash "$SCRIPTS/history.sh" alpha bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "from before the split" ]]
}

@test "migrate: a team whose name cannot be a directory is reported, not dropped" {
  # Names like this exist in real stores from before team-name validation
  # (#140). The rows must stay reachable rather than being guessed into a path.
  local bad="/Users/someone/project"
  seed "$bad" ann bob stranded
  seed alpha ann bob fine
  run migrate
  [ "$status" -eq 0 ]
  [[ "$output" =~ "SKIPPED team with a name that cannot be a directory" ]]
  [[ "$output" =~ "1 could not be named as a directory" ]]
  [ "$(count_in "$(store_of alpha)")" -eq 1 ]
  # The row is still where it was, and nothing was written outside the tree.
  [ "$(sqlite3 "$SHARED" "SELECT COUNT(*) FROM messages WHERE team='$bad';" | tr -d '\r')" -eq 1 ]
  [ ! -e "$TEST_SKILL_DIR/db/teams/Users" ]
}

@test "migrate: refuses to merge into a store that already exists" {
  # Merging would collide on the copied seq/id values, and INSERT OR IGNORE
  # would drop them — losing history in the case that looks like success.
  seed alpha ann bob from-shared
  ( # shellcheck disable=SC1091
    source "$SCRIPTS/lib/storage.sh"; agmsg_storage_load
    storage_init alpha >/dev/null
    storage_send alpha ann bob already-here >/dev/null )
  run migrate
  [ "$status" -eq 0 ]
  [[ "$output" =~ "SKIPPED 'alpha' — a store already exists" ]]
  ! grep -q from-shared "$(store_of alpha)"
  [ "$(sqlite3 "$SHARED" "SELECT COUNT(*) FROM messages;" | tr -d '\r')" -eq 1 ]
}

@test "migrate: a store with nothing to move is a no-op, not an error" {
  run migrate
  [ "$status" -eq 0 ]
  [[ "$output" =~ "0 team(s), 0 row(s) copied" ]]
}
