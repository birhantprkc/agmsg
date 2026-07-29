# Handoff: rewrite `tests/test_remote.bats` for the register model

**Not part of the PR — delete this file before merging.** It is the map for the
one remaining piece of step 3 (Done-when 5, "test_remote.bats passes"). The plane
itself is done and validated; this is only the test rewrite.

## What already shipped on this branch (feat/remote-connect)

The client `connect` was rewritten from the pairing-exchange model to the
register model, and the data plane was made authless. Concretely:

- `remote.sh connect --endpoint <url> <team>` (no token, no `--force`). It reads
  the team's locally-minted `team_id` + roster (`.agents`) from
  `teams/<team>/config.json`, POSTs them to `/v1/connect`, records a binding with
  **no `credential_id`**, migrates the team to its per-team store
  (`migrate-team-store.sh`), and starts a background sync engine.
- A duplicate `team_id` comes back **409** (`team-already-exists`). There is no
  `--force` rebind.
- The sync engine is a background daemon: `_remote_sync_engine_start/stop` in
  remote.sh, pidfile at `$CONNECTION_ROOT/run/remote-sync.<team>.pid`, SIGTERM to
  stop, `_agmsg_pid_alive` for liveness. `disconnect` stops it.
- Server: `scopedTeamId` takes the team from the `Agmsg-Team-ID` header alone
  (no credential). `scopedCredential` stays only for `/v1/pairing/exchange` and
  `/v1/credentials/:id/revoke`, which are untouched (removed in step 7).
- Client engine (`remote-sync.mjs`): no `Authorization` header, no credential
  file; `readConnectedCredential`/`credentialPath` removed; binding has no
  `credential_id`.
- The bats **mock** already gained `POST /v1/connect` (200 capability snapshot,
  409 on a repeat `team_id`) — see `tests/helpers/mock_remote_server.py`.

Validated end-to-end against a real reference server: register, per-team migrate,
history upload, engine runs and stops, 409 on the second connect. `set -u`-safe
now (the connect cleanup trap was fixed to guard `${var:-}`).

## The test surgery (40 currently-failing tests)

