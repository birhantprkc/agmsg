# ADR 0010: Local-first onboarding and convergent rosters

**Status:** proposed (design gate)
**Date:** 2026-07-24
**Deciders:** @fujibee

## Context

The canonical product story is local-first:

1. install agmsg;
2. create a team and its members with the local CLI; and
3. connect that local team to a remote service.

A second, clean installation may join an already-promoted team by pulling its
canonical identity and retained history. Pull is a join operation; it never
creates a remote team. V1 does not merge two independently populated teams.

The current onboarding implementation has the opposite creation order. A server
operator first creates a team and provisions its roster, then issues a
team-scoped pairing token. The token exchange immediately creates an active,
team-bound credential. This assumption is present in the database as well as the
CLI: `pairing_tokens.team_id` and `credentials.team_id` are non-null references
to an existing team.

Adding one `promote` endpoint after that exchange would create two overlapping
onboarding state machines. It would leave unclear which operation creates the
team, how an unbound credential is authorized, how a client distinguishes
promotion from joining, and what survives a response-loss crash between those
steps.

At the same time, the existing implementation contains reviewed components that
must not be discarded:

- opaque, single-use, short-lived pairing tokens;
- independently revocable per-device credential IDs and secret digests;
- strict protocol, server-instance, team, capability, and response binding;
- private credential and key storage;
- Stage-1 durable reservation, full acknowledgement reconciliation, pull
  quarantine, and transport progress;
- Stage-2 read-state separation; and
- the `none` and `age-v1` envelope profiles.

This ADR replaces only the team-establishment portion of onboarding. It
supersedes ADR 0007's assumptions that every pairing token is already
team-scoped, that exchange immediately returns an active credential binding,
and that the console or reference-server admin creates the team. ADR 0007's
command shape, secret handling, status, doctor, disconnect/revoke, and key
handling remain in force unless this ADR says otherwise.

## Decision

We choose a **surgical rewrite of the onboarding state machine**, not an
additive `promote` endpoint on the current one-shot exchange and not a rewrite
of remote synchronization.

The one user action, `agmsg remote connect`, performs one of two strictly
separated operations:

- **Promote:** an existing local team, with a local identity catalog, becomes
  the canonical remote team. Its roster is created transactionally and its
  complete shareable local history is subsequently backfilled through Stage 1.
- **Join:** a clean local target pulls an existing remote team's immutable
  identity catalog, current roster revision, policy, and retained history. It
  does not create or merge a remote team.

Internally, connect uses a two-phase protocol. Exchange creates a short-lived
onboarding session and a future credential secret. Finalize atomically promotes
or joins the team and activates that same secret as the long-lived credential.
The CLI durably stores the pending session before finalize. The user still runs
one command.

## Local identity model

### Stable team and member IDs

Local team configuration becomes the source of stable identity instead of a
projection of server provisioning.

Every new local team gets a canonical UUIDv7 `team_id` when the local CLI first
creates it. Every member gets a canonical UUIDv7 `member_id` when the local CLI
first creates that member. IDs are generated once with a cryptographically
secure generator and are never regenerated on retry, rename, connect,
disconnect, storage compaction, or remote rebind.

An existing v1 local configuration is upgraded under the existing team-config
lock:

1. generate and durably write one `team_id`;
2. generate and durably write one `member_id` for every current agent name;
3. give every local registration stable `registration_id` and
   `installation_id` values; and
4. only then expose the upgraded identity document to onboarding.

The upgrade is one atomic config replacement. A crash before replacement
publishes no IDs; a crash after replacement reuses every published ID.

The v2 local shape separates the team member catalog from machine-local agent
placements:

```json
{
  "schema_version": 2,
  "name": "example-team",
  "team_id": "018f3f7e-0000-7000-8000-000000000001",
  "members_revision": null,
  "members": {
    "018f3f7e-0000-7000-8000-000000000010": {
      "name": "worker-1"
    }
  },
  "agents": {
    "worker-1": {
      "member_id": "018f3f7e-0000-7000-8000-000000000010",
      "registrations": [
        {
          "registration_id": "018f3f7e-0000-7000-8000-000000000011",
          "installation_id": "018f3f7e-0000-7000-8000-000000000012",
          "type": "codex",
          "project": "/machine-local/path"
        }
      ]
    }
  }
}
```

