import type { Pool, PoolClient } from "pg";
import { ProtocolError } from "./errors.js";
import {
  MAX_SEQUENCE,
  envelopeDigest,
  type Envelope,
  type MessageInput,
} from "./protocol.js";
import { inTransaction } from "./db.js";

type TeamRow = {
  team_id: string;
  team_name: string;
  current_seq: string;
  min_available_seq: string;
  policy_revision: string;
  accepted_envelope_versions: number[];
  write_allowed_ciphers: string[];
  max_blob_bytes: number;
  members_revision: string;
};

type LiveMessageRow = {
  id: string;
  team_seq: string;
  server_received_at: string;
  envelope_v: number;
  cipher: string;
  key_id: string | null;
  blob: string;
  envelope_digest: Buffer;
};

type ExistingRecord =
  | { kind: "live"; row: LiveMessageRow }
  | { kind: "tombstone"; sequence: string; digest: Buffer };

const timestampSql = `to_char(server_received_at AT TIME ZONE 'UTC',
  'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`;

async function serverInstanceId(client: PoolClient): Promise<string> {
  const result = await client.query<{ server_instance_id: string }>(
    "SELECT server_instance_id::text FROM server_metadata WHERE singleton = TRUE",
  );
  const id = result.rows[0]?.server_instance_id;
  if (!id) throw new Error("server metadata is not initialized");
  return id;
}

async function teamRow(
  client: PoolClient,
  id: string,
  lock = false,
): Promise<TeamRow | undefined> {
  const result = await client.query<TeamRow>(
    `SELECT team_id::text, team_name, current_seq::text, min_available_seq::text,
            policy_revision::text, accepted_envelope_versions,
            write_allowed_ciphers, max_blob_bytes, members_revision::text
       FROM teams WHERE team_id = $1${lock ? " FOR UPDATE" : ""}`,
    [id],
  );
  return result.rows[0];
}

function common(serverId: string, team: TeamRow): Record<string, unknown> {
  return {
    protocol_version: 1,
    server_instance_id: serverId,
    team_id: team.team_id,
    team_name: team.team_name,
    min_available_seq: team.min_available_seq,
  };
}

function notFound(serverId: string, teamId: string): ProtocolError {
  return new ProtocolError(404, "team-not-found", "team is not provisioned", {}, {
    serverInstanceId: serverId,
    teamId,
  });
}

function envelopeMatches(row: LiveMessageRow, envelope: Envelope): boolean {
  return (
    row.envelope_v === envelope.v &&
    row.cipher === envelope.cipher &&
    row.key_id === envelope.key_id &&
    row.blob === envelope.blob
  );
}

function inputFingerprint(message: MessageInput): string {
  return JSON.stringify([
    message.envelope.v,
    message.envelope.cipher,
    message.envelope.key_id,
    message.envelope.blob,
  ]);
}

