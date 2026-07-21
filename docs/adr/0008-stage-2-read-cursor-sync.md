# ADR 0008: Stage-2 read-state synchronization

**Status:** proposed (dogfood contract)
**Date:** 2026-07-21
**Deciders:** @fujibee

## Context

Stage 1 deliberately separates remote transport progress, decrypt/import state,
and user or agent read state. The first two layers synchronize, but read state
is still machine-local. A message read on one device can therefore be delivered
again on another device.

The older Phase-3 storage-cursor branch used one scalar local-log position per
`(team, agent)`. That scalar cannot represent read state in a local-first remote
store. For example, an unread, unacknowledged local message may be at local
position 5 while a remote message at server sequence 10 is imported at local
position 6. Translating a remote read frontier of 10 into local position 6 would
hide the unread local message. Refusing to translate it would redeliver the
remote message.

## Decision

### Store-owned composite frontier

Each storage driver owns one composite read state per local `(team, agent)` and
remote binding:

- `local_position`: the contiguous covered prefix of the driver's local message
  order;
- `remote_server_seq`: the contiguous covered prefix of the immutable remote
  team stream;
- exact local reads, keyed by stable local message ID until a wire mapping
  exists; and
- exact remote reads, keyed by wire ID.

A projected message is read for an agent when at least one of these facts covers
that message itself:

1. its local position is at or below `local_position`;
2. it has a durable mapping whose `server_seq` is at or below
   `remote_server_seq`; or
3. its stable local ID or wire ID is in the corresponding exact-read set.

The driver MUST NOT infer remote coverage for a local message without a durable
wire/sequence mapping. The remote component and exact remote facts are scoped by
`(server_instance_id, remote_team_id, protocol_version, member_id)`. The local
team name and mutable member name are not remote identities. A roster name is
associated durably with its immutable `member_id`; rename preserves the
association, and retired names cannot be rebound as required by HTTP v1.

The transport cursor, quarantine/decrypt state, composite read state, and the
existing display/read receipt layer remain distinct. Receiving remote read
state never imports, decrypts, displays, or marks a blocking quarantine entry as
read. If reprocessing later imports that message and its sequence or wire ID is
already covered, the local projection starts read.

### Contiguous-prefix and exact-read rules

Neither frontier may jump over an uncovered message on its own axis. Reading a
later message creates an exact fact while the frontier remains immediately
before the first hole. Once the hole becomes covered, the driver compacts the
now-contiguous prefix and may discard absorbed synchronization exceptions.

For example, if local position 5 is unread and position 6 is read, position 6 is
an exact read and `local_position` remains 4. Reading position 5 permits a
single transaction to advance the local frontier to 6 and compact the absorbed
exact fact. The same prefix-plus-exceptions rule applies to `server_seq`.

The merge algebra is deliberately monotonic:

- remote frontiers merge with `max`;
- exact wire reads merge with set union; and
- local frontiers advance only inside their originating store through local
  contiguous compaction and are never merged between machines.

Read undo is not part of Stage 2. A future non-monotonic unread feature would
need an explicit generation or epoch rather than weakening these rules.

### Local consume contract

The required storage ABI adds:

```text
storage_read_cursor_get <team> <agent>
storage_read_cursor_consume <team> <agent> <delivery-cursor> [<id> ...]
```

`storage_read_cursor_get` returns the opaque local-position component.
`storage_read_cursor_consume` records the exact displayed IDs and advances the
local component only through a contiguous, successfully scanned delivery
prefix. Drivers MUST max-merge it and MUST NOT move it backwards.

Inbox, turn-hook, and monitor delivery use the same stored cursor. A successful
scan advances it even if the scanned span contains no message for the agent.
The monitor's former per-session watermark is no longer read authority.

An upgrade from the pre-cursor model treats the existing backlog as consumed to
avoid a full-history monitor storm. Fresh stores begin at zero. Messages that
arrive after migration remain unread.

### Wire-ID promotion and atomicity

An exact read of a local-only message is initially keyed by its stable local
message ID. Publishing a Stage-1 reservation or reconciling a pull mapping MUST,
in the same storage transaction, promote or alias that read fact to the durable
wire ID. The promoted fact becomes eligible for upload only after the mapping
has a canonical acknowledged `server_seq`; a server MUST NOT be asked to store
an exact read for a wire ID it does not yet know.

Message import or mapping, exact-read promotion, frontier compaction, and any
covered projection change that they enable are one local transaction. Durable
covered rows and exact facts are written before either frontier advances. A
crash rolls the whole transition back, and replay is idempotent.

An exact remote fact may arrive before its message. The driver stores it by wire
ID without fabricating a local projection. Import later applies the fact only
after the envelope has passed policy/decrypt validation and has been durably
projected.

### Optional Stage-2 driver operations

A Stage-1 SQLite driver may advertise the additional
`stage2-read-state` capability and implement:

```text
storage_sync_prepare_read_state <local-team> <server-instance-id> <remote-team-id> <protocol-version>
storage_sync_apply_read_state <local-team> <server-instance-id> <remote-team-id> <protocol-version>
```