`members` is the portable identity catalog. `agents` contains local placements.
Machine-local project paths never enter the remote roster. A clean joining
device materializes the member catalog but does not invent local agent
registrations for remote machines.

`members_revision` is null until the first successful promote or join finalize.
Afterward it is the last server revision durably incorporated locally. Pending
local roster operations live in a separate durable outbox; they do not
speculatively increment the server revision.

### First creator is canonical

Within a team, a normalized member name is permanently anchored to the first
accepted `member_id`. The existing server identity-history tables enforce that
retired names and IDs cannot be rebound.

The local `join` command follows these rules:

- if the local member catalog already contains the normalized name, reuse that
  `member_id` and add only a new local registration;
- otherwise create a new `member_id` once and enqueue the roster mutation; and
- never infer identity from a message's opaque sender or recipient projection.

If a concurrent client creates the same normalized name under a different
`member_id`, the first server-accepted mutation is canonical. The loser stops
with an identity conflict. It MUST NOT silently rewrite message history or
alias the two members. The operator may rename an unaccepted local member and
retry. Deleting or rewriting a member that already owns local messages or read
facts requires a separate explicit repair design.

## Connect mode selection

Pairing tokens have one immutable purpose:

- a **promote token** is a single-use capability to create exactly one team on
  the server. It is server/account scoped, not org-wide, cannot select or modify
  an existing team, and expires after 15 minutes;
- a **join token** is scoped to exactly one existing immutable team and one
  device join.

The client sends its intended mode during exchange, and the token purpose MUST
match. A purpose mismatch is terminal and creates no session.

| Local target | Token purpose | Result |
| --- | --- | --- |
| Existing local team, no active binding | promote | Promote |
| No local team/config/store at target | join | Join and pull |
| Existing local team without an exact prior binding | join | Reject: both sides are populated |
| No local team/config/store | promote | Reject: there is no local authority to promote |

An exact-ID recovery of an interrupted prior promotion is a retry, not a merge.
A disconnected local team with a prior binding may reattach only when the join
token names that exact `server_instance_id` and `team_id`, the locally retained
member IDs descend from that binding, and the ordinary revision reconciliation
finds no identity conflict. This is lifecycle recovery under ADR 0007, not a
third creation mode. A local team with no proof of that prior binding cannot use
a join token merely because its display name or claimed team ID matches.

For promote, an explicit local team is required unless the CLI can identify
exactly one eligible local team without prompting. Provider tooling MUST pass
the explicit team in non-interactive use. For join, the remote display name is
the default local name and the existing local-name override remains available.

## Onboarding protocol

### Phase 1: exchange a pairing token for a pending session

`POST /v1/pairing/exchange` remains the only endpoint that receives the opaque
pairing token. Its strict request becomes:

```json
{
  "token": "agmsg_pair_opaque",
  "onboarding_id": "550e8400-e29b-41d4-a716-446655440000",
  "intent": "promote"
}
```

`onboarding_id` is a client-generated UUIDv4, generated once and durably stored
with the local onboarding intent before network exposure. `intent` is
`promote` or `join`.

A successful exchange consumes the token and creates an
`onboarding_sessions` row, not an active team credential. The response contains:

```json
{
  "protocol_version": 1,
  "server_instance_id": "018f3f7e-0000-7000-8000-000000000000",
  "onboarding_session_id": "018f3f7e-0000-7000-8000-000000000020",
  "onboarding_id": "550e8400-e29b-41d4-a716-446655440000",
  "intent": "promote",
  "credential_id": "018f3f7e-0000-7000-8000-000000000021",
  "credential": "agmsg_credential_opaque-value",
  "expires_at": "2026-07-24T06:30:00.000000Z",
  "onboarding_policy": {
    "accepted_envelope_versions": [1],
    "write_allowed_ciphers": ["none", "age-v1"],
    "max_blob_bytes": "1048576"
  }
}
```

