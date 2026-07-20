#!/usr/bin/env bash
# Optional Stage-1 remote synchronization extension for the SQLite driver.
# See docs/adr/0005-stage-1-remote-sync.md. All bulk input/output is JSONL.

_sqlite_sync_uuid4() {
  local h n variant
  h=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 1
  [ "${#h}" -eq 32 ] || return 1
  n=$((16#${h:16:1}))
  variant=$(printf '%x' $(((n & 3) | 8)))
  printf '%s-%s-4%s-%s%s-%s\n' \
    "${h:0:8}" "${h:8:4}" "${h:13:3}" "$variant" "${h:17:3}" "${h:20:12}"
}

_sqlite_sync_valid_binding() {
  printf '%s\n' "$1" | grep -Eq \
    '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' || return 1
  printf '%s\n' "$2" | grep -Eq \
    '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' || return 1
  case "$3" in ''|*[!0-9]*) return 1 ;; esac
}

_sqlite_sync_schema() {
  command -v jq >/dev/null 2>&1 || {
    echo "agmsg: Stage-1 sync requires jq" >&2
    return 10
  }
  storage_init >/dev/null || return 13
  local db generation
  db="$(_sqlite_db)"
  agmsg_sqlite "$db" "
    CREATE TABLE IF NOT EXISTS sync_store_metadata (
      singleton INTEGER PRIMARY KEY CHECK(singleton=1),
      generation TEXT NOT NULL UNIQUE
    );
    CREATE TABLE IF NOT EXISTS sync_bindings (
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      push_cursor INTEGER NOT NULL DEFAULT 0,
      transport_cursor TEXT NOT NULL DEFAULT '0',
      PRIMARY KEY(local_team,server_instance_id,remote_team_id,
                  protocol_version,driver_generation)
    );
    CREATE TABLE IF NOT EXISTS sync_messages (
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      local_position INTEGER NOT NULL,
      local_id TEXT NOT NULL,
      wire_id TEXT NOT NULL,
      envelope_v INTEGER NOT NULL,
      cipher TEXT NOT NULL,
      key_id TEXT,
      blob TEXT NOT NULL,
      server_seq TEXT,
      direction TEXT NOT NULL CHECK(direction IN ('push','pull')),
      PRIMARY KEY(local_team,server_instance_id,remote_team_id,
                  protocol_version,driver_generation,local_position),
      UNIQUE(server_instance_id,remote_team_id,protocol_version,wire_id)
    );
    CREATE TABLE IF NOT EXISTS sync_quarantine (
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      server_seq TEXT NOT NULL,
      wire_id TEXT NOT NULL,
      server_received_at TEXT NOT NULL,
      envelope_v INTEGER NOT NULL,
      cipher TEXT NOT NULL,
      key_id TEXT,
      blob TEXT NOT NULL,
      status TEXT NOT NULL,
      policy_revision TEXT,
      local_security_revision TEXT,
      reason TEXT,
      PRIMARY KEY(server_instance_id,remote_team_id,protocol_version,wire_id),
      UNIQUE(server_instance_id,remote_team_id,protocol_version,server_seq)
    );
    CREATE TABLE IF NOT EXISTS sync_conflicts (
      conflict_id INTEGER PRIMARY KEY AUTOINCREMENT,
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      server_seq TEXT NOT NULL,
      wire_id TEXT NOT NULL,
      envelope_v INTEGER NOT NULL,
      cipher TEXT NOT NULL,
      key_id TEXT,
      blob TEXT NOT NULL,
      reason TEXT NOT NULL,
      observed_at TEXT NOT NULL,
      UNIQUE(server_instance_id,remote_team_id,protocol_version,
             server_seq,wire_id,reason)
    );
  " >/dev/null 2>&1 || return 13
  generation=$(agmsg_sqlite "$db" \
    "SELECT generation FROM sync_store_metadata WHERE singleton=1;" 2>/dev/null | tr -d '\r')
  if [ -z "$generation" ]; then
    generation=$(_sqlite_sync_uuid4) || return 13
    agmsg_sqlite "$db" "INSERT OR IGNORE INTO sync_store_metadata(singleton,generation)
      VALUES(1,'$(_sqlite_lit "$generation")');" >/dev/null 2>&1 || return 13
  fi
}

_sqlite_sync_generation() {
  agmsg_sqlite "$(_sqlite_db)" \
    "SELECT generation FROM sync_store_metadata WHERE singleton=1;" | tr -d '\r'
}

_sqlite_sync_ensure_binding() {
  local team="$1" server="$2" remote="$3" protocol="$4" generation="$5"
  agmsg_sqlite "$(_sqlite_db)" "INSERT OR IGNORE INTO sync_bindings
    (local_team,server_instance_id,remote_team_id,protocol_version,driver_generation)
    VALUES('$(_sqlite_lit "$team")','$server','$remote',$protocol,'$generation');" \
    >/dev/null 2>&1
}

# Emits sync_state followed by ordered, durable push reservations.
storage_sync_prepare_push() {
  local team="$1" server="$2" remote="$3" protocol="$4" limit="$5"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || return 13
  case "$limit" in ''|*[!0-9]*) return 13 ;; esac
  [ "$limit" -ge 1 ] && [ "$limit" -le 1000 ] || return 13
  _sqlite_sync_schema || return $?

  local prepare generation db tl input_ok version cipher key_id max_blob allow_new
  prepare=$(cat)
  input_ok=$(printf '%s\n' "$prepare" | jq -r \
    'select(.type=="sync_prepare" and (.envelope_v|type)=="number" and
            (.cipher|type)=="string" and has("key_id") and
            (.max_blob_bytes|type)=="number" and (.allow_new|type)=="boolean") | "ok"' 2>/dev/null)
  [ "$input_ok" = ok ] || return 13
  version=$(printf '%s\n' "$prepare" | jq -r '.envelope_v')
  cipher=$(printf '%s\n' "$prepare" | jq -r '.cipher')
  key_id=$(printf '%s\n' "$prepare" | jq -r '.key_id // empty')
  max_blob=$(printf '%s\n' "$prepare" | jq -r '.max_blob_bytes')
  allow_new=$(printf '%s\n' "$prepare" | jq -r 'if .allow_new then 1 else 0 end')
  # Stage 1 implements the cipher-neutral ABI with the plaintext profile only.
  [ "$version" = 1 ] && [ "$cipher" = none ] && [ -z "$key_id" ] || return 13
  case "$max_blob" in ''|*[!0-9]*) return 13 ;; esac

  generation=$(_sqlite_sync_generation) || return 13
  _sqlite_sync_ensure_binding "$team" "$server" "$remote" "$protocol" "$generation" || return 13
  db="$(_sqlite_db)"; tl="$(_sqlite_lit "$team")"

  local rows line pos local_id body at created plaintext blob bytes wire
  rows=$(_sqlite_data "
    SELECT json_object('local_position',CAST(e.seq AS TEXT),'local_id',e.id,
                       'body',e.body,'at',e.at,'from_agent',e.from_agent,
                       'to_agent',e.to_agent)
      FROM events e
      JOIN sync_bindings b ON b.local_team='$tl'
       AND b.server_instance_id='$server' AND b.remote_team_id='$remote'
       AND b.protocol_version=$protocol AND b.driver_generation='$generation'
      LEFT JOIN sync_messages m ON m.local_team=b.local_team
       AND m.server_instance_id=b.server_instance_id
       AND m.remote_team_id=b.remote_team_id
       AND m.protocol_version=b.protocol_version
       AND m.driver_generation=b.driver_generation AND m.local_position=e.seq
     WHERE e.type='message_sent' AND e.team='$tl' AND e.seq>b.push_cursor
       AND m.server_seq IS NULL
       AND ($allow_new=1 OR m.wire_id IS NOT NULL)
     ORDER BY e.seq LIMIT $limit;
  ") || return 13

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pos=$(printf '%s\n' "$line" | jq -r '.local_position')
    local_id=$(printf '%s\n' "$line" | jq -r '.local_id')
    # A reservation already produced by an earlier call is immutable.
    if [ -n "$(agmsg_sqlite "$db" "SELECT wire_id FROM sync_messages WHERE
        local_team='$tl' AND server_instance_id='$server' AND remote_team_id='$remote'
        AND protocol_version=$protocol AND driver_generation='$generation'
        AND local_position=$pos;" 2>/dev/null)" ]; then
      continue
    fi
    body=$(printf '%s\n' "$line" | jq -r '.body')
    [ -n "$body" ] || return 13
    at=$(printf '%s\n' "$line" | jq -r '.at')
    case "$at" in ????-??-??T??:??:??Z) created="${at%Z}.000000Z" ;; *) created="$at" ;; esac
    plaintext=$(printf '%s\n' "$line" | jq -c --arg created "$created" \
      '{body:.body,created_at:$created,from_agent:.from_agent,to_agent:.to_agent}') || return 13
    bytes=$(LC_ALL=C printf '%s' "$plaintext" | wc -c | tr -d ' ')
    [ "$bytes" -ge 1 ] && [ "$bytes" -le 1048576 ] && [ "$bytes" -le "$max_blob" ] || return 13
    blob=$(printf '%s' "$plaintext" | base64 | tr -d '\r\n') || return 13
    wire=$(_sqlite_sync_uuid4) || return 13
    # INSERT OR IGNORE makes concurrent prepare calls converge on one winner;
    # the final SELECT below always emits the committed winner's bytes.
    agmsg_sqlite "$db" "BEGIN IMMEDIATE;
      INSERT OR IGNORE INTO sync_messages
        (local_team,server_instance_id,remote_team_id,protocol_version,
         driver_generation,local_position,local_id,wire_id,envelope_v,cipher,
         key_id,blob,direction)
      VALUES('$tl','$server','$remote',$protocol,'$generation',$pos,
             '$(_sqlite_lit "$local_id")','$wire',1,'none',NULL,
             '$(_sqlite_lit "$blob")','push');
      COMMIT;" >/dev/null 2>&1 || return 13
  done <<EOF
