#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  export AGMSG_STORAGE_DRIVER=sqlite
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init >/dev/null
  SERVER_ID=018f3f7e-0000-7000-8000-000000000000
  TEAM_ID=018f3f7e-0000-7000-8000-000000000001
  PREPARE='{"type":"sync_prepare","envelope_v":1,"cipher":"none","key_id":null,"max_blob_bytes":1048576,"allow_new":true}'
}

teardown() { teardown_test_env; }

prepare_push() {
  printf '%s\n' "$PREPARE" | storage_sync_prepare_push demo "$SERVER_ID" "$TEAM_ID" 1 "${1:-100}"
}

@test "sync contract: prepare is re-entrant and byte-stable before reconcile" {
  storage_send demo alice bob "preserve these exact bytes" >/dev/null
  local first second
  first=$(prepare_push)
  second=$(prepare_push)
  [ "$first" = "$second" ]
  [ "$(printf '%s\n' "$first" | jq -s '[.[] | select(.type=="sync_push_candidate")] | length')" -eq 1 ]
  printf '%s\n' "$first" | jq -e 'select(.type=="sync_push_candidate")
    | (.id | test("^[0-9a-f]{8}-[0-9a-f]{4}-4"))
      and (.envelope.cipher=="none") and (.envelope.key_id==null)' >/dev/null
}

@test "sync contract: reconcile advances only the acknowledged contiguous prefix" {
  storage_send demo alice bob one >/dev/null
  storage_send demo alice bob two >/dev/null
  storage_send demo alice bob three >/dev/null
  local candidates late early result
  candidates=$(prepare_push 3)
  late=$(printf '%s\n' "$candidates" | jq -c '
    select(.type=="sync_push_candidate" and (.local_position|tonumber)>1)
    | {type:"sync_push_ack",local_position,id,server_seq:.local_position,disposition:"stored"}')
  result=$(printf '%s\n' "$late" | storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -r '.push_cursor')" = 0 ]
  early=$(printf '%s\n' "$candidates" | jq -c '
    select(.type=="sync_push_candidate" and .local_position=="1")
    | {type:"sync_push_ack",local_position,id,server_seq:"1",disposition:"stored"}')
  result=$(printf '%s\n' "$early" | storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -r '.push_cursor')" = 3 ]
}

@test "sync contract: pull reconciles echoes, imports wire IDs once, and keeps read state separate" {
  storage_send demo alice bob "outgoing" >/dev/null
  local prepared candidate ack envelope echo remote page result
  prepared=$(prepare_push)
  candidate=$(printf '%s\n' "$prepared" | jq -c 'select(.type=="sync_push_candidate")')
  ack=$(printf '%s\n' "$candidate" | jq -c \
    '{type:"sync_push_ack",local_position,id,server_seq:"1",disposition:"stored"}')
  printf '%s\n' "$ack" | storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  envelope=$(printf '%s\n' "$candidate" | jq -c '.envelope')
  echo=$(jq -nc --argjson envelope "$envelope" --arg id "$(printf '%s\n' "$candidate" | jq -r '.id')" '
    {type:"sync_pull_message",server_seq:"1",id:$id,
     server_received_at:"2026-07-20T13:00:00.000000Z",envelope:$envelope,
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"outgoing",created_at:"2026-07-20T13:00:00.000000Z",
                 from_agent:"alice",to_agent:"bob"}}')
  remote=$(jq -nc '
    {type:"sync_pull_message",server_seq:"2",
     id:"550e8400-e29b-41d4-a716-446655440000",
     server_received_at:"2026-07-20T13:00:01.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:(
       {body:"incoming",created_at:"2026-07-20T13:00:01.000000Z",
        from_agent:"carol",to_agent:"bob"}|tojson|@base64)},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"incoming",created_at:"2026-07-20T13:00:01.000000Z",
                 from_agent:"carol",to_agent:"bob"}}')
  page=$(printf '%s\n%s\n%s\n' "$echo" "$remote" '{"type":"sync_pull_cursor","next_after":"2"}')
  result=$(printf '%s\n' "$page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -sr '.[0].transport_cursor')" = 2 ]
  [ "$(storage_history demo | jq -s 'length')" -eq 2 ]
  [ "$(storage_history demo | jq -s '[.[]|select(.body=="outgoing")]|length')" -eq 1 ]
  [ "$(storage_history demo | jq -s '[.[]|select(.body=="incoming")]|length')" -eq 1 ]
  [ "$(storage_list_unread demo bob | jq -s '[.[]|select(.body=="incoming")]|length')" -eq 1 ]
  # Re-applying a durable page cannot create a second local event.
  printf '%s\n' "$page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  [ "$(storage_history demo | jq -s 'length')" -eq 2 ]
}