For join, the response also identifies the token's existing `remote_team_id`.
For promote, no remote team exists yet, so the response MUST NOT manufacture a
team binding.

The returned credential secret is the future long-lived device secret, but
before finalize it authenticates only the finalize and onboarding-status
endpoints. Sync, roster mutation, message, member, read-state, and revoke
endpoints reject it as not active. The server stores only its domain-separated
digest. The reference session expires 30 minutes after exchange; the exact
timestamp is returned and clients do not guess it.

The client writes the session ID, onboarding ID, purpose, credential ID, secret,
endpoint, and exact exchange response into its private pending store before it
calls finalize. Binding JSON remains secret-free.

If the exchange response is lost before the client stores it, the short-lived
session expires without creating a team or active credential. The operator may
issue a new token. This failure no longer creates an unknown live device
credential or orphan team.

### Phase 2: idempotent finalize

The pending credential authenticates:

```http
POST /v1/onboarding/finalize
Authorization: Bearer <pending credential>
Agmsg-Protocol-Version: 1
Content-Type: application/json
```

The promote request contains the local identity document:

```json
{
  "onboarding_id": "550e8400-e29b-41d4-a716-446655440000",
  "intent": "promote",
  "team": {
    "team_id": "018f3f7e-0000-7000-8000-000000000001",
    "team_name": "example-team",
    "members_revision": null,
    "members": []
  },
  "history": {
    "mode": "all",
    "snapshot_id": "driver-defined-opaque-id",
    "message_count": "0"
  }
}
```

The join request contains only the onboarding ID, `intent: "join"`, and the
local installation ID. The join target comes exclusively from the token; the
client cannot substitute a team ID.

Finalize locks the onboarding session. It canonicalizes and hashes the exact
request. In one transaction it:

- for promote, verifies that the team ID and normalized name are unused, creates
  the team with the token's policy, applies the initial roster and permanent
  identity history, activates the pending credential for that team, and marks
  the session finalized;
- for join, locks the token-selected existing team, activates the pending
  credential for it, and marks the session finalized; and
- returns one binding, complete capability snapshot, complete roster snapshot,
  and resulting `members_revision` from the same team-row snapshot.

The server stores `(onboarding_session_id, onboarding_id, request_digest,
resulting_team_id, credential_id, finalized_at)`. An exact retry returns the
same canonical response. Reusing either ID with a different request is
`409 onboarding-conflict`.

The credential secret is not returned again by finalize because the client
already durably holds it. Finalize promotes that exact secret digest into the
ordinary `credentials` table. There is no second secret and no response-loss
orphan.

An unfinalized expired session cannot create a team and returns
`410 onboarding-session-expired`. A finalized session remains available for
exact result recovery after its original expiry; expiry MUST NOT make a
committed result locally unrecoverable.

The client validates the response binding, roster, revision, capabilities, and
onboarding IDs before atomically committing the local binding. A crash after
server commit but before local commit retries finalize and receives the same
result.

Onboarding responses use `Cache-Control: no-store`, strict UTF-8 JSON,
duplicate/unknown-field rejection, bounded bodies and headers, no redirects,
and the existing protocol-header rules. Access logs, APM, and traces MUST redact
pairing tokens, pending credentials, and response bodies.

The minimum error contract is:

| HTTP | Code | Meaning and client action |
| --- | --- | --- |
| 401 | `invalid-pairing-token` | Unknown token; stop and request another |
| 401 | `invalid-onboarding-credential` | Pending secret is absent or invalid; stop |
| 409 | `pairing-token-consumed` | Token was already exchanged; recover a locally stored session or reissue after the old session expires |
| 409 | `onboarding-intent-conflict` | Token purpose and local mode differ; no automatic fallback |
| 409 | `onboarding-conflict` | An onboarding/session ID was reused with different canonical input; stop |
| 409 | `team-identity-conflict` | Promote collided with an existing team ID or normalized name; never adopt it implicitly |
| 409 | `both-sides-populated` | Join target is not clean; do not merge |
| 410 | `pairing-token-expired` | Token expired before exchange; request another |
| 410 | `onboarding-session-expired` | Unfinalized session expired; preserve recovery audit, then request another |

