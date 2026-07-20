# agmsg remote storage reference server

This directory contains the thin, self-hosted PostgreSQL reference
implementation of the [HTTP API v1 contract](spec/v1.md). It is independent of
the root installer package and desktop app.

The server currently implements the v1 plaintext envelope (`cipher: "none"`).
It stores envelope blobs opaquely and does not inspect sender, recipient, body,
or client creation time. Authentication is a deployment concern in the protocol;
this reference uses one required bearer token and still authorizes every
team-scoped operation against an immutable `Agmsg-Team-ID`.

## Run with Compose

Change the token and database password in `compose.yaml` before exposing the
service outside a local development machine, then run:

```sh
docker compose up --build
```

`GET /v1/health` is available without credentials. The message, member, and
capability endpoints require these headers:

```http
Authorization: Bearer <AGMSG_SERVER_TOKEN>
Agmsg-Protocol-Version: 1
Agmsg-Team-ID: <immutable UUIDv7 team ID>
```

## Run from source

Node.js 22 and PostgreSQL 17 are the reference versions.

```sh
npm install
export DATABASE_URL=postgresql://localhost/agmsg
export AGMSG_SERVER_TOKEN='replace-with-at-least-16-bytes'
npm run migrate
npm run provision -- example/team.json
npm run dev
```

The server also runs the idempotent migration at startup. Team creation and
roster mutation remain outside HTTP v1: the provisioning command atomically
applies the complete operator-owned roster manifest. IDs and retired names are
checked against permanent identity history before replacement.

## Verify

Integration tests use an isolated, randomly named PostgreSQL schema. The test
only removes the schema it created and validates its generated name first.

```sh
export TEST_DATABASE_URL=postgresql://localhost/agmsg_test
npm run typecheck
npm test
npm run build
```

The integration suite covers atomic batch rollback, complete input-order ack
mapping, transactional team sequence allocation, UUID conflict handling,
retention tombstones, cursor floors, capability snapshots, roster reads, and
strict JSON framing.