$rows
EOF

  _sqlite_data "SELECT json_object('type','sync_state','driver_generation',
      '$generation','transport_cursor',transport_cursor)
    FROM sync_bindings WHERE local_team='$tl' AND server_instance_id='$server'
      AND remote_team_id='$remote' AND protocol_version=$protocol
      AND driver_generation='$generation';
    SELECT json_object('type','sync_push_candidate','local_position',
      CAST(m.local_position AS TEXT),'local_id',m.local_id,'id',m.wire_id,
      'envelope',json_object('v',m.envelope_v,'cipher',m.cipher,
                             'key_id',m.key_id,'blob',m.blob))
    FROM sync_messages m JOIN sync_bindings b
      ON b.local_team=m.local_team AND b.server_instance_id=m.server_instance_id
     AND b.remote_team_id=m.remote_team_id AND b.protocol_version=m.protocol_version
     AND b.driver_generation=m.driver_generation
    WHERE m.local_team='$tl' AND m.server_instance_id='$server'
      AND m.remote_team_id='$remote' AND m.protocol_version=$protocol
      AND m.driver_generation='$generation' AND m.local_position>b.push_cursor
      AND m.server_seq IS NULL ORDER BY m.local_position LIMIT $limit;"
}

# Reads complete server acknowledgements and advances only the contiguous prefix.
storage_sync_reconcile_push() {
  local team="$1" server="$2" remote="$3" protocol="$4"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || return 13
  _sqlite_sync_schema || return $?
  local generation db tl line values="" pos wire seq disposition count=0
  generation=$(_sqlite_sync_generation); db="$(_sqlite_db)"; tl="$(_sqlite_lit "$team")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(printf '%s\n' "$line" | jq -r '.type // empty')" = sync_push_ack ] || return 13
    pos=$(printf '%s\n' "$line" | jq -r '.local_position // empty')
    wire=$(printf '%s\n' "$line" | jq -r '.id // empty')
    seq=$(printf '%s\n' "$line" | jq -r '.server_seq // empty')
    disposition=$(printf '%s\n' "$line" | jq -r '.disposition // empty')
    case "$pos:$seq" in *[!0-9:]*) return 13 ;; esac
    case "$disposition" in stored|duplicate) ;; *) return 13 ;; esac
    printf '%s' "$wire" | grep -Eq '^[0-9a-f-]{36}$' || return 13
    values="${values}${values:+,}($pos,'$wire','$seq')"; count=$((count + 1))
  done
  [ "$count" -gt 0 ] || return 13

  agmsg_sqlite "$db" "BEGIN IMMEDIATE;
    CREATE TEMP TABLE incoming_sync_acks(
      local_position INTEGER UNIQUE,wire_id TEXT UNIQUE,server_seq TEXT UNIQUE);
    INSERT INTO incoming_sync_acks VALUES $values;
    CREATE TEMP TABLE sync_assert(ok INTEGER CHECK(ok=1));
    INSERT INTO sync_assert SELECT CASE WHEN COUNT(*)=$count THEN 1 ELSE 0 END
      FROM incoming_sync_acks a JOIN sync_messages m
        ON m.local_team='$tl' AND m.server_instance_id='$server'
       AND m.remote_team_id='$remote' AND m.protocol_version=$protocol
       AND m.driver_generation='$generation' AND m.local_position=a.local_position
       AND m.wire_id=a.wire_id
       AND (m.server_seq IS NULL OR m.server_seq=a.server_seq);
    UPDATE sync_messages SET server_seq=(SELECT a.server_seq FROM incoming_sync_acks a
      WHERE a.local_position=sync_messages.local_position AND a.wire_id=sync_messages.wire_id)
      WHERE local_team='$tl' AND server_instance_id='$server' AND remote_team_id='$remote'
        AND protocol_version=$protocol AND driver_generation='$generation'
        AND EXISTS(SELECT 1 FROM incoming_sync_acks a
          WHERE a.local_position=sync_messages.local_position AND a.wire_id=sync_messages.wire_id);
    UPDATE sync_bindings AS b SET push_cursor=COALESCE((
      SELECT MAX(e.seq) FROM events e
      WHERE e.type='message_sent' AND e.team='$tl' AND e.seq>b.push_cursor
        AND NOT EXISTS (
          SELECT 1 FROM events gap LEFT JOIN sync_messages gm
            ON gm.local_team='$tl' AND gm.server_instance_id='$server'
           AND gm.remote_team_id='$remote' AND gm.protocol_version=$protocol
           AND gm.driver_generation='$generation' AND gm.local_position=gap.seq
          WHERE gap.type='message_sent' AND gap.team='$tl'
            AND gap.seq>b.push_cursor AND gap.seq<=e.seq AND gm.server_seq IS NULL
        )),b.push_cursor)
    WHERE b.local_team='$tl' AND b.server_instance_id='$server'
      AND b.remote_team_id='$remote' AND b.protocol_version=$protocol
      AND b.driver_generation='$generation';
    COMMIT;" >/dev/null 2>&1 || return 12

  _sqlite_data "SELECT json_object('type','sync_reconcile_result','push_cursor',
    CAST(push_cursor AS TEXT)) FROM sync_bindings WHERE local_team='$tl'
    AND server_instance_id='$server' AND remote_team_id='$remote'
    AND protocol_version=$protocol AND driver_generation='$generation';"
}

