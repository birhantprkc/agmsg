# Stage-1 remote sync dogfood

Stage 1 polls the draft reference server while every `send` still commits to the
local SQLite store first. It is intentionally branch-only and is not installed
by the released core yet.

Requirements: Node.js 22+, SQLite, jq, base64, and a provisioned team on the
reference server. The bearer token is accepted only through
`AGMSG_SYNC_TOKEN`; it is never stored in sync config or passed as an argument.

Configure each machine (or each isolated dogfood store) with an explicit local
plaintext policy:

```sh
export AGMSG_STORAGE_PATH=/path/to/machine-a-store
export AGMSG_SYNC_TOKEN='deployment bearer token'

scripts/remote-sync.sh configure \
  --team example-team \
  --server http://127.0.0.1:8787 \
  --team-id 018f3f7e-0000-7000-8000-000000000001 \
  --minimum-security plaintext-allowed
```

Run one push/pull cycle:

```sh
scripts/remote-sync.sh once --team example-team
```

Or poll continuously (five seconds by default):

```sh
scripts/remote-sync.sh run --team example-team --interval 5
```

After installing a previously missing identity or deliberately changing local
open support, retry durable quarantine without rewinding the transport cursor:

```sh
scripts/remote-sync.sh reprocess --team example-team --limit 100
```

Reprocessing is explicit. Continuous polling does not repeatedly decrypt a
permanently invalid ciphertext.

The command emits timestamped JSONL lifecycle events. Set a log file to retain
the exact push/ack/pull/import trace; the file is append-only from the client's
perspective and includes imported plaintext bodies:

```sh
export AGMSG_SYNC_LOG_FILE=/path/to/stage1-dogfood.jsonl
scripts/remote-sync.sh once --team example-team
```

For an `age-v1` binding, install the standard `age` CLI and provision a
freshness-confirmed epoch snapshot outside the message server. Identity files
must be regular files with mode `0600` on POSIX systems. The snapshot is public
key material and its file must use compact RFC 8785 JCS; the expanded example
below shows its minimum initial-epoch data shape:

```json
{
  "profile": "age-v1",
  "server_instance_id": "018f3f7e-0000-7000-8000-000000000000",
  "team_id": "018f3f7e-0000-7000-8000-000000000001",
  "epoch_revision": "0",
  "writer_generation": "0",
  "authorized_writers": ["machine-a"],
  "previous_snapshot_sha256": null,
  "history": [{
    "epoch_revision": "0",
    "effective_from_seq": "1",
    "cipher": "age-v1",
    "key_id": "epoch-1",
    "recipients": ["age1..."]
  }]
}
```

After independently confirming the current revision and lowercase JCS SHA-256
digest with the epoch authority, configure the binding:

```sh
export AGMSG_AGE_BIN=/path/to/age       # optional when age is already on PATH
chmod 600 /secure/path/epoch-1.identity

scripts/remote-sync.sh configure \
  --team example-team \
  --server https://sync.example \
  --team-id 018f3f7e-0000-7000-8000-000000000001 \
  --minimum-security e2ee-required \
  --cipher age-v1 \
  --age-snapshot /authenticated/path/epoch-snapshot.json \
  --age-checkpoint '0:CONFIRMED_LOWERCASE_SHA256' \
  --age-identity epoch-1=/secure/path/epoch-1.identity
```

Only the public recipient list crosses the storage-driver seam. The private
identity path stays in the engine configuration and is used only while opening
pulled envelopes. The current dogfood command accepts only an initial revision-0
snapshot. Joining an established rotated binding or rotating an active binding
requires complete chain verification, quiesce, drain, a server authorization
fence, and the fresh-boundary procedure in the
[`age-v1` profile](spec/age-v1-profile.md#multi-writer-cutover-protocol), which
is not yet automated by this client.

For `age-v1`, lifecycle logs omit imported plaintext fields by default. Set
`AGMSG_SYNC_LOG_PLAINTEXT=1` only when the log destination is intentionally
trusted to contain decrypted message content. Plaintext bindings retain the
existing body-inclusive dogfood trace.

For a single-host two-machine simulation, repeat configuration with two
different `AGMSG_STORAGE_PATH` directories and the same immutable remote team
ID. A message sent into store A is pushed by A and imported by B; the pull echo
on A only confirms its existing local-to-wire mapping and does not create a
second local message.

HTTP 410 (`resync-required`) is terminal. Stage 1 never rewinds or resets the
transport cursor automatically. JSONL and other drivers that do not advertise
`capabilities=stage1-sync` remain valid local-only drivers.
