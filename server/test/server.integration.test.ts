import { randomBytes } from "node:crypto";
import { execFile } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import type { Config } from "../src/config.js";
import { migrate } from "../src/db.js";
import { retainThrough } from "../src/storage.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
const describeDatabase = databaseUrl ? describe : describe.skip;
const execFileAsync = promisify(execFile);

describeDatabase("remote storage HTTP API v1", () => {
  const schema = `agmsg_test_${randomBytes(8).toString("hex")}`;
  const token = "integration-test-token-32-bytes";
  const teamId = "018f3f7e-0000-7000-8000-000000000001";
  const memberId = "018f3f7e-0000-7000-8000-000000000010";
  const registrationId = "018f3f7e-0000-7000-8000-000000000011";
  const installationId = "018f3f7e-0000-7000-8000-000000000012";
  let admin: Pool;
  let pool: Pool;
  let app: ReturnType<typeof createApp>;

  const config: Config = {
    databaseUrl: databaseUrl ?? "",
    token,
    host: "127.0.0.1",
    port: 8787,
    logLevel: "silent",
  };

  const headers = {
    authorization: `Bearer ${token}`,
    "agmsg-protocol-version": "1",
    "agmsg-team-id": teamId,
  };

  beforeAll(async () => {
    admin = new Pool({ connectionString: databaseUrl });
    await admin.query(`CREATE SCHEMA ${schema}`);
    pool = new Pool({
      connectionString: databaseUrl,
      options: `-c search_path=${schema}`,
    });
    await migrate(pool);
    await pool.query(
      `INSERT INTO teams (team_id, team_name) VALUES ($1, 'example-team')`,
      [teamId],
    );
    await pool.query(
      `INSERT INTO team_policy_history
         (team_id, policy_revision, effective_from_seq,
          accepted_envelope_versions, write_allowed_ciphers)
       VALUES ($1, 0, 1, ARRAY[1], ARRAY['none']::TEXT[])`,
      [teamId],
    );
    await pool.query(
      `INSERT INTO members (team_id, member_id, name)
       VALUES ($1, $2, 'worker-1')`,
      [teamId, memberId],
    );
    await pool.query(
      `INSERT INTO registrations
         (team_id, registration_id, member_id, installation_id, type)
       VALUES ($1, $2, $3, $4, 'codex')`,
      [teamId, registrationId, memberId, installationId],
    );
    app = createApp(pool, config);
    await app.ready();
  });

  afterAll(async () => {
    await app.close();
    await pool.end();
    if (!/^agmsg_test_[0-9a-f]{16}$/.test(schema)) {
      throw new Error("refusing to remove an unexpected test schema");
    }
    await admin.query(`DROP SCHEMA ${schema} CASCADE`);
    await admin.end();
  });

  function message(id: string, text: string) {
    const plaintext = JSON.stringify({
      body: text,
      created_at: "2026-07-20T06:30:00.000000Z",
      from_agent: "leader",
      to_agent: "worker-1",
    });
    return {
      id,
      envelope: {
        v: 1,
        cipher: "none",
        key_id: null,
        blob: Buffer.from(plaintext).toString("base64"),
      },
    };
  }

  it("reports readiness and fixes the response protocol version", async () => {
    const response = await app.inject({ method: "GET", url: "/v1/health" });
    expect(response.statusCode).toBe(200);
    expect(response.headers["agmsg-protocol-version"]).toBe("1");
    expect(response.json()).toMatchObject({
      status: "ok",
      protocol: { supported_versions: [1] },
      database: "ok",
    });
  });

  it("requires matching protocol, credentials, and immutable team ID", async () => {
    const noVersion = await app.inject({
      method: "GET",
      url: "/v1/members",
      headers: { authorization: `Bearer ${token}`, "agmsg-team-id": teamId },
    });
    expect(noVersion.statusCode).toBe(426);
    expect(noVersion.json().error.code).toBe("unsupported-protocol-version");

    const noAuth = await app.inject({
      method: "GET",
      url: "/v1/members",
      headers: {
        "agmsg-protocol-version": "1",
        "agmsg-team-id": teamId,
      },
    });
    expect(noAuth.statusCode).toBe(401);
  });

  it("stores a batch atomically and returns complete input-order acknowledgements", async () => {
    const first = message("550e8400-e29b-41d4-a716-446655440000", "first");
    const response = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: { messages: [first, first] },
    });
    expect(response.statusCode).toBe(200);
    expect(response.json().acks).toEqual([
      { id: first.id, server_seq: "1", disposition: "stored" },
      { id: first.id, server_seq: "1", disposition: "duplicate" },
    ]);

    const replay = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: { messages: [first] },
    });
    expect(replay.json().acks[0]).toEqual({
      id: first.id,
      server_seq: "1",
      disposition: "duplicate",
    });

    const conflict = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: {
        messages: [
          message("750e8400-e29b-41d4-a716-446655440001", "would-roll-back"),
          message(first.id, "different"),
        ],
      },
    });
    expect(conflict.statusCode).toBe(409);
    expect(conflict.json()).toMatchObject({
      team_id: teamId,
      error: { code: "message-uuid-conflict" },
    });

    const count = await pool.query<{ count: string }>(
      "SELECT count(*)::text AS count FROM messages WHERE team_id = $1",
      [teamId],
    );
    expect(count.rows[0]?.count).toBe("1");
  });

  it("allocates team sequence without a rollback gap and pages one snapshot", async () => {
    const second = message("750e8400-e29b-41d4-a716-446655440002", "second");
    const stored = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: { messages: [second] },
    });
    expect(stored.json().acks[0].server_seq).toBe("2");

    const page = await app.inject({
      method: "GET",
      url: "/v1/messages?after=0&limit=1",
      headers,
    });
    expect(page.statusCode).toBe(200);
    expect(page.json()).toMatchObject({
      next_after: "1",
      has_more: true,
      messages: [{ server_seq: "1" }],
    });
    expect(page.json().messages[0].server_received_at).toMatch(
      /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/,
    );
  });

  it("advertises one-snapshot capabilities and operator-provisioned members", async () => {
    const capabilities = await app.inject({
      method: "GET",
      url: "/v1/capabilities",
      headers,
    });
    expect(capabilities.statusCode).toBe(200);
    expect(capabilities.headers["cache-control"]).toBe("no-store");
    expect(capabilities.json()).toMatchObject({
      current_seq: "2",
      next_sequence_boundary: "3",
      accepted_envelope_versions: [1],
      write_allowed_ciphers: ["none"],
      policy_revision: "0",
      effective_from_seq: "1",
      policy_history: [{ policy_revision: "0", effective_from_seq: "1" }],
    });

    const members = await app.inject({
      method: "GET",
      url: "/v1/members",
      headers,
    });
    expect(members.json()).toMatchObject({
      members_revision: "0",
      members: [
        {
          member_id: memberId,
          name: "worker-1",
          registrations: [{ registration_id: registrationId, type: "codex" }],
        },
      ],
    });
  });

  it("serializes concurrent writers on the team row", async () => {
    const writes = await Promise.all(
      [
        message("750e8400-e29b-41d4-a716-446655440005", "concurrent-a"),
        message("750e8400-e29b-41d4-a716-446655440006", "concurrent-b"),
      ].map((entry) =>
        app.inject({
          method: "POST",
          url: "/v1/messages",
          headers,
          payload: { messages: [entry] },
        }),
      ),
    );
    expect(writes.map((response) => response.statusCode)).toEqual([200, 200]);
    expect(
      writes
        .map((response) => response.json().acks[0].server_seq)
        .sort((left, right) => Number(left) - Number(right)),
    ).toEqual(["3", "4"]);
  });

  it("retains atomically under the writer lock and keeps tombstones idempotent", async () => {
    await pool.query(
      `CREATE FUNCTION fail_tombstone_insert() RETURNS trigger AS $$
       BEGIN RAISE EXCEPTION 'injected retention failure'; END;
       $$ LANGUAGE plpgsql`,
    );
    await pool.query(
      `CREATE TRIGGER fail_tombstone_insert
       BEFORE INSERT ON message_tombstones
       FOR EACH ROW EXECUTE FUNCTION fail_tombstone_insert()`,
    );
    await expect(retainThrough(pool, teamId, 1n)).rejects.toThrow(
      /injected retention failure/,
    );
    const rolledBack = await pool.query<{
      messages: string;
      tombstones: string;
      floor: string;
    }>(
      `SELECT
         (SELECT count(*)::text FROM messages WHERE team_id = $1) AS messages,
         (SELECT count(*)::text FROM message_tombstones WHERE team_id = $1) AS tombstones,
         (SELECT min_available_seq::text FROM teams WHERE team_id = $1) AS floor`,
      [teamId],
    );
    expect(rolledBack.rows[0]).toEqual({ messages: "4", tombstones: "0", floor: "0" });
    await pool.query("DROP TRIGGER fail_tombstone_insert ON message_tombstones");
    await pool.query("DROP FUNCTION fail_tombstone_insert()");

    const concurrent = message("750e8400-e29b-41d4-a716-446655440007", "after-floor");
    const [retained, posted] = await Promise.all([
      retainThrough(pool, teamId, 4n),
      app.inject({
        method: "POST",
        url: "/v1/messages",
        headers,
        payload: { messages: [concurrent] },
      }),
    ]);
    expect(retained).toMatchObject({
      min_available_seq: "4",
      retained_through: "4",
      tombstones_created: "4",
    });
    expect(posted.statusCode).toBe(200);
    expect(posted.json().acks[0].server_seq).toBe("5");

    const belowFloor = await app.inject({
      method: "GET",
      url: "/v1/messages?after=0",
      headers,
    });
    expect(belowFloor.statusCode).toBe(410);
    expect(belowFloor.json().error.code).toBe("resync-required");

    const replay = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: {
        messages: [message("550e8400-e29b-41d4-a716-446655440000", "first")],
      },
    });
    expect(replay.json().acks[0]).toMatchObject({
      server_seq: "1",
      disposition: "duplicate",
    });

    await pool.query(
      "UPDATE teams SET write_allowed_ciphers = ARRAY[]::TEXT[] WHERE team_id = $1",
      [teamId],
    );
    const duplicateUnderNewPolicy = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: {
        messages: [message("550e8400-e29b-41d4-a716-446655440000", "first")],
      },
    });
    expect(duplicateUnderNewPolicy.statusCode).toBe(200);
    expect(duplicateUnderNewPolicy.json().acks[0].disposition).toBe("duplicate");
    const rejectedFresh = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: { messages: [message("750e8400-e29b-41d4-a716-446655440008", "fresh")] },
    });
    expect(rejectedFresh.statusCode).toBe(403);
    await pool.query(
      "UPDATE teams SET write_allowed_ciphers = ARRAY['none']::TEXT[] WHERE team_id = $1",
      [teamId],
    );

    const invalidVersion = message(
      "550e8400-e29b-41d4-a716-446655440000",
      "first",
    );
    invalidVersion.envelope.v = 0x1_0000_0000;
    const outOfRange = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: { messages: [invalidVersion] },
    });
    expect(outOfRange.statusCode).toBe(400);
    expect(outOfRange.json().error.code).toBe("invalid-request");
  });

  it("atomically provisions the operator roster and permanently retires IDs", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agmsg-provision-test-"));
    const manifestPath = join(directory, "team.json");
    const provisionTeam = "018f3f7e-0000-7000-8000-000000000101";
    const provisionMember = "018f3f7e-0000-7000-8000-000000000110";
    const provisionRegistration = "018f3f7e-0000-7000-8000-000000000111";
    const connection = new URL(databaseUrl ?? "");
    connection.searchParams.set("options", `-c search_path=${schema}`);
    const environment = {
      ...process.env,
      DATABASE_URL: connection.toString(),
      AGMSG_SERVER_TOKEN: token,
    };
    const runProvision = () =>
      execFileAsync(
        process.execPath,
        ["node_modules/tsx/dist/cli.mjs", "src/provision.ts", manifestPath],
        { cwd: process.cwd(), env: environment },
      );

    try {
      const member = {
        member_id: provisionMember,
        name: "provisioned-worker",
        registrations: [
          {
            registration_id: provisionRegistration,
            installation_id: "018f3f7e-0000-7000-8000-000000000112",
            type: "codex",
          },
        ],
      };
      await writeFile(
        manifestPath,
        JSON.stringify({
          team_id: provisionTeam,
          team_name: "provisioned-team",
          members: [member],
        }),
      );
      const first = await runProvision();
      expect(JSON.parse(first.stdout)).toMatchObject({ members_revision: "0" });

      await writeFile(
        manifestPath,
        JSON.stringify({
          team_id: provisionTeam,
          team_name: "provisioned-team",
          members: [],
        }),
      );
      const second = await runProvision();
      expect(JSON.parse(second.stdout)).toMatchObject({ members_revision: "1" });

      await writeFile(
        manifestPath,
        JSON.stringify({
          team_id: provisionTeam,
          team_name: "provisioned-team",
          members: [member],
        }),
      );
      await expect(runProvision()).rejects.toThrow(/retired/);
    } finally {
      if (!directory.startsWith(join(tmpdir(), "agmsg-provision-test-"))) {
        throw new Error("refusing to remove an unexpected temporary directory");
      }
      await rm(directory, { recursive: true });
    }
  });

  it("rejects duplicate JSON keys and rolls back a sequence-crossing batch", async () => {
    const duplicateKeys = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers: { ...headers, "content-type": "application/json" },
      payload: '{"messages":[],"messages":[]}',
    });
    expect(duplicateKeys.statusCode).toBe(400);

    await pool.query(
      "UPDATE teams SET current_seq = 9223372036854775806 WHERE team_id = $1",
      [teamId],
    );
    const exhausted = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: {
        messages: [
          message("750e8400-e29b-41d4-a716-446655440003", "a"),
          message("750e8400-e29b-41d4-a716-446655440004", "b"),
        ],
      },
    });
    expect(exhausted.statusCode).toBe(507);
    expect(exhausted.json().error.code).toBe("sequence-exhausted");
    const rows = await pool.query<{ count: string }>(
      "SELECT count(*)::text AS count FROM messages WHERE id = ANY($1::uuid[])",
      [["750e8400-e29b-41d4-a716-446655440003", "750e8400-e29b-41d4-a716-446655440004"]],
    );
    expect(rows.rows[0]?.count).toBe("0");
  });
});
