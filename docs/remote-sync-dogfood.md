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

The command emits timestamped JSONL lifecycle events. Set a log file to retain
the exact push/ack/pull/import trace; the file is append-only from the client's
perspective and includes imported plaintext bodies:

```sh
export AGMSG_SYNC_LOG_FILE=/path/to/stage1-dogfood.jsonl
scripts/remote-sync.sh once --team example-team
```

For a single-host two-machine simulation, repeat configuration with two
different `AGMSG_STORAGE_PATH` directories and the same immutable remote team
ID. A message sent into store A is pushed by A and imported by B; the pull echo
on A only confirms its existing local-to-wire mapping and does not create a
second local message.

HTTP 410 (`resync-required`) is terminal. Stage 1 never rewinds or resets the
transport cursor automatically. JSONL and other drivers that do not advertise
`capabilities=stage1-sync` remain valid local-only drivers.