Transport loss and retryable `5xx` preserve the existing exact-request retry
rules. Definitive `409` and `410` outcomes are not busy-retried.

### E2EE insertion point

The exchange response's onboarding policy is the input to the existing
`none`/`age-v1` branch. Private age identities stay local and never enter either
onboarding request.

For promotion into an E2EE-required policy, connect completes the existing
generate/import/abort key flow before finalize and includes only the approved
public epoch snapshot or its pinned reference in the initial team document.
For join, finalize returns the current public epoch metadata. Missing private
key material does not weaken policy: the binding may complete, but ciphertext
remains in `pending_key` quarantine until the existing key-import and reprocess
flow succeeds.

The exact epoch-authority wire document remains owned by the age-v1 profile; this
ADR does not invent a second key format or put key distribution in roster
state.

## Convergent roster API

`GET /v1/members` remains the canonical roster read. A new ordinary,
team-credential endpoint replaces privileged provisioning:

```http
PUT /v1/members
Authorization: Bearer <ordinary team credential>
Agmsg-Protocol-Version: 1
Agmsg-Team-ID: <immutable team UUIDv7>
Content-Type: application/json
```

```json
{
  "roster_mutation_id": "550e8400-e29b-41d4-a716-446655440001",
  "expected_members_revision": "7",
  "team_name": "example-team",
  "members": []
}
```

The request is a complete desired roster, uses all existing member,
registration, normalization, cardinality, and retirement rules, and carries no
machine-local path.

The server locks the team row and:

1. compares `expected_members_revision`;
2. validates every immutable identity and permanent name/ID history rule;
3. atomically replaces the current roster;
4. increments `members_revision`; and
5. records the mutation ID, canonical request digest, and resulting revision.

An exact mutation retry returns the same revision and snapshot. Reusing the
mutation ID with different bytes is `409 roster-mutation-conflict`. A stale
expected revision is `409 members-revision-conflict` and includes the current
revision and roster digest; the client refetches `GET /v1/members` before any
rebase.

There is no administrator credential tier in this protocol. Every active team
credential may submit a roster mutation. This makes credential compromise a
roster-integrity risk as well as a message/read-availability risk; documentation
and revocation UX MUST say so.

The local CLI remains the only product-facing team/member creation and mutation
surface. It updates the local identity catalog and a durable roster outbox in
one local transaction. The sync engine publishes the outbox through this API.
A revision conflict is never resolved by last-writer-wins. Disjoint changes may
be replayed on a freshly fetched roster; identity/name conflicts stop
fail-closed for explicit local resolution.

## Sub-decisions

### A. Promote complete history, not a silent window

Promotion captures one durable storage-driver snapshot boundary and backfills
every shareable local message at or before that boundary. Messages created
after the boundary follow normal Stage-1 ordering. The CLI shows the message
count and estimated bytes before finalize; it does not silently choose a recent
window.

The driver records a stable promotion snapshot ID, generation, cutoff, count,
and digest before finalize. Stage-1's contiguous push cursor proves completion
through that cutoff. `remote status` distinguishes:

- `promoting-roster`;
- `backfilling-history (acked/total)`;
- `connected`; and
- a terminal conflict or policy/key block.

Existing Stage-1 encrypt-once, ack reconciliation, and exact retry rules own the
actual upload. No onboarding endpoint accepts message bodies.

`connect` reports success once the binding and canonical roster are committed
locally and the durable history snapshot is queued; it does not hold a terminal
open until an arbitrarily large archive uploads. The ordinary polling engine
continues the backfill. A second device may join while backfill is in progress
and will converge as later server sequences arrive.

