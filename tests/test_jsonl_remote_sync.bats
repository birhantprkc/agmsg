#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  export AGMSG_STORAGE_DRIVER=jsonl
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init >/dev/null
  SERVER_ID=018f3f7e-0000-7000-8000-000000000000
  TEAM_ID=018f3f7e-0000-7000-8000-000000000001
  PREPARE='{"type":"sync_prepare","envelope_v":1,"cipher":"none","key_id":null,"recipients":[],"max_blob_bytes":1048576,"allow_new":true}'
}

teardown() { teardown_test_env; }

prepare_push() {
  printf '%s\n' "$PREPARE" |
    storage_sync_prepare_push demo "$SERVER_ID" "$TEAM_ID" 1 "${1:-100}"
}

candidate_of() { printf '%s\n' "$1" | jq -c 'select(.type=="sync_push_candidate")'; }

@test "jsonl sync advertises Stage-1 only when its runtime seam is available" {
  run storage_describe
  [ "$status" -eq 0 ]
  [[ "$output" == *"capabilities=stage1-sync"* ]]
}

@test "jsonl prepare publishes a byte-stable age-v1 envelope through the cipher seam" {
  local age_bin="${AGMSG_AGE_BIN:-age}"
  command -v "$age_bin" >/dev/null 2>&1 || skip "age CLI is not installed"
  local recipient age_prepare first second
  recipient=$(jq -r '.recipient_sets.team_a.recipient' \
    "$BATS_TEST_DIRNAME/../docs/spec/vectors/age-v1-vectors.json")
  age_prepare=$(jq -nc --arg recipient "$recipient" '
    {type:"sync_prepare",envelope_v:1,cipher:"age-v1",key_id:"epoch-1",
     recipients:[$recipient],max_blob_bytes:1048576,allow_new:true}')
  storage_send demo alice bob encrypted >/dev/null
  first=$(printf '%s\n' "$age_prepare" |
    storage_sync_prepare_push demo "$SERVER_ID" "$TEAM_ID" 1 100)
  second=$(printf '%s\n' "$age_prepare" |
    storage_sync_prepare_push demo "$SERVER_ID" "$TEAM_ID" 1 100)
  [ "$(candidate_of "$first" | jq -c '{local_id,id,envelope}')" = \
    "$(candidate_of "$second" | jq -c '{local_id,id,envelope}')" ]
  candidate_of "$first" | jq -e '
    .envelope.cipher=="age-v1" and .envelope.key_id=="epoch-1" and
    (.envelope.blob|type)=="string" and (.envelope.blob|length)>0' >/dev/null
}

@test "jsonl sync publishes one byte-stable reservation and abandons a pre-commit seal" {
  storage_send demo alice bob stable >/dev/null
  local first second log
  first=$(prepare_push)
  second=$(prepare_push)
  [ "$(candidate_of "$first" | jq -c '{local_position,local_id,id,envelope}')" = \
    "$(candidate_of "$second" | jq -c '{local_position,local_id,id,envelope}')" ]

  storage_send demo alice bob crash-before-publish >/dev/null
  export AGMSG_SYNC_TEST_ABORT_AFTER_SEAL=1
  run prepare_push
  [ "$status" -eq 75 ]
  unset AGMSG_SYNC_TEST_ABORT_AFTER_SEAL
  log="$(dirname "$(agmsg_db_path)")/events.jsonl"
  [ "$(jq -s '[.[]|select(.type=="sync_prepare_commit")|.reservations[]|
    select(.local_id as $id | $id != null)]|length' "$log")" -eq 1 ]
  run prepare_push
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -s '[.[]|select(.type=="sync_push_candidate")]|length')" -eq 2 ]
}

@test "jsonl sync rejects duplicate-key input and journal records before mutation" {
  storage_send demo alice bob strict >/dev/null
  local log input; log="$(dirname "$(agmsg_db_path)")/events.jsonl"
  input="$BATS_TEST_TMPDIR/duplicate-input.jsonl"
  printf '%s\n' '{"type":"sync_prepare","envelope_v":1,"cipher":"none","key_id":null,"recipients":[],"max_blob_bytes":1048576,"allow_new":true,"allow_new":false}' > "$input"
  run storage_sync_prepare_push demo "$SERVER_ID" "$TEAM_ID" 1 100 < "$input"
  [ "$status" -ne 0 ]
  [ "$(jq -s '[.[]|select(.type|startswith("sync_"))]|length' "$log")" -eq 0 ]

  printf '%s\n' '{"type":"sync_generation","generation":"550e8400-e29b-41d4-a716-446655440000","generation":"550e8400-e29b-41d4-a716-446655440001"}' >> "$log"
  run prepare_push
  [ "$status" -ne 0 ]
  [ "$(grep -c '"type":"sync_prepare_commit"' "$log" || true)" -eq 0 ]
}