Both operations use UTF-8 JSONL on stdin/stdout. Prepare receives one validated
`sync_read_roster` record containing the current immutable member IDs and names.
It emits zero or more `sync_read_frontier` and `sync_read_exact` records:

```jsonl
{"type":"sync_read_frontier","member_id":"018f...","server_seq":"42"}
{"type":"sync_read_exact","member_id":"018f...","wire_id":"550e8400-e29b-41d4-a716-446655440000"}
```

For each member, prepare computes the largest safe contiguous remote prefix. It
stops before any sequence whose envelope lacks a durable outcome, any blocking
quarantine entry whose recipient is unknown, or any imported message addressed
to that member that local read state does not cover. Imported messages for other
members are vacuously covered for this member. It emits exact wire reads above
the safe prefix only when their mappings and server sequences are durable.

Apply consumes a page of authenticated server `sync_read_frontier` and
`sync_read_exact` records. In one transaction it max-merges frontiers, set-unions
exact facts, projects coverage only onto already imported messages, compacts
each local prefix, and removes only exact facts whose own durable mapping proves
`server_seq <= remote_server_seq`. It MUST NOT garbage-collect by wire ID alone.
It never changes transport or decrypt/import progress.

### HTTP operation

`POST /v1/read-state/sync` uses the normal team credential and standard HTTP v1
binding/version rules. The strict request is:

```json
{
  "updates": [
    {
      "member_id": "018f3f7e-0000-7000-8000-000000000010",
      "server_seq": "42",
      "exact_wire_ids": ["550e8400-e29b-41d4-a716-446655440000"]
    }
  ],
  "page_after": null,
  "page_limit": 1000
}
```

`updates` contains at most 1,000 distinct active members, each exact list
contains distinct canonical UUIDv4 wire IDs, and the request contains at most
1,000 exact IDs in total. `server_seq` is a canonical signed-BIGINT decimal
string. `page_limit` is an integer from 1 through 1,000. `page_after` is either
null or the exact `{member_id, wire_id}` key returned by the previous response.
Unknown and duplicate fields are rejected under the common v1 JSON rules.

In one transaction the server:

1. locks the team row used by message and policy sequencing;
2. validates that every member is active in the credential's team, every
   frontier is at most `current_seq`, and every exact wire ID resolves to a live
   message or permanent tombstone in that team;
3. max-merges frontiers and set-unions exact reads;
4. removes an exact row only when the resolved live message `team_seq` or
   tombstone `original_seq` is at or below that member's merged frontier;
5. verifies the remaining exact set is at most 4,096 rows per member and 65,536
   rows per team, failing the entire update atomically with `409
   read-state-limit-exceeded` otherwise; and
6. reads the response from the same snapshot.

The response contains every active member frontier plus one lexicographically
ordered page of unabsorbed exact rows:

```json
{
  "protocol_version": 1,
  "server_instance_id": "018f3f7e-0000-7000-8000-000000000000",
  "team_id": "018f3f7e-0000-7000-8000-000000000001",
  "team_name": "example-team",
  "min_available_seq": "0",
  "current_seq": "52",
  "frontiers": [
    {"member_id":"018f3f7e-0000-7000-8000-000000000010","server_seq":"42"}
  ],
  "exact_reads": [
    {"member_id":"018f3f7e-0000-7000-8000-000000000010","wire_id":"550e8400-e29b-41d4-a716-446655440000"}
  ],
  "next_page_after": null,
  "has_more": false
}
```

Frontiers are sorted by `member_id`; exact rows are sorted by
`(member_id, wire_id)`. A member with no row has frontier zero. Pagination is
keyset-based. Each request is an independent current snapshot: concurrent
monotonic additions that sort before an in-progress page cursor may be observed
on the next poll, while an exact row removed by GC is necessarily represented
by the always-returned frontier. Clients therefore apply every page
monotonically and restart at `page_after: null` on the next polling cycle.

An empty update list is the read-only synchronization form. Retrying an update
is idempotent. The engine sends local updates with the first page request and
uses empty updates for subsequent pages. It validates response binding,
canonical ordering, limits, and pagination before giving a page to the driver.

The server schema is keyed by immutable `(team_id, member_id)` and
`(team_id, member_id, wire_id)`. Removing a member cascades its read state.
Member rename preserves it. A team credential may synchronize any active member
in its own team; cross-team access is impossible.

### Explicitly out of scope

Stage 3 server-sent events and wake delivery are not launch requirements and are
not part of this ADR. Stage 2 continues to use the existing polling loop.

## Consequences

- A read on one device converges monotonically on every device.
- Local-first messages are never hidden merely because a later remote sequence
  was read elsewhere.
- Out-of-order read state is bounded, paginated, and compacted only from proven
  wire-to-sequence mappings.
- The server stores member IDs, wire IDs, and numeric frontiers, but still
  cannot see sender, recipient, body, or client timestamps.
- Cursor synchronization cannot advance through an undecryptable envelope,
  because its recipient is unknown. Transport may continue independently.

## References

- [ADR 0003: storage-axis ABI](0003-storage-axis-driver-abi-and-scope.md)
- [ADR 0005: Stage-1 remote sync](0005-stage-1-remote-sync.md)
- [HTTP API v1](../../server/spec/v1.md)
