#!/usr/bin/env bats

# The `-b` requirement, and the refusal that carries it (#829).
#
# A native Windows jq prints CRLF, and the trailing CR rides into the two values
# this driver sends -- the message `wire_id` and the base64 envelope `blob` --
# because `read` takes the LF and `IFS` has no CR. `jq -b` is jq's own answer.
#
# The requirement fails closed rather than degrading: this repository checks that
# jq EXISTS and never which jq it is, so a jq without `-b` would exit 2 on every
# call in here anyway. What the refusal buys is the operator reading "this jq
# cannot do binary output" instead of "Stage-1 sync is broken".

load test_helper

setup() { setup_test_env; }
teardown() { teardown_test_env; }

# A jq that works for everything except `-b`, which is what an older jq is.
stub_jq_without_b() {
  local bin="$TEST_SKILL_DIR/jq-no-b"
  mkdir -p "$bin"
  cat > "$bin/jq" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    -b|-b*|--binary) echo "jq: Unknown option $a" >&2; exit 2 ;;
  esac
done
exec /usr/bin/env -i PATH="$REAL_PATH" jq "$@"
STUB
  chmod +x "$bin/jq"
  printf '%s' "$bin"
}

@test "sync: a jq without -b is refused by name, not left to fail later (#829)" {
  local bin; bin="$(stub_jq_without_b)"

  run env REAL_PATH="$PATH" PATH="$bin:$PATH" bash -c '
    . "$1/drivers/storage/sqlite-sync.sh"
    _sqlite_sync_require_jq_binary
  ' _ "$SCRIPTS"

  [ "$status" -ne 0 ]
  # NAMED. The point of failing closed is the sentence, so the sentence is what
  # is asserted -- not merely that something went wrong.
  echo "$output" | grep -q 'requires a jq that supports -b'
  echo "$output" | grep -q 'CRLF'
}

@test "sync: a jq WITH -b is accepted, so the refusal is not unconditional (#829)" {
  # The negative control. Without it, the case above is satisfied by a probe
  # that refuses every jq.
  run bash -c '
    . "$1/drivers/storage/sqlite-sync.sh"
    _sqlite_sync_require_jq_binary
  ' _ "$SCRIPTS"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sync: the driver's own entry refuses too, so the check is wired (#829)" {
  # THE PROBE BEING RIGHT IS NOT THE PROBE BEING CALLED.
  #
  # The two cases above drive `_sqlite_sync_require_jq_binary` directly, so they
  # hold even if nothing in the driver ever calls it -- measured: removing the
  # call from `_sqlite_sync_schema` reddens neither. This one goes in through the
  # entry that gates the driver, so the wiring is what fails when the wiring is
  # what breaks.
  local bin; bin="$(stub_jq_without_b)"

  run env REAL_PATH="$PATH" PATH="$bin:$PATH" bash -c '
    . "$1/lib/storage.sh" 2>/dev/null || true
    . "$1/drivers/storage/sqlite-sync.sh"
    _sqlite_sync_schema testteam
  ' _ "$SCRIPTS"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'requires a jq that supports -b'
}