The bundled SQLite promotion path MUST include pre-event-log legacy rows rather
than silently leave them local-only. It may materialize a durable,
driver-private promotion queue, but it MUST preserve stable local identity,
recipient read facts, and a deterministic total order without duplicating
local inbox/history projection. A driver that cannot prove a complete stable
snapshot fails promotion before finalize.

Server retention remains independent. A server may later retain only its
configured live window, but the client never labels a partial local selection
as a complete promotion. A future explicit history-window product is a separate
interface and policy decision.

### B. Make every externally visible transition retryable

The required crash outcomes are:

| Failure point | Durable result |
| --- | --- |
| Before local identity upgrade commit | No published new IDs |
| After identity upgrade commit | Exact IDs reused |
| Before exchange response is stored | Expiring pending server session only; no team or active credential |
| After pending session store, before finalize | Retry exact finalize |
| After finalize commit, before response/local binding commit | Retry returns identical binding and roster |
| During local binding commit | Server result remains recoverable through pending session |
| During history seal/reserve | Existing Stage-1 pre-publication abandon or exact-envelope reuse |
| After message POST, before ack reconcile | Exact wire/envelope replay and canonical ack |

Pending onboarding state is never deleted merely because it is old or malformed.
It is quarantined as private recovery material until expiry plus server-confirmed
session cancellation, successful finalize, or explicit operator cleanup after
credential/team inventory.

### C. A clean second device adopts canonical member IDs

A join finalize requires that the local target team config and selected store do
not exist. It atomically materializes the remote `team_id`, team name,
`members_revision`, and complete member catalog locally before enabling sync.
It then pulls from the authenticated retention floor.

The pull does not create local agent placements. When the user later runs the
local join/act-as flow with an existing normalized member name, the CLI reuses
the pulled canonical `member_id` and creates only a new registration. It MUST
NOT mint a second member ID for that name.

If any local team config, local history, independent member catalog, or
non-empty target store already exists, join refuses. V1 does not compare and
merge both sides. This restriction is what makes automatic adoption safe.

### D. Demote raw server operations to escape hatches

The primary self-host quickstart no longer contains `team create`,
`provision.js`, a roster JSON file, or `psql`.

Self-host and hosted management surfaces issue only:

- a one-team promote token for the first local authority; or
- a team-scoped join token for a clean additional device.

The reference admin `token issue` command may remain as the self-host token
delivery mechanism, but promote-token issuance takes no team name or roster and
cannot itself create a team.

`provision.js` becomes an explicitly low-level client of the same
`PUT /v1/members` endpoint. It requires an ordinary team credential,
`expected_members_revision`, and `roster_mutation_id`; it receives no privileged
database path. It is suitable for scripted repair or bulk input, not onboarding.

Direct SQL is an unsupported offline recovery escape hatch. It is not a
protocol authority and cannot safely bypass identity history, revision,
mutation-id, or read-state invariants. Reference documentation removes it from
normal setup and warns that the server must be stopped and invariants audited
before any emergency database repair.

## Ownership boundary

The implementation is split by contract, not by file convenience.

### Server/sync track (aggie-co2)

- HTTP/spec changes for onboarding exchange/finalize and roster mutation;
- `onboarding_sessions`, pending-to-active credential transition, mutation
  dedupe, team/roster transaction, and capability snapshot;
- reference-server token purposes and admin/quickstart demotion;
- sync-engine promotion snapshot/backfill orchestration and status;
- SQLite/JSONL promotion boundary, including legacy SQLite history; and
- protocol/integration tests for crash, response loss, concurrency, identity
  conflicts, and full backfill.

### Local CLI track (aggie-cc2)

- local config v2 and atomic UUID migration;
- `join`/`team` member catalog versus local registration behavior;
- `remote connect` local-exists/clean-target detection and intent selection;
- durable pending onboarding session, exact finalize retry, and local binding
  commit;
- clean-device roster materialization and same-name member-ID reuse; and
- human UX for promote progress, join refusal, conflicts, and recovery.

Both tracks consume the exact JSON schemas and error matrix pinned by the HTTP
spec. Neither track may independently reinterpret a field or add a fallback
merge.