Rule applied per test (pm's condition): **does the client still do the behavior
this test verifies?** No → delete, one-line reason. Yes → adapt to the new form.
Do NOT bulk-delete "because it's connect-related" — some verify still-live
behavior (endpoint validation, response bounds).

### DELETE — behavior the register client no longer does (each needs a 1-line PR reason)

The whole pairing/token/credential/exchange path is gone; connect issues no
credential and validates no exchange response.

- 12 `connect: rejects an exchange response with a path-injection-shaped credential_id` — no exchange response, no credential_id.
- 13 `connect: rejects an exchange response missing a required field` — no exchange response.
- 14 `connect: rejects an exchange response with a duplicate JSON key (D4)` — no exchange response (the connect response carries no secret to smuggle).
- 15 `connect: rejects an exchange response with an unrecognized field (D4)` — no exchange response.
- 16 `connect: rejects a credential containing a raw control character (E3)` — no credential.
- 18 `connect: credential file is 0600 and never appears in team config.json` — no credential file is written.
- 19 `connect: bare positional token warns on stderr; --token-stdin does not` — no token argument at all.
- 20 `connect: bad token surfaces the exchange endpoint's HTTP error` — no token/exchange.
- 21 `connect: refuses to rebind an already-connected team without --force` — no `--force`; a duplicate team_id is a 409 (covered by a new test).
- 22 `connect: --force allows rebinding an already-connected team` — no `--force`.
- 23 `connect: --force revokes the OLD credential before establishing the new one (B5)` — no credential to revoke.
- 24 `connect: --force refuses to rebind if the old credential can't be confirmed revoked` — no credential.
- 25 `connect: --force rejects a 200 revoke body that does not match the binding` — no revoke on connect.
- 26 `connect: --force bounds revoke response before validation` — no revoke on connect.
- 27 `connect: --force requires an explicit <team> (refuses when omitted)` — no `--force`.
- 28 `connect: --force does not blindly overwrite an unexpected binding it never revoked (D1)` — no `--force`/revoke.
- 30 `connect: uses the exchange response's remote_team_name when <team> is omitted` — no exchange; `<team>` is required and read locally.
- 31 `connect: encryption required + empty stream still requires an explicit 'g' to generate` — connect no longer runs the E2EE key-bootstrap prompt (cipher:none is the base; key.sh stands alone). *E2EE machinery is untouched — this deletes the test of the removed connect-time prompt, not the E2EE code.*
- 32 `connect: token stdin remains separate from the E2EE generate prompt` — no token; no connect prompt.
- 33 `connect: encryption required + existing history still requires an explicit 'i' to import` — no connect E2EE prompt.
- 34 `connect: token stdin remains separate from the E2EE import prompts` — no token; no connect prompt.
- 35 `connect: encryption required + empty/EOF input on the choice prompt safely aborts` — no connect prompt.
- 36 `connect: aborting the encryption prompt leaves the binding but no key, visible via status` — no connect prompt.
- 37 `connect: missing age binary blocks the encryption bootstrap with an install hint` — no connect E2EE bootstrap (the age-hint now lives only in `doctor`, out of scope here).
- 40 `connect: quarantines legacy pending recovery material without committing it` — connect no longer uses the pending machinery.
- 41 `connect: resumes from a hand-crafted pending record without a fresh network call` — connect no longer resumes from pending.
- 42 `connect: resuming after the commit already fully succeeded is an idempotent no-op (R3)` — no pending/resume on connect.
- 54 `pending list: does not list a record that already fully committed` — connect no longer creates pending records. *(The `pending` machinery itself stays until step 7 — but this test drives it via connect, which no longer does.)*
- 64 `connect: blocks (does not resume/commit) when a concurrent pending abort already holds this pending_id's lock` — connect takes no pending lock.

### ADAPT — still-live behavior whose shape changed

- 5 `connect: http://127.0.0.1 (loopback) is accepted without https` — endpoint validation is unchanged and still accepts loopback, but connect now proceeds to read a **local team** and POST /v1/connect. Give the test a local team (`teams/myteam/config.json` with a `team_id` + one agent) so it reaches and succeeds at register. (Failure-path endpoint tests — non-HTTPS, no-scheme, subdomain/userinfo bypass — already PASS unchanged: validation fails before any config read.)
- 17 `connect: happy path, no encryption required` — keep as the happy path but drop the credential-file assertion; assert instead that the team registers (`Connected: … Sync engine running.`), a binding is written, and **no** `run/remote-credentials/<team>.json` exists.
- 29 `connect: after disconnect, reconnecting the same team needs no --force` — the model changed: disconnect does not unregister server-side, so a reconnect of the same `team_id` now gets **409**. Either rewrite to assert that, or fold into the new 409 test and delete.
- 39 `status: with no <team> lists every locally-known connected team` — binding no longer has `credential_id`; set up via the new connect, adjust expectations.
- 43 `disconnect: revokes server-side then clears local state` — no server revoke now; disconnect stops the engine and clears local state. Rewrite to assert engine-stopped + local-cleared (drop the revoke assertion).
- 44 `disconnect: server unreachable for revoke still clears local state, with a warning` — the revoke path is old-path noise now (still prints because the old code runs with no credential; cleaned in step 7). Decide: assert local-cleared + engine-stopped, or delete the revoke-specific assertion.
- 45 `disconnect: does not claim revoke success without the protocol response header` — revoke-on-disconnect is gone; delete or fold into the disconnect rewrite.
- 47 `status --json: reports the strict schema for an active connection` — the active-connection schema no longer includes `credential_id`. Set up via the new connect and update the expected strict schema.
- 48 `status --json: reports state=disconnected after disconnect` — same schema change; set up via new connect.
- 51 `status --json: with no <team>, emits one JSONL line per connected team` — same schema change.
- 52 `status: a team name containing a single quote doesn't break status` — its setup uses the old connect; re-drive via the new connect (the #87-class SQL property under test is unchanged).

*(Note: disconnect still prints a "Revoking credential… failed" line because the old revoke code runs with no credential present. That is old-path noise removed in step 7; the ADAPT tests above should not assert on it.)*

### ADD — one per revised Done-when item (see PR body)

- **Done-when 1** — `connect: registers a client-owned team` (mock `/v1/connect` 200; assert binding written, `Connected`).
- **Done-when 2** — `connect: moves the team into its own per-team store` (assert `<store>/teams/<team>/messages.db` exists and the team's rows are gone from the shared store). Needs a local team with a seeded shared-store message.
- **Done-when 3** — `connect: uploads existing history` — the engine push is best asserted at the reference-server level (the vitest sync path) rather than the python mock; if kept in bats, extend the mock to record POSTs to `/v1/messages`. Validated manually end-to-end already; a bats version is optional but nice.
- **Done-when 4** — `connect: starts a background sync engine that disconnect stops` (assert the pidfile + a live pid after connect; assert the pidfile gone + pid dead after disconnect).
- **Done-when 5/uniqueness** — `connect: refuses a second connect for the same team_id with 409` (mock returns 409 on the repeat).

**Why the suite shrinks** (for the PR body): the register model removes tokens,
credential files, the exchange response, `--force` rebinding, server-side revoke
on connect, and the connect-time E2EE prompt — so a large block of security
properties simply has no surface anymore. The remaining connect surface is:
endpoint validation, response bounds, register, 409, migrate, engine lifecycle.

## Practical notes for whoever picks this up

- Run: `bats tests/test_remote.bats` (needs `bats`, `python3`, `node`). The mock
  starts in `setup()`; it now answers `/v1/connect` too.
- A local team for the success-path tests is just a `teams/<team>/config.json`
  with `{ "name", "team_id": <uuidv7>, "agents": { "<name>": { "member_id": <uuidv7> } } }`
  and an initialized store (`storage_init` under `AGMSG_STORAGE_PATH`); see the
  end-to-end steps used to validate the plane.
- `migrate-team-store.sh` resolves the team via `$SKILL_DIR/teams` (NOT
  `AGMSG_SYNC_CONNECTION_DIR`), so a test that sets a custom connection dir must
  keep `SKILL_DIR/teams` aligned, or not set a custom connection dir.
- PR body must carry three lines pm asked for: (1) connect starts a continuous
  engine (not just `once`); (2) the pidfile lifecycle now lives in two places
  (this engine + watch.sh), shared-lib extraction deferred; (3) the disconnect
  "revoke failed" message is old-path noise removed in step 7.