# Reads a validated pull page, durably quarantines/reconciles/imports it, then
# advances the transport cursor in the same transaction.
storage_sync_apply_pull() {
  local team="$1" server="$2" remote="$3" protocol="$4"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || return 13
  _sqlite_sync_schema || return $?
  local generation db tl sql_file line type final_cursor="" corrupt=0 outcome_ids=""
  local seq wire received v cipher key_id blob status policy local_rev reason
  local from to body at local_id q
  generation=$(_sqlite_sync_generation); db="$(_sqlite_db)"; tl="$(_sqlite_lit "$team")"
  _sqlite_sync_ensure_binding "$team" "$server" "$remote" "$protocol" "$generation" || return 13
  sql_file=$(mktemp "${TMPDIR:-/tmp}/agmsg-sync-sql.XXXXXX") || return 13
  _AGMSG_SYNC_SQL_FILE="$sql_file"
  trap 'case "${_AGMSG_SYNC_SQL_FILE:-}" in "${TMPDIR:-/tmp}"/agmsg-sync-sql.*) rm -f "$_AGMSG_SYNC_SQL_FILE" ;; esac' EXIT INT TERM HUP
  printf '%s\n' 'BEGIN IMMEDIATE;' > "$sql_file"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    type=$(printf '%s\n' "$line" | jq -r '.type // empty')
    if [ "$type" = sync_pull_cursor ]; then
      final_cursor=$(printf '%s\n' "$line" | jq -r '.next_after // empty')
      case "$final_cursor" in ''|*[!0-9]*) rm -f "$sql_file"; return 13 ;; esac
      continue
    fi
    [ "$type" = sync_pull_message ] || { rm -f "$sql_file"; return 13; }
    seq=$(printf '%s\n' "$line" | jq -r '.server_seq // empty')
    wire=$(printf '%s\n' "$line" | jq -r '.id // empty')
    printf '%s\n' "$wire" | grep -Eq \
      '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' \
      || { rm -f "$sql_file"; trap - EXIT INT TERM HUP; return 13; }
    outcome_ids="${outcome_ids}${outcome_ids:+,}'$wire'"
    received=$(printf '%s\n' "$line" | jq -r '.server_received_at // empty')
    v=$(printf '%s\n' "$line" | jq -r '.envelope.v')
    cipher=$(printf '%s\n' "$line" | jq -r '.envelope.cipher')
    key_id=$(printf '%s\n' "$line" | jq -r '.envelope.key_id // empty')
    blob=$(printf '%s\n' "$line" | jq -r '.envelope.blob')
    status=$(printf '%s\n' "$line" | jq -r '.status')
    policy=$(printf '%s\n' "$line" | jq -r '.policy_revision // empty')
    local_rev=$(printf '%s\n' "$line" | jq -r '.local_security_revision // empty')
    reason=$(printf '%s\n' "$line" | jq -r '.reason // empty')
    case "$seq:$v" in *[!0-9:]*) rm -f "$sql_file"; return 13 ;; esac
    case "$status" in importable|unsupported_cipher|pending_key|authentication_failed|malformed|policy_violation) ;; *) rm -f "$sql_file"; return 13 ;; esac
    q="'$(_sqlite_lit "$key_id")'"; [ -n "$key_id" ] || q=NULL
    printf "%s\n" "
      INSERT OR IGNORE INTO sync_conflicts
        (local_team,server_instance_id,remote_team_id,protocol_version,
         driver_generation,server_seq,wire_id,envelope_v,cipher,key_id,blob,
         reason,observed_at)
      SELECT '$tl','$server','$remote',$protocol,'$generation','$seq','$wire',$v,
             '$(_sqlite_lit "$cipher")',$q,'$(_sqlite_lit "$blob")',
             'server sequence maps to another wire id',
             strftime('%Y-%m-%dT%H:%M:%fZ','now')
      WHERE EXISTS(SELECT 1 FROM sync_quarantine qx
        WHERE qx.server_instance_id='$server' AND qx.remote_team_id='$remote'
          AND qx.protocol_version=$protocol AND qx.server_seq='$seq'
          AND qx.wire_id<>'$wire');
      INSERT OR IGNORE INTO sync_conflicts
        (local_team,server_instance_id,remote_team_id,protocol_version,
         driver_generation,server_seq,wire_id,envelope_v,cipher,key_id,blob,
         reason,observed_at)
      SELECT '$tl','$server','$remote',$protocol,'$generation','$seq','$wire',$v,
             '$(_sqlite_lit "$cipher")',$q,'$(_sqlite_lit "$blob")',
             'wire id maps to another sequence or envelope',
             strftime('%Y-%m-%dT%H:%M:%fZ','now')
      WHERE EXISTS(SELECT 1 FROM sync_quarantine qx
        WHERE qx.server_instance_id='$server' AND qx.remote_team_id='$remote'
          AND qx.protocol_version=$protocol AND qx.wire_id='$wire'
          AND (qx.server_seq<>'$seq' OR qx.envelope_v<>$v
            OR qx.cipher<>'$(_sqlite_lit "$cipher")'
            OR COALESCE(qx.key_id,'')<>'$(_sqlite_lit "$key_id")'
            OR qx.blob<>'$(_sqlite_lit "$blob")'));
      INSERT OR IGNORE INTO sync_quarantine
        (local_team,server_instance_id,remote_team_id,protocol_version,
         driver_generation,server_seq,wire_id,server_received_at,envelope_v,
         cipher,key_id,blob,status,policy_revision,local_security_revision,reason)
      VALUES('$tl','$server','$remote',$protocol,'$generation','$seq','$wire',
        '$(_sqlite_lit "$received")',$v,'$(_sqlite_lit "$cipher")',$q,
        '$(_sqlite_lit "$blob")','$status','$(_sqlite_lit "$policy")',
        '$(_sqlite_lit "$local_rev")','$(_sqlite_lit "$reason")');
      UPDATE sync_quarantine SET status='corrupt_state',reason='wire envelope mismatch'
       WHERE server_instance_id='$server' AND remote_team_id='$remote'
         AND protocol_version=$protocol AND wire_id='$wire'
         AND (server_seq<>'$seq' OR envelope_v<>$v OR cipher<>'$(_sqlite_lit "$cipher")'
              OR COALESCE(key_id,'')<>'$(_sqlite_lit "$key_id")'
              OR blob<>'$(_sqlite_lit "$blob")');
      UPDATE sync_quarantine SET status='corrupt_state',reason='mapped envelope mismatch'
       WHERE server_instance_id='$server' AND remote_team_id='$remote'
         AND protocol_version=$protocol AND wire_id='$wire' AND EXISTS(
           SELECT 1 FROM sync_messages m WHERE m.server_instance_id='$server'
             AND m.remote_team_id='$remote' AND m.protocol_version=$protocol
             AND m.wire_id='$wire' AND (m.envelope_v<>$v OR m.cipher<>'$(_sqlite_lit "$cipher")'
               OR COALESCE(m.key_id,'')<>'$(_sqlite_lit "$key_id")'
               OR m.blob<>'$(_sqlite_lit "$blob")'
               OR (m.server_seq IS NOT NULL AND m.server_seq<>'$seq')));
      UPDATE sync_messages SET server_seq='$seq' WHERE server_instance_id='$server'
        AND remote_team_id='$remote' AND protocol_version=$protocol AND wire_id='$wire'
        AND envelope_v=$v AND cipher='$(_sqlite_lit "$cipher")'
        AND COALESCE(key_id,'')='$(_sqlite_lit "$key_id")'
        AND blob='$(_sqlite_lit "$blob")' AND (server_seq IS NULL OR server_seq='$seq')
        AND EXISTS(SELECT 1 FROM sync_quarantine qx
          WHERE qx.server_instance_id='$server' AND qx.remote_team_id='$remote'
            AND qx.protocol_version=$protocol AND qx.wire_id='$wire'
            AND qx.status='importable');
      UPDATE sync_quarantine SET status='reconciled' WHERE server_instance_id='$server'
        AND remote_team_id='$remote' AND protocol_version=$protocol AND wire_id='$wire'
        AND status='importable' AND EXISTS(SELECT 1 FROM sync_messages m
          WHERE m.server_instance_id='$server' AND m.remote_team_id='$remote'
            AND m.protocol_version=$protocol AND m.wire_id='$wire' AND m.server_seq='$seq');" >> "$sql_file"

    if [ "$status" = importable ]; then
      from=$(printf '%s\n' "$line" | jq -r '.projection.from_agent // empty')
      to=$(printf '%s\n' "$line" | jq -r '.projection.to_agent // empty')
      body=$(printf '%s\n' "$line" | jq -r '.projection.body // empty')
      at=$(printf '%s\n' "$line" | jq -r '.projection.created_at // empty')
      [ -n "$from" ] && [ -n "$to" ] && [ -n "$body" ] && [ -n "$at" ] || { rm -f "$sql_file"; return 13; }
      local_id=$(_sqlite_uuid7) || { rm -f "$sql_file"; return 13; }
      printf "%s\n" "
        INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
        SELECT 'message_sent','$local_id','$tl','$(_sqlite_lit "$from")',
               '$(_sqlite_lit "$to")','$(_sqlite_lit "$body")','$(_sqlite_lit "$at")'
        WHERE NOT EXISTS(SELECT 1 FROM sync_messages m
          WHERE m.server_instance_id='$server' AND m.remote_team_id='$remote'
            AND m.protocol_version=$protocol AND m.wire_id='$wire')
          AND NOT EXISTS(SELECT 1 FROM sync_quarantine qx
          WHERE qx.server_instance_id='$server' AND qx.remote_team_id='$remote'
            AND qx.protocol_version=$protocol AND qx.wire_id='$wire'
            AND qx.status='corrupt_state')
          AND NOT EXISTS(SELECT 1 FROM sync_conflicts cx
          WHERE cx.server_instance_id='$server' AND cx.remote_team_id='$remote'
            AND cx.protocol_version=$protocol AND cx.wire_id='$wire');
        INSERT OR IGNORE INTO sync_messages
          (local_team,server_instance_id,remote_team_id,protocol_version,
           driver_generation,local_position,local_id,wire_id,envelope_v,cipher,
           key_id,blob,server_seq,direction)
        SELECT '$tl','$server','$remote',$protocol,'$generation',seq,id,'$wire',$v,
               '$(_sqlite_lit "$cipher")',$q,'$(_sqlite_lit "$blob")','$seq','pull'
          FROM events WHERE id='$local_id';
        UPDATE sync_quarantine SET status='imported' WHERE server_instance_id='$server'
          AND remote_team_id='$remote' AND protocol_version=$protocol AND wire_id='$wire'
          AND status<>'corrupt_state' AND EXISTS(SELECT 1 FROM sync_messages m
            WHERE m.server_instance_id='$server' AND m.remote_team_id='$remote'
              AND m.protocol_version=$protocol AND m.wire_id='$wire'
              AND m.direction='pull');" >> "$sql_file"
    fi
  done
  [ -n "$final_cursor" ] || { rm -f "$sql_file"; return 13; }
  printf "%s\n" "UPDATE sync_bindings SET transport_cursor='$final_cursor'
    WHERE local_team='$tl' AND server_instance_id='$server' AND remote_team_id='$remote'
      AND protocol_version=$protocol AND driver_generation='$generation';
    COMMIT;" >> "$sql_file"
  if ! agmsg_sqlite "$db" < "$sql_file" >/dev/null 2>&1; then
    rm -f "$sql_file"; trap - EXIT INT TERM HUP; return 13
  fi
  rm -f "$sql_file"
  trap - EXIT INT TERM HUP
  _AGMSG_SYNC_SQL_FILE=""
  corrupt=$(agmsg_sqlite "$db" "SELECT
    (SELECT COUNT(*) FROM sync_quarantine WHERE
    server_instance_id='$server' AND remote_team_id='$remote' AND protocol_version=$protocol
    AND status='corrupt_state') +
    (SELECT COUNT(*) FROM sync_conflicts WHERE server_instance_id='$server'
     AND remote_team_id='$remote' AND protocol_version=$protocol);" | tr -d '\r')
  _sqlite_data "SELECT json_object('type','sync_apply_result','transport_cursor',
    transport_cursor,'corrupt_count',$corrupt) FROM sync_bindings
    WHERE local_team='$tl' AND server_instance_id='$server' AND remote_team_id='$remote'
      AND protocol_version=$protocol AND driver_generation='$generation';
    SELECT json_object('type','sync_apply_outcome','id',wire_id,
                       'server_seq',server_seq,'status',status)
      FROM sync_quarantine WHERE server_instance_id='$server'
       AND remote_team_id='$remote' AND protocol_version=$protocol
       AND wire_id IN (${outcome_ids:-''})
    UNION ALL
    SELECT json_object('type','sync_apply_outcome','id',c.wire_id,
                       'server_seq',c.server_seq,'status','corrupt_state')
      FROM sync_conflicts c WHERE c.server_instance_id='$server'
       AND c.remote_team_id='$remote' AND c.protocol_version=$protocol
       AND c.wire_id IN (${outcome_ids:-''})
       AND NOT EXISTS(SELECT 1 FROM sync_quarantine qx
         WHERE qx.server_instance_id=c.server_instance_id
           AND qx.remote_team_id=c.remote_team_id
           AND qx.protocol_version=c.protocol_version AND qx.wire_id=c.wire_id);"
}
