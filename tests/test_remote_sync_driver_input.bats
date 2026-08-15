#!/usr/bin/env bats

# The staged-input path, run where it actually matters (#817).
#
# The change these cover exists FOR Windows: the roster driver is handed its
# input as an open file descriptor instead of a pipe, so that nothing is ever in
# a position to SIGKILL a driver that holds the registry lock. Two of the things
# it rests on behave differently on Windows than anywhere else -- Node hands an
# ordinary descriptor to Git Bash as stdin, and Windows cannot unlink a file
# that is still open, so the temp directory is removed on a different route.
#
# `tests/test_remote_sync_engine.bats` runs on ubuntu and macos only. Without
# this file the Windows half of a Windows fix would be argued rather than run.
#
# The name carries `driver-input` because the Windows matrix leg selects by
# `bats --filter`.

@test "driver-input: the staged input arrives whole and leaves nothing behind" {
  run node --test \
    --test-name-pattern 'whole input, from the start|leaves nothing behind' \
    "$BATS_TEST_DIRNAME/remote_sync_engine.test.mjs"
  [ "$status" -eq 0 ]
  # A pattern that selects nothing exits 0 with nothing run, which is precisely
  # the shape of a leg that looks green because it never happened. So the count
  # is asserted, not just the status: two tests, both of them passing.
  echo "$output" | grep -qE '(^|[^0-9])tests 2([^0-9]|$)'
  echo "$output" | grep -qE '(^|[^0-9])pass 2([^0-9]|$)'
  echo "$output" | grep -qE '(^|[^0-9])fail 0([^0-9]|$)'
}
