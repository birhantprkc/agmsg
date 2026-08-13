# Start a connected team's sync engine when an agent turns up (#774).
#
# A machine restart leaves every sync engine dead and nothing restarts one. The
# agent keeps working, `send` keeps committing locally, and nothing reaches the
# other machines until a person happens to type `remote sync start`. #765 made
# that visible; a warning still asks a person to do what the machine can do.
#
# Sourced by the two places an agent establishes what it is:
#   scripts/session-start.sh   — where the monitor is started
#   scripts/actas-claim.sh     — where a session takes on a role, and a team
#
# ONE ENGINE PER (MACHINE, TEAM) IS NOT ENFORCED HERE, AND MUST NOT BE.
#
# `cmd_sync_start` already takes `agmsg_lock_acquire "$TEAMS_DIR/<team>"`, and
# under that lock it answers `Sync engine already running (pid N).` and returns
# 0. The pidfile is per team. So the invariant holds by construction in the
# command, and this calls the command.
#
# The alternative — checking the pidfile here and starting only when it looks
# dead — puts a SECOND answer to "is it running?" in the tree, outside the lock
# that makes the first one true. Two answers to that question diverge exactly
# when several sessions open at once, which is the case this exists for: they
# race for the lock, one starts the engine, the rest are told `already running`
# and carry on. That behaviour is the command's, and it is inherited rather than
# reproduced.
#
# THE BINDING CHECK IS INHERITED TOO. `cmd_sync_start` refuses a team with no
# active binding and a disconnected team, by name, before it starts anything.
# Filtering on the binding here would be the same duplication one level up.
#
# NOTHING HERE MAY FAIL A SESSION. An agent that will not open because a sync
# engine refused is worse than a sync engine that is down, so every path returns
# 0 and the worst outcome is a line of text.

# Usage: agmsg_sync_autostart <remote.sh path> <team>...
#
# Prints, at most, one block: the teams whose engines this call started, and the
# teams it could not start. A team whose engine was already running produces no
# output at all — starting is a side effect the person did not ask for in this
# moment, and "nothing changed" is not news.
agmsg_sync_autostart() {
  local remote_sh="$1"; shift
  [ -x "$remote_sh" ] || return 0
  [ $# -gt 0 ] || return 0

  local team out rc started="" failed=""
  for team in "$@"; do
    [ -n "$team" ] || continue
    # stderr folded in: `cmd_sync_start` says why it refused on stderr, and that
    # sentence is the useful half of a failure. Swallowing it would leave this
    # printing "could not start" with the reason on the floor.
    out="$("$remote_sh" sync start "$team" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'already running'; then
      continue
    fi
    if [ "$rc" -eq 0 ]; then
      started="$started$team"$'\n'
      continue
    fi
    # The team name AND what the command said. A bare "could not start <team>"
    # sends the reader to a log to find a sentence this already had.
    failed="$failed$team	$(printf '%s' "$out" | tr '\n' ' ')"$'\n'
  done

  if [ -n "$started" ]; then
    # Written as a loop rather than a joined string: a team name may contain
    # characters that make a one-line join ambiguous, and one line per team is
    # what the #765 block already established as this hook's voice.
    printf '%s\n' 'AGMSG: no sync engine was running; started one for:'
    printf '%s' "$started" | while IFS= read -r t; do
      [ -n "$t" ] || continue
      printf '  %s\n' "$t"
    done
    printf '\n'
  fi

  if [ -n "$failed" ]; then
    printf '%s\n' 'AGMSG: connected, but not syncing.' ''
    printf '%s\n' \
      'No sync engine is running for the team(s) below and starting one failed,' \
      'so messages from other machines are not arriving. The session continues.' ''
    printf '%s' "$failed" | while IFS=$'\t' read -r t reason; do
      [ -n "$t" ] || continue
      printf '  %s: %s\n' "$t" "$reason"
      # The runnable line, unchanged from #765: the remedy is still a person
      # running the command, and now they also know it has been tried.
      printf '    bash %q sync start %q\n' "$remote_sh" "$t"
    done
    printf '\n'
  fi

  return 0
}
