#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
}

teardown() { teardown_test_env; }

require_age() {
  if [ -n "${AGMSG_AGE_BIN:-}" ]; then
    [ -x "$AGMSG_AGE_BIN" ] || skip "AGMSG_AGE_BIN is not executable"
  elif ! command -v age >/dev/null 2>&1; then
    skip "standard age CLI is not installed"
  fi
}

@test "age-v1 shared contract vectors" {
  require_age
  run node --test "$BATS_TEST_DIRNAME/sync_cipher.test.mjs"
  [ "$status" -eq 0 ]
}

@test "sqlite prepare publishes one byte-stable age-v1 envelope" {
  require_age
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  export AGMSG_STORAGE_DRIVER=sqlite
  export AGMSG_SYNC_NODE_BIN=node
  export AGMSG_SYNC_CIPHER_HELPER="$SCRIPTS/internal/sync-cipher.mjs"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init >/dev/null
  storage_send demo alice bob "encrypted at the durability boundary" >/dev/null
  local recipient prepare first second
  recipient=$(jq -r '.recipient_sets.team_a.recipient' \
    "$BATS_TEST_DIRNAME/../docs/spec/vectors/age-v1-vectors.json")
  prepare=$(jq -nc --arg recipient "$recipient" '
    {type:"sync_prepare",envelope_v:1,cipher:"age-v1",key_id:"epoch-1",
     recipients:[$recipient],max_blob_bytes:1048576,allow_new:true}')
  first=$(printf '%s\n' "$prepare" | storage_sync_prepare_push demo \
    018f3f7e-0000-7000-8000-000000000000 \
    018f3f7e-0000-7000-8000-000000000001 1 100)
  second=$(printf '%s\n' "$prepare" | storage_sync_prepare_push demo \
    018f3f7e-0000-7000-8000-000000000000 \
    018f3f7e-0000-7000-8000-000000000001 1 100)
  [ "$first" = "$second" ]
  printf '%s\n' "$first" | jq -e 'select(.type=="sync_push_candidate")
    | .envelope.v==1 and .envelope.cipher=="age-v1"
      and .envelope.key_id=="epoch-1" and (.envelope.blob|length)>0' >/dev/null
}

@test "concurrent age-v1 sealers publish one transaction winner" {
  require_age
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  export AGMSG_STORAGE_DRIVER=sqlite
  export AGMSG_SYNC_NODE_BIN=node
  export AGMSG_SYNC_CIPHER_HELPER="$SCRIPTS/internal/sync-cipher.mjs"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init >/dev/null
  storage_send demo alice bob "one published ciphertext" >/dev/null
  local recipient prepare first_file second_file first_pid second_pid
  recipient=$(jq -r '.recipient_sets.team_a.recipient' \
    "$BATS_TEST_DIRNAME/../docs/spec/vectors/age-v1-vectors.json")
  prepare=$(jq -nc --arg recipient "$recipient" '
    {type:"sync_prepare",envelope_v:1,cipher:"age-v1",key_id:"epoch-1",
     recipients:[$recipient],max_blob_bytes:1048576,allow_new:true}')
  first_file="$BATS_TEST_TMPDIR/first.jsonl"
  second_file="$BATS_TEST_TMPDIR/second.jsonl"
  (printf '%s\n' "$prepare" | storage_sync_prepare_push demo \
    018f3f7e-0000-7000-8000-000000000000 \
    018f3f7e-0000-7000-8000-000000000001 1 100 >"$first_file") 3>&- 4>&- &
  first_pid=$!
  (printf '%s\n' "$prepare" | storage_sync_prepare_push demo \
    018f3f7e-0000-7000-8000-000000000000 \
    018f3f7e-0000-7000-8000-000000000001 1 100 >"$second_file") 3>&- 4>&- &
  second_pid=$!
  wait "$first_pid"
  wait "$second_pid"
  [ "$(cat "$first_file")" = "$(cat "$second_file")" ]
  [ "$(agmsg_sqlite "$(agmsg_db_path)" "SELECT COUNT(*) FROM sync_messages;" | tr -d '\r')" -eq 1 ]
}