@test "sync contract: a server sequence reused by another wire ID is durably corrupt" {
  local first second first_page second_page result db
  first=$(jq -nc '
    {type:"sync_pull_message",server_seq:"1",id:"550e8400-e29b-41d4-a716-446655440010",
     server_received_at:"2026-07-20T13:01:00.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:"e30="},status:"malformed",
     policy_revision:"0",local_security_revision:"0",reason:"fixture"}')
  first_page=$(printf '%s\n%s\n' "$first" '{"type":"sync_pull_cursor","next_after":"1"}')
  printf '%s\n' "$first_page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  second=$(printf '%s\n' "$first" | jq -c '.id="550e8400-e29b-41d4-a716-446655440011"')
  second_page=$(printf '%s\n%s\n' "$second" '{"type":"sync_pull_cursor","next_after":"1"}')
  result=$(printf '%s\n' "$second_page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -s '.[0].corrupt_count')" -ge 1 ]
  [ "$(printf '%s\n' "$result" | jq -s '[.[]|select(.id=="550e8400-e29b-41d4-a716-446655440011" and .status=="corrupt_state")]|length')" -eq 1 ]
  db=$(agmsg_db_path)
  [ "$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sync_conflicts;" | tr -d '\r')" -eq 1 ]
}

@test "sync contract: pull conflicts with an acked mapping before its echo arrives" {
  storage_send demo alice bob "acked without echo" >/dev/null
  local prepared candidate ack remote page result db
  prepared=$(prepare_push)
  candidate=$(printf '%s\n' "$prepared" | jq -c 'select(.type=="sync_push_candidate")')
  ack=$(printf '%s\n' "$candidate" | jq -c \
    '{type:"sync_push_ack",local_position,id,server_seq:"1",disposition:"stored"}')
  printf '%s\n' "$ack" | storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  remote=$(jq -nc '
    {type:"sync_pull_message",server_seq:"1",
     id:"550e8400-e29b-41d4-a716-446655440012",
     server_received_at:"2026-07-20T13:01:30.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:(
       {body:"conflicting remote",created_at:"2026-07-20T13:01:30.000000Z",
        from_agent:"carol",to_agent:"bob"}|tojson|@base64)},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"conflicting remote",created_at:"2026-07-20T13:01:30.000000Z",
                 from_agent:"carol",to_agent:"bob"}}')
  page=$(printf '%s\n%s\n' "$remote" '{"type":"sync_pull_cursor","next_after":"1"}')
  result=$(printf '%s\n' "$page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -sr '.[0].corrupt_count')" -ge 1 ]
  [ "$(printf '%s\n' "$result" | jq -sr '[.[]|select(.id=="550e8400-e29b-41d4-a716-446655440012")][0].status')" = corrupt_state ]
  [ "$(storage_history demo | jq -s 'length')" -eq 1 ]
  db=$(agmsg_db_path)
  [ "$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sync_messages WHERE server_seq='1';" | tr -d '\r')" -eq 1 ]
  [ "$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sync_conflicts;" | tr -d '\r')" -eq 1 ]
}

@test "sync contract: a mapped echo keeps its blocking policy evaluation" {
  storage_send demo alice bob "mapped" >/dev/null
  local prepared candidate ack blocked page result db wire
  prepared=$(prepare_push)
  candidate=$(printf '%s\n' "$prepared" | jq -c 'select(.type=="sync_push_candidate")')
  ack=$(printf '%s\n' "$candidate" | jq -c \
    '{type:"sync_push_ack",local_position,id,server_seq:"1",disposition:"stored"}')
  printf '%s\n' "$ack" | storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  wire=$(printf '%s\n' "$candidate" | jq -r '.id')
  blocked=$(printf '%s\n' "$candidate" | jq -c '
    {type:"sync_pull_message",server_seq:"1",id,
     server_received_at:"2026-07-20T13:02:00.000000Z",envelope,
     status:"policy_violation",policy_revision:"2",local_security_revision:"1",
     reason:"E2EE required"}')
  page=$(printf '%s\n%s\n' "$blocked" '{"type":"sync_pull_cursor","next_after":"1"}')
  result=$(printf '%s\n' "$page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -sr --arg wire "$wire" '[.[]|select(.id==$wire)][0].status')" = policy_violation ]
  db=$(agmsg_db_path)
  [ "$(agmsg_sqlite "$db" "SELECT status FROM sync_quarantine WHERE wire_id='$wire';" | tr -d '\r')" = policy_violation ]
  [ "$(storage_history demo | jq -s 'length')" -eq 1 ]
}