export async function postMessages(
  pool: Pool,
  teamId: string,
  messages: MessageInput[],
): Promise<Record<string, unknown>> {
  return inTransaction(pool, async (client) => {
    const serverId = await serverInstanceId(client);
    const team = await teamRow(client, teamId, true);
    if (!team) throw notFound(serverId, teamId);
    const binding = { serverInstanceId: serverId, teamId };

    const firstById = new Map<string, MessageInput>();
    for (const message of messages) {
      const first = firstById.get(message.id);
      if (first && inputFingerprint(first) !== inputFingerprint(message)) {
        throw new ProtocolError(
          409,
          "message-uuid-conflict",
          "message id is repeated with a different payload",
          { id: message.id },
          binding,
        );
      }
      firstById.set(message.id, first ?? message);
    }

    const ids = [...firstById.keys()];
    const liveResult = await client.query<LiveMessageRow>(
      `SELECT id::text, team_seq::text, ${timestampSql} AS server_received_at,
              envelope_v, cipher, key_id, blob, envelope_digest
         FROM messages WHERE team_id = $1 AND id = ANY($2::uuid[])`,
      [teamId, ids],
    );
    const tombstoneResult = await client.query<{
      id: string;
      original_team_seq: string;
      envelope_digest: Buffer;
    }>(
      `SELECT id::text, original_team_seq::text, envelope_digest
         FROM message_tombstones WHERE team_id = $1 AND id = ANY($2::uuid[])`,
      [teamId, ids],
    );
    const existing = new Map<string, ExistingRecord>();
    for (const row of liveResult.rows) existing.set(row.id, { kind: "live", row });
    for (const row of tombstoneResult.rows) {
      existing.set(row.id, {
        kind: "tombstone",
        sequence: row.original_team_seq,
        digest: row.envelope_digest,
      });
    }

    for (const [id, message] of firstById) {
      const record = existing.get(id);
      if (!record) continue;
      const matches =
        record.kind === "live"
          ? envelopeMatches(record.row, message.envelope)
          : record.digest.equals(envelopeDigest(message.envelope));
      if (!matches) {
        throw new ProtocolError(
          409,
          "message-uuid-conflict",
          "message id already exists with a different payload",
          { id },
          binding,
        );
      }
    }

    const fresh = [...firstById.values()].filter((message) => !existing.has(message.id));
    for (const message of fresh) {
      const { envelope, id } = message;
      if (envelope.v !== 1 || envelope.cipher !== "none") {
        throw new ProtocolError(
          422,
          "unsupported-cipher",
          "envelope version or cipher is not supported",
          {
            id,
            v: envelope.v,
            cipher: envelope.cipher,
            accepted_envelope_versions: team.accepted_envelope_versions,
            write_allowed_ciphers: team.write_allowed_ciphers,
            policy_revision: team.policy_revision,
          },
          binding,
        );
      }
      if (
        !team.accepted_envelope_versions.includes(envelope.v) ||
        !team.write_allowed_ciphers.includes(envelope.cipher)
      ) {
        throw new ProtocolError(
          403,
          "cipher-policy-violation",
          "cipher is not currently write-allowed",
          {
            id,
            v: envelope.v,
            cipher: envelope.cipher,
            write_allowed_ciphers: team.write_allowed_ciphers,
            policy_revision: team.policy_revision,
          },
          binding,
        );
      }
      if (Buffer.from(envelope.blob, "base64").length > team.max_blob_bytes) {
        throw new ProtocolError(
          413,
          "request-too-large",
          "message blob exceeds the team capability limit",
          { id, max_blob_bytes: String(team.max_blob_bytes) },
          binding,
        );
      }
    }

    let next = BigInt(team.current_seq);
    if (BigInt(fresh.length) > MAX_SEQUENCE - next) {
      throw new ProtocolError(
        507,
        "sequence-exhausted",
        "team sequence is exhausted",
        {},
        binding,
      );
    }

    const inserted = new Map<string, LiveMessageRow>();
    for (const message of fresh) {
      next += 1n;
      const digest = envelopeDigest(message.envelope);
      const result = await client.query<LiveMessageRow>(
        `INSERT INTO messages
           (team_id, id, team_seq, envelope_v, cipher, key_id, blob, envelope_digest)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
         RETURNING id::text, team_seq::text, ${timestampSql} AS server_received_at,
                   envelope_v, cipher, key_id, blob, envelope_digest`,
        [
          teamId,
          message.id,
          next.toString(),
          message.envelope.v,
          message.envelope.cipher,
          message.envelope.key_id,
          message.envelope.blob,
          digest,
        ],
      );
      const row = result.rows[0];
      if (!row) throw new Error("insert did not return a message");
      inserted.set(message.id, row);
      existing.set(message.id, { kind: "live", row });
    }
    if (fresh.length > 0) {
      await client.query("UPDATE teams SET current_seq = $2 WHERE team_id = $1", [
        teamId,
        next.toString(),
      ]);
    }

    const seen = new Set<string>();
    const acks = messages.map((message) => {
      const record = existing.get(message.id);
      if (!record) throw new Error("missing canonical ack record");
      const stored = inserted.has(message.id) && !seen.has(message.id);
      seen.add(message.id);
      return {
        id: message.id,
        server_seq: record.kind === "live" ? record.row.team_seq : record.sequence,
        disposition: stored ? "stored" : "duplicate",
      };
    });

    return {
      ...common(serverId, { ...team, current_seq: next.toString() }),
      policy_revision: team.policy_revision,
      acks,
    };
  });
}

export async function retainThrough(
  pool: Pool,
  teamId: string,
  through: bigint,
): Promise<Record<string, unknown>> {
  return inTransaction(pool, async (client) => {
    const serverId = await serverInstanceId(client);
    const team = await teamRow(client, teamId, true);
    if (!team) throw notFound(serverId, teamId);
    const currentFloor = BigInt(team.min_available_seq);
    const currentSequence = BigInt(team.current_seq);
    if (through < currentFloor || through > currentSequence) {
      throw new ProtocolError(
        400,
        "invalid-request",
        "retention floor must be between the current floor and current sequence",
        {
          through: through.toString(),
          min_available_seq: team.min_available_seq,
          current_seq: team.current_seq,
        },
        { serverInstanceId: serverId, teamId },
      );
    }

    const tombstones = await client.query(
      `INSERT INTO message_tombstones
         (team_id, id, original_team_seq, envelope_digest)
       SELECT team_id, id, team_seq, envelope_digest
         FROM messages
        WHERE team_id = $1 AND team_seq <= $2
       RETURNING id`,
      [teamId, through.toString()],
    );
    const deleted = await client.query(
      "DELETE FROM messages WHERE team_id = $1 AND team_seq <= $2",
      [teamId, through.toString()],
    );
    if (deleted.rowCount !== tombstones.rowCount) {
      throw new Error("retention tombstone and deletion counts differ");
    }
    await client.query(
      "UPDATE teams SET min_available_seq = $2 WHERE team_id = $1",
      [teamId, through.toString()],
    );
    return {
      ...common(serverId, { ...team, min_available_seq: through.toString() }),
      retained_through: through.toString(),
      tombstones_created: String(tombstones.rowCount ?? 0),
    };
  });
}