@test "jsonl reconcile advances only an acknowledged contiguous byte-offset prefix" {
  storage_send demo alice bob one >/dev/null
  storage_send demo alice bob two >/dev/null
  storage_send demo alice bob three >/dev/null
  local prepared first later result last_position
  prepared=$(prepare_push 3)
  first=$(printf '%s\n' "$prepared" | jq -c 'select(.type=="sync_push_candidate")' | sed -n '1p')
  later=$(printf '%s\n' "$prepared" | jq -cs '
    [ .[] | select(.type=="sync_push_candidate") ][1:]
    | to_entries[]
    | {type:"sync_push_ack",local_position:.value.local_position,id:.value.id,
       server_seq:((.key + 2)|tostring),disposition:"stored"}')
  result=$(printf '%s\n' "$later" |
    storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -r '.push_cursor')" = 0 ]
  result=$(printf '%s\n' "$first" | jq -c '
    {type:"sync_push_ack",local_position,id,server_seq:"1",disposition:"stored"}' |
    storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1)
  last_position=$(printf '%s\n' "$prepared" |
    jq -r 'select(.type=="sync_push_candidate")|.local_position' | tail -n 1)
  [ "$(printf '%s\n' "$result" | jq -r '.push_cursor')" = "$last_position" ]
}

@test "jsonl pull atomically reconciles echo, imports once, and projects normal local views" {
  storage_send demo alice bob outgoing >/dev/null
  local prepared candidate ack echo remote page result log
  prepared=$(prepare_push); candidate=$(candidate_of "$prepared")
  ack=$(printf '%s\n' "$candidate" | jq -c '
    {type:"sync_push_ack",local_position,id,server_seq:"1",disposition:"stored"}')
  printf '%s\n' "$ack" |
    storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  echo=$(printf '%s\n' "$candidate" | jq -c '
    {type:"sync_pull_message",server_seq:"1",id,envelope,
     server_received_at:"2026-07-22T11:00:00.000000Z",status:"importable",
     policy_revision:"0",local_security_revision:"0",
     projection:{body:"outgoing",created_at:"2026-07-22T11:00:00.000000Z",
                 from_agent:"alice",to_agent:"bob"}}')
  remote=$(jq -nc '{type:"sync_pull_message",server_seq:"2",
    id:"550e8400-e29b-41d4-a716-446655440000",
    server_received_at:"2026-07-22T11:00:01.000000Z",
    envelope:{v:1,cipher:"none",key_id:null,blob:"e30="},status:"importable",
    policy_revision:"0",local_security_revision:"0",
    projection:{body:"incoming",created_at:"2026-07-22T11:00:01.000000Z",
                from_agent:"carol",to_agent:"bob"}}')
  page=$(printf '%s\n%s\n%s\n' "$echo" "$remote" \
    '{"type":"sync_pull_cursor","next_after":"2"}')
  result=$(printf '%s\n' "$page" |
    storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -sr '.[0].transport_cursor')" = 2 ]
  [ "$(storage_history demo | jq -s 'length')" -eq 2 ]
  [ "$(storage_history demo | jq -s '[.[]|select(.body=="incoming")]|length')" -eq 1 ]
  [ "$(storage_list_unread demo bob | jq -s '[.[]|select(.body=="incoming")]|length')" -eq 1 ]
  printf '%s\n' "$page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  [ "$(storage_history demo | jq -s '[.[]|select(.body=="incoming")]|length')" -eq 1 ]
  [ "$(prepare_push | jq -s '[.[]|select(.type=="sync_push_candidate")]|length')" -eq 0 ]
  storage_compact >/dev/null
  [ "$(storage_history demo | jq -s '[.[]|select(.body=="incoming")]|length')" -eq 1 ]
  log="$(dirname "$(agmsg_db_path)")/events.jsonl"
  jq -e -s '[.[]|select(.type=="sync_pull_commit")][0]
    | (.transport_cursor=="2" and ([.messages[]|select(.local_event!=null)]|length)==1)' \
    "$log" >/dev/null
}

@test "jsonl pull durably rejects a pre-echo server sequence conflict" {
  storage_send demo alice bob outgoing >/dev/null
  local prepared candidate ack conflict page result
  prepared=$(prepare_push); candidate=$(candidate_of "$prepared")
  ack=$(printf '%s\n' "$candidate" | jq -c '
    {type:"sync_push_ack",local_position,id,server_seq:"1",disposition:"stored"}')
  printf '%s\n' "$ack" |
    storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  conflict=$(jq -nc '{type:"sync_pull_message",server_seq:"1",
    id:"550e8400-e29b-41d4-a716-446655440010",
    server_received_at:"2026-07-22T11:01:00.000000Z",
    envelope:{v:1,cipher:"none",key_id:null,blob:"e30="},status:"importable",
    policy_revision:"0",local_security_revision:"0",
    projection:{body:"must-not-import",created_at:"2026-07-22T11:01:00.000000Z",
                from_agent:"mallory",to_agent:"bob"}}')
  page=$(printf '%s\n%s\n' "$conflict" \
    '{"type":"sync_pull_cursor","next_after":"1"}')
  result=$(printf '%s\n' "$page" |
    storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -r 'select(.type=="sync_apply_outcome")|.status')" = \
    corrupt_state ]
  [ "$(storage_history demo | jq -s '[.[]|select(.body=="must-not-import")]|length')" -eq 0 ]
}

@test "jsonl pull echo before POST acknowledgement durably reconciles the reservation" {
  storage_send demo alice bob early-echo >/dev/null
  local prepared candidate echo page after
  prepared=$(prepare_push); candidate=$(candidate_of "$prepared")
  echo=$(printf '%s\n' "$candidate" | jq -c '
    {type:"sync_pull_message",server_seq:"1",id,envelope,
     server_received_at:"2026-07-22T11:02:00.000000Z",status:"importable",
     policy_revision:"0",local_security_revision:"0",
     projection:{body:"early-echo",created_at:"2026-07-22T11:02:00.000000Z",
                 from_agent:"alice",to_agent:"bob"}}')
  page=$(printf '%s\n%s\n' "$echo" \
    '{"type":"sync_pull_cursor","next_after":"1"}')
  printf '%s\n' "$page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  after=$(prepare_push)
  [ "$(printf '%s\n' "$after" | jq -s '[.[]|select(.type=="sync_push_candidate")]|length')" -eq 0 ]
  [ "$(storage_history demo | jq -s '[.[]|select(.body=="early-echo")]|length')" -eq 1 ]
}

@test "jsonl compaction rotates generation but preserves in-flight wire acknowledgement" {
  storage_send demo alice bob compact-safe >/dev/null
  local before candidate old_generation after new_candidate new_generation ack result
  before=$(prepare_push); candidate=$(candidate_of "$before")
  old_generation=$(printf '%s\n' "$before" | jq -r 'select(.type=="sync_state")|.driver_generation')
  storage_compact >/dev/null
  after=$(prepare_push); new_candidate=$(candidate_of "$after")
  new_generation=$(printf '%s\n' "$after" | jq -r 'select(.type=="sync_state")|.driver_generation')
  [ "$old_generation" != "$new_generation" ]
  [ "$(printf '%s\n' "$candidate" | jq -c '{local_id,id,envelope}')" = \
    "$(printf '%s\n' "$new_candidate" | jq -c '{local_id,id,envelope}')" ]
  ack=$(printf '%s\n' "$candidate" | jq -c '
    {type:"sync_push_ack",local_position,id,server_seq:"1",disposition:"stored"}')
  result=$(printf '%s\n' "$ack" |
    storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -r '.push_cursor')" = \
    "$(printf '%s\n' "$new_candidate" | jq -r '.local_position')" ]
}

@test "jsonl rewrite crash after new generation append leaves the original journal untouched" {
  storage_send demo alice bob rewrite-crash >/dev/null
  prepare_push >/dev/null
  local log before after
  log="$(dirname "$(agmsg_db_path)")/events.jsonl"
  before=$(cksum "$log")
  export AGMSG_SYNC_TEST_ABORT_AFTER_ROTATE_APPEND=1
  run storage_compact
  [ "$status" -eq 13 ]
  unset AGMSG_SYNC_TEST_ABORT_AFTER_ROTATE_APPEND
  after=$(cksum "$log")
  [ "$before" = "$after" ]
  run prepare_push
  [ "$status" -eq 0 ]
}

@test "jsonl concurrent prepare converges on one journal winner" {
  storage_send demo alice bob concurrent >/dev/null
  local first="$BATS_TEST_TMPDIR/first" second="$BATS_TEST_TMPDIR/second" log
  (printf '%s\n' "$PREPARE" |
    storage_sync_prepare_push demo "$SERVER_ID" "$TEAM_ID" 1 100 >"$first") 3>&- 4>&- &
  local first_pid=$!
  (printf '%s\n' "$PREPARE" |
    storage_sync_prepare_push demo "$SERVER_ID" "$TEAM_ID" 1 100 >"$second") 3>&- 4>&- &
  local second_pid=$!
  wait "$first_pid"; wait "$second_pid"
  [ "$(candidate_of "$(cat "$first")" | jq -c '{local_id,id,envelope}')" = \
    "$(candidate_of "$(cat "$second")" | jq -c '{local_id,id,envelope}')" ]
  log="$(dirname "$(agmsg_db_path)")/events.jsonl"
  [ "$(jq -s '[.[]|select(.type=="sync_prepare_commit")]|length' "$log")" -eq 1 ]
}

@test "jsonl team rename rotates offsets and preserves the durable wire mapping" {
  storage_send demo alice bob rename-safe >/dev/null
  local before candidate after rebound
  before=$(prepare_push); candidate=$(candidate_of "$before")
  storage_rename_team demo renamed >/dev/null
  after=$(printf '%s\n' "$PREPARE" |
    storage_sync_prepare_push renamed "$SERVER_ID" "$TEAM_ID" 1 100)
  rebound=$(candidate_of "$after")
  [ "$(printf '%s\n' "$candidate" | jq -c '{local_id,id,envelope}')" = \
    "$(printf '%s\n' "$rebound" | jq -c '{local_id,id,envelope}')" ]
  [ "$(storage_history renamed | jq -s '[.[]|select(.body=="rename-safe")]|length')" -eq 1 ]
}
