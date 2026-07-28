#!/usr/bin/env bash
# migrate-per-team.sh — copy each team's rows out of the pre-split shared store
# into its own store at <storage>/teams/<team>/messages.db.
#
# Runs from install.sh after init-db.sh, so it happens once per update and
# before anything writes through the new resolver. Safe to run again: a team
# that already has a store is reported and left alone.
#
# It COPIES. The shared store is never modified and never deleted, so a
# migration that goes wrong costs nothing but the disk the duplicate uses —
# delete the per-team store and run this again. Reclaiming the old file is a
# separate, later decision that wants confidence this one does not.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/validate.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../drivers/storage/sqlite.sh"

SHARED="$(_agmsg_runtime_db_path)"
[ -f "$SHARED" ] || { echo "per-team migration: no pre-split store, nothing to do"; exit 0; }

# Which of the source tables exist decides what can be copied at all. A store
# from before the event log has only `messages`; a newer one also has `events`,
# `read_cursors` and `storage_metadata`. Referencing a missing table would abort
# the batch, so the statement list is built from what is actually there.
src_tables="$(agmsg_sqlite "$SHARED" \
  "SELECT name FROM sqlite_master WHERE type='table';" 2>/dev/null || true)"
has_table() { printf '%s\n' "$src_tables" | grep -qx "$1"; }

has_table messages || has_table events || {
  echo "per-team migration: pre-split store holds no message tables, nothing to do"
  exit 0
}

# The set of teams to migrate is taken from the rows themselves, not from
# teams/<name>/ — a team whose config was removed still owns its history, and
# leaving those rows behind would look exactly like data loss.
teams_sql="SELECT DISTINCT team FROM messages WHERE team IS NOT NULL"
if has_table events; then
  teams_sql="$teams_sql UNION SELECT DISTINCT team FROM events WHERE team IS NOT NULL"
fi
if ! has_table messages; then
  teams_sql="SELECT DISTINCT team FROM events WHERE team IS NOT NULL"
fi

migrated=0; skipped_existing=0; rejected=0; total_rows=0

while IFS= read -r team; do
  [ -n "$team" ] || continue

  # A team name reaches the filesystem as a directory here. Stores predating
  # the name validation (#140) can hold names that cannot be one — a project
  # path was found in a real store, complete with separators. Such a team is
  # reported, not guessed at and not silently dropped: its rows stay readable
  # in the shared store, which this never deletes.
  if ! agmsg_validate_team_name "$team" >/dev/null 2>&1; then
    echo "per-team migration: SKIPPED team with a name that cannot be a directory: '$team'"
    rejected=$((rejected + 1))
    continue
  fi

  dest="$(agmsg_db_path "$team")"
  if [ -f "$dest" ]; then
    # Never merge into a store that already exists. Its rows carry their own
    # seq/id values, and copying the shared ones on top would either collide or
    # be silently ignored — losing history in the case that looks like success.
    echo "per-team migration: SKIPPED '$team' — a store already exists at $dest"
    skipped_existing=$((skipped_existing + 1))
    continue
  fi

  # Create the schema, then clear the read-cursor marker that a first init
  # writes on an empty store. The copy below brings the source's own
  # storage_metadata with it, so the marker ends up reflecting the SOURCE:
  # a pre-cursor store arrives without it and the second init runs phase-3
  # adoption over the copied rows exactly as it would have in place, while a
  # store that already had cursors keeps them untouched.
  storage_init "$team" >/dev/null
  agmsg_sqlite "$dest" "DELETE FROM storage_metadata WHERE key='read_cursor_v1';" >/dev/null

  src_lit="$(agmsg_sql_readfile_path "$SHARED")"
  team_lit="$(agmsg_sqlesc "$team")"

  # seq and id are copied verbatim rather than reassigned. read_cursors record
  # positions in the events.seq space, so renumbering would silently move every
  # cursor; preserving them keeps a copied cursor pointing where it did.
  copy="BEGIN;"
  if has_table events; then
    copy="$copy
      INSERT OR IGNORE INTO events(seq,type,id,team,from_agent,to_agent,body,msg_id,agent,at)
        SELECT seq,type,id,team,from_agent,to_agent,body,msg_id,agent,at
          FROM src.events WHERE team='$team_lit';"
  fi
  if has_table messages; then
    copy="$copy
      INSERT OR IGNORE INTO messages(id,team,from_agent,to_agent,body,created_at,read_at)
        SELECT id,team,from_agent,to_agent,body,created_at,read_at
          FROM src.messages WHERE team='$team_lit';"
  fi
  if has_table read_cursors; then
    copy="$copy
      INSERT OR IGNORE INTO read_cursors(team,agent,local_position)
        SELECT team,agent,local_position
          FROM src.read_cursors WHERE team='$team_lit';"
  fi
  if has_table storage_metadata; then
    copy="$copy
      INSERT OR IGNORE INTO storage_metadata(key,value) SELECT key,value FROM src.storage_metadata;"
  fi
  copy="$copy
    COMMIT;"

  printf '%s\n' "ATTACH DATABASE '$src_lit' AS src;
$copy" | agmsg_sqlite "$dest" >/dev/null

  # Count what was copied BEFORE re-running init. Phase-3 adoption writes one
  # message_read event per legacy row, so a count taken afterwards reports
  # roughly double and reads as if the copy had duplicated the history.
  rows="$(agmsg_sqlite "$dest" \
    "SELECT (SELECT COUNT(*) FROM messages) + (SELECT COUNT(*) FROM events);")"

  # Re-run init so phase-3 adoption sees the copied rows.
  storage_init "$team" >/dev/null

  echo "per-team migration: '$team' -> $dest ($rows rows copied)"
  migrated=$((migrated + 1))
  total_rows=$((total_rows + rows))
done <<EOF
$(agmsg_sqlite "$SHARED" "$teams_sql;")
EOF

echo "per-team migration: $migrated team(s), $total_rows row(s) copied; \
$skipped_existing already had a store, $rejected could not be named as a directory"
if [ "$rejected" -gt 0 ]; then
  echo "per-team migration: rows for the skipped team(s) remain in $SHARED and are not lost"
fi