export async function getMessages(
  pool: Pool,
  teamId: string,
  after: bigint,
  limit: number,
): Promise<Record<string, unknown>> {
  return inTransaction(
    pool,
    async (client) => {
      const serverId = await serverInstanceId(client);
      const team = await teamRow(client, teamId);
      if (!team) throw notFound(serverId, teamId);
      if (after < BigInt(team.min_available_seq)) {
        throw new ProtocolError(
          410,
          "resync-required",
          "cursor predates retained history",
          { after: after.toString(), min_available_seq: team.min_available_seq },
          { serverInstanceId: serverId, teamId },
        );
      }
      const result = await client.query<LiveMessageRow>(
        `SELECT id::text, team_seq::text, ${timestampSql} AS server_received_at,
                envelope_v, cipher, key_id, blob, envelope_digest
           FROM messages
          WHERE team_id = $1 AND team_seq > $2
          ORDER BY team_seq ASC
          LIMIT $3`,
        [teamId, after.toString(), limit + 1],
      );
      const hasMore = result.rows.length > limit;
      const page = result.rows.slice(0, limit);
      return {
        ...common(serverId, team),
        messages: page.map((row) => ({
          server_seq: row.team_seq,
          id: row.id,
          server_received_at: row.server_received_at,
          envelope: {
            v: row.envelope_v,
            cipher: row.cipher,
            key_id: row.key_id,
            blob: row.blob,
          },
        })),
        next_after: page.at(-1)?.team_seq ?? after.toString(),
        has_more: hasMore,
      };
    },
    { readOnly: true, repeatableRead: true },
  );
}

export async function getCapabilities(
  pool: Pool,
  teamId: string,
): Promise<Record<string, unknown>> {
  return inTransaction(
    pool,
    async (client) => {
      const serverId = await serverInstanceId(client);
      const team = await teamRow(client, teamId);
      if (!team) throw notFound(serverId, teamId);
      const historyResult = await client.query<{
        policy_revision: string;
        effective_from_seq: string;
        accepted_envelope_versions: number[];
        write_allowed_ciphers: string[];
      }>(
        `SELECT policy_revision::text, effective_from_seq::text,
                accepted_envelope_versions, write_allowed_ciphers
           FROM (
             SELECT DISTINCT ON (effective_from_seq)
                    policy_revision, effective_from_seq,
                    accepted_envelope_versions, write_allowed_ciphers
               FROM team_policy_history
              WHERE team_id = $1
              ORDER BY effective_from_seq, policy_revision DESC
           ) effective
          ORDER BY effective_from_seq, policy_revision`,
        [teamId],
      );
      if (historyResult.rows.length > 4096) {
        throw new Error("team policy history exceeds protocol limit");
      }
      const current = BigInt(team.current_seq);
      return {
        ...common(serverId, team),
        current_seq: team.current_seq,
        next_sequence_boundary:
          current === MAX_SEQUENCE ? null : (current + 1n).toString(),
        accepted_envelope_versions: team.accepted_envelope_versions,
        write_allowed_ciphers: team.write_allowed_ciphers,
        policy_revision: team.policy_revision,
        effective_from_seq:
          historyResult.rows.at(-1)?.effective_from_seq ?? "1",
        max_blob_bytes: String(team.max_blob_bytes),
        policy_history: historyResult.rows,
      };
    },
    { readOnly: true, repeatableRead: true },
  );
}

export async function getMembers(
  pool: Pool,
  teamId: string,
): Promise<Record<string, unknown>> {
  return inTransaction(
    pool,
    async (client) => {
      const serverId = await serverInstanceId(client);
      const team = await teamRow(client, teamId);
      if (!team) throw notFound(serverId, teamId);
      const members = await client.query<{ member_id: string; name: string }>(
        `SELECT member_id::text, name FROM members
          WHERE team_id = $1 ORDER BY member_id`,
        [teamId],
      );
      const registrations = await client.query<{
        registration_id: string;
        member_id: string;
        installation_id: string;
        type: string;
      }>(
        `SELECT registration_id::text, member_id::text, installation_id::text, type
           FROM registrations WHERE team_id = $1
          ORDER BY registration_id`,
        [teamId],
      );
      return {
        ...common(serverId, team),
        members_revision: team.members_revision,
        members: members.rows.map((member) => ({
          member_id: member.member_id,
          name: member.name,
          registrations: registrations.rows
            .filter((registration) => registration.member_id === member.member_id)
            .map(({ member_id: _memberId, ...registration }) => registration),
        })),
      };
    },
    { readOnly: true, repeatableRead: true },
  );
}

export async function health(pool: Pool): Promise<{
  status: "ok";
  server_instance_id: string;
  protocol: { supported_versions: number[] };
  database: "ok";
}> {
  const client = await pool.connect();
  try {
    return {
      status: "ok",
      server_instance_id: await serverInstanceId(client),
      protocol: { supported_versions: [1] },
      database: "ok",
    };
  } finally {
    client.release();
  }
}