## Compatibility and rollout

This is a pre-release dogfood stack, so the protocol does not preserve the old
server-first onboarding flow.

- Existing active dogfood bindings remain usable for sync while the new flow is
  developed.
- New onboarding uses only the new session/finalize protocol after cutover.
- There is no automatic conversion of an old consumed pairing token.
- Draft servers may offer a temporary feature flag for tests, but published v1
  documents one canonical local-first flow.
- ADR 0007 is updated to point its superseded creation/exchange sections here;
  its unaffected security and UX requirements remain normative.

## Rejected alternatives

- **Add promotion after the current one-shot exchange.** Rejected because the
  current exchange requires an existing team and creates an active credential.
  Weakening those constraints would leave credential activation, team creation,
  and response-loss recovery split across incompatible transactions.
- **Rewrite the full remote stack.** Rejected because synchronization,
  credential secrecy/revocation, binding validation, E2EE, and cursor layers are
  independent of who creates the first team and have already survived
  adversarial review.
- **Keep server-first team creation as a self-host exception.** Rejected because
  it creates two product stories and makes E2EE/local-first behavior appear to
  be a hosted-only downgrade.
- **Infer promote versus join from server name lookup.** Rejected because names
  are mutable display values, leak existence, and cannot authorize creation or
  joining. Token purpose and local state decide the mode.
- **Merge two populated teams automatically.** Rejected for v1. There is no safe
  automatic answer for duplicate semantic messages with different wire IDs,
  same-name members with different IDs, divergent read facts, or independent
  E2EE epochs.
- **Upload only a recent history window by default.** Rejected because it makes
  the second device silently incomplete and turns retention/product policy into
  an irreversible client-side omission.
- **Keep `provision.js` or SQL as a privileged roster authority.** Rejected
  because it bypasses the same convergence and concurrency rules every local
  client must obey.

## Consequences

- Positive: the only team-creation story starts locally and uses the same CLI
  for hosted and self-hosted deployments.
- Positive: immutable member IDs exist before messages are promoted, so roster,
  read state, and future device registration share one identity anchor.
- Positive: response loss cannot leave an unknown active credential or orphan
  team; finalize is exactly retryable.
- Positive: current Stage-1, Stage-2, and E2EE work remains the transport and
  confidentiality foundation.
- Negative: local team configuration needs a versioned identity migration and a
  member-catalog/registration split.
- Negative: onboarding requires a new pending-session table and an incompatible
  pairing exchange response.
- Negative: full legacy-history promotion requires additional bundled-driver
  work before existing SQLite installations are genuinely supported.
- Negative: ordinary device credentials can mutate the roster, increasing the
  impact of credential compromise.
- Neutral: cloud consoles and self-host admin tools still issue access tokens
  and show/manage device credentials, but they no longer create product teams
  or author rosters.

## Implementation gates

Implementation does not begin until adversarial review closes at least:

1. exchange/finalize response-loss, expiry, cancellation, and concurrent retry;
2. promote-token authority and inability to modify existing teams;
3. join-token team binding and clean-target proof;
4. initial roster and credential activation in one team transaction;
5. roster mutation idempotency, revision races, name/ID conflicts, and
   retirement;
6. atomic local UUID migration and same-name canonical adoption;
7. full event-log plus legacy SQLite snapshot and Stage-1 completion proof;
8. E2EE-required promote/join without private-key or plaintext leakage;
9. no team/message/member creation from opaque message contents; and
10. removal of server-first/raw provisioning from the primary quickstart.

## References

- [ADR 0005: Stage-1 remote sync](0005-stage-1-remote-sync.md)
- [ADR 0006: E2EE-first-class server schema](0006-e2ee-first-class-server-schema.md)
- [ADR 0007: Remote connect onboarding UX](0007-remote-connect-onboarding-ux.md)
- [ADR 0008: Stage-2 read-state synchronization](0008-stage-2-read-cursor-sync.md)
- [HTTP API v1](../../server/spec/v1.md)
