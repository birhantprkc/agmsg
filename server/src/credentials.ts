import { createHash, randomBytes } from "node:crypto";
import type { Pool, PoolClient } from "pg";
import { v7 as uuidv7 } from "uuid";
import { inTransaction } from "./db.js";
import { ProtocolError } from "./errors.js";
import { teamNameSchema, uuidV7Schema } from "./protocol.js";
import { capabilitySnapshot } from "./storage.js";

const PAIRING_TTL_MINUTES = 15;
const SUPPORTED_ENVELOPE_VERSIONS = [1];
const DEFAULT_WRITE_CIPHERS = ["none", "age-v1"];
const timestampSql = (column: string) => `to_char(${column} AT TIME ZONE 'UTC',
  'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`;

type PairingRow = {
  team_id: string;
  team_name: string;
  expires_at: string;
  consumed_at: string | null;
};

export type CredentialIdentity = {
  teamId: string;
  credentialId: string;
  revoked: boolean;
};

export async function credentialBinding(
  pool: Pool,
  teamId: string,
): Promise<{ serverInstanceId: string; teamId: string }> {
  const result = await pool.query<{ server_instance_id: string }>(
    `SELECT m.server_instance_id::text
       FROM server_metadata m
       JOIN teams t ON t.team_id = $1
      WHERE m.singleton = TRUE`,
    [teamId],
  );
  const serverId = result.rows[0]?.server_instance_id;
  if (!serverId) throw new Error("credential binding is not initialized");
  return { serverInstanceId: serverId, teamId };
}

function opaqueValue(prefix: string): string {
  return `${prefix}${randomBytes(32).toString("base64url")}`;
}

function digest(kind: "pairing" | "credential", value: string): Buffer {
  return createHash("sha256")
    .update(`agmsg-${kind}-v1\0`, "ascii")
    .update(value, "utf8")
    .digest();
}

async function serverInstanceId(client: PoolClient): Promise<string> {
  const result = await client.query<{ server_instance_id: string }>(
    "SELECT server_instance_id::text FROM server_metadata WHERE singleton = TRUE",
  );
  const value = result.rows[0]?.server_instance_id;
  if (!value) throw new Error("server metadata is not initialized");
  return value;
}

export async function resolveTeamId(pool: Pool, selector: string): Promise<string> {
  const parsedId = uuidV7Schema.safeParse(selector);
  const result = parsedId.success
    ? await pool.query<{ team_id: string }>(
        "SELECT team_id::text FROM teams WHERE team_id = $1",
        [parsedId.data],
      )
    : await pool.query<{ team_id: string }>(
        "SELECT team_id::text FROM teams WHERE team_name = $1 ORDER BY team_id",
        [teamNameSchema.parse(selector)],
      );
  if (result.rows.length === 0) throw new Error(`team ${selector} is not provisioned`);
  if (result.rows.length > 1) {
    throw new Error(`team name ${selector} is ambiguous; use its team ID`);
  }
  const id = result.rows[0]?.team_id;
  if (!id) throw new Error("team lookup returned no ID");
  return id;
}

export async function createTeam(
  pool: Pool,
  name: string,
  requestedId?: string,
): Promise<{ team_id: string; team_name: string }> {
  const teamName = teamNameSchema.parse(name);
  const teamId = requestedId ? uuidV7Schema.parse(requestedId) : uuidv7();
  return inTransaction(pool, async (client) => {
    // Display names are intentionally not database identities, but the admin UX
    // rejects duplicates. Serialize that check without imposing a schema-level
    // uniqueness rule on deployments which provision names independently.
    await client.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [teamName]);
    const duplicate = await client.query(
      "SELECT 1 FROM teams WHERE team_name = $1 LIMIT 1",
      [teamName],
    );
    if (duplicate.rows[0]) throw new Error(`team name ${teamName} already exists`);
    await client.query(
      `INSERT INTO teams
         (team_id, team_name, accepted_envelope_versions, write_allowed_ciphers)
       VALUES ($1, $2, $3, $4)`,
      [teamId, teamName, SUPPORTED_ENVELOPE_VERSIONS, DEFAULT_WRITE_CIPHERS],
    );
    await client.query(
      `INSERT INTO team_policy_history
         (team_id, policy_revision, effective_from_seq,
          accepted_envelope_versions, write_allowed_ciphers)
       VALUES ($1, 0, 1, $2, $3)`,
      [teamId, SUPPORTED_ENVELOPE_VERSIONS, DEFAULT_WRITE_CIPHERS],
    );
    return { team_id: teamId, team_name: teamName };
  });
}

export async function issuePairingToken(
  pool: Pool,
  teamId: string,
): Promise<{ token: string; team_id: string; expires_at: string }> {
  const token = opaqueValue("agmsg_pair_");
  return inTransaction(pool, async (client) => {
    const team = await client.query("SELECT 1 FROM teams WHERE team_id = $1 FOR UPDATE", [teamId]);
    if (!team.rows[0]) throw new Error(`team ${teamId} is not provisioned`);
    const inserted = await client.query<{ expires_at: string }>(
      `INSERT INTO pairing_tokens (token_digest, team_id, expires_at)
       VALUES ($1, $2, clock_timestamp() + make_interval(mins => $3))
       RETURNING ${timestampSql("expires_at")} AS expires_at`,
      [digest("pairing", token), teamId, PAIRING_TTL_MINUTES],
    );
    const expiresAt = inserted.rows[0]?.expires_at;
    if (!expiresAt) throw new Error("pairing token expiry was not returned");
    return { token, team_id: teamId, expires_at: expiresAt };
  });
}

export async function exchangePairingToken(
  pool: Pool,
  token: string,
): Promise<Record<string, unknown>> {
  const credential = opaqueValue("agmsg_credential_");
  const credentialId = uuidv7();
  return inTransaction(pool, async (client) => {
    const serverId = await serverInstanceId(client);
    const tokenResult = await client.query<PairingRow>(
      `SELECT p.team_id::text, t.team_name,
              ${timestampSql("p.expires_at")} AS expires_at,
              ${timestampSql("p.consumed_at")} AS consumed_at
         FROM pairing_tokens p
         JOIN teams t ON t.team_id = p.team_id
        WHERE p.token_digest = $1
        FOR UPDATE OF p`,
      [digest("pairing", token)],
    );
    const pairing = tokenResult.rows[0];
    if (!pairing) {
      throw new ProtocolError(401, "invalid-pairing-token", "pairing token is invalid");
    }
    const binding = { serverInstanceId: serverId, teamId: pairing.team_id };
    if (pairing.consumed_at) {
      throw new ProtocolError(
        409,
        "pairing-token-consumed",
        "pairing token has already been consumed",
        {},
        binding,
      );
    }
    const live = await client.query<{ live: boolean }>(
      "SELECT expires_at > clock_timestamp() AS live FROM pairing_tokens WHERE token_digest = $1",
      [digest("pairing", token)],
    );
    if (!live.rows[0]?.live) {
      throw new ProtocolError(
        410,
        "pairing-token-expired",
        "pairing token has expired",
        { expired_at: pairing.expires_at },
        binding,
      );
    }
    await client.query(
      `INSERT INTO credentials (team_id, credential_id, secret_digest)
       VALUES ($1, $2, $3)`,
      [pairing.team_id, credentialId, digest("credential", credential)],
    );
    await client.query(
      `UPDATE pairing_tokens
          SET consumed_at = clock_timestamp(), credential_id = $2
        WHERE token_digest = $1`,
      [digest("pairing", token), credentialId],
    );
    // The team-row lock is the same serialization point used by policy writes.
    // It makes the nested document one canonical snapshot even though this is
    // a read/write exchange transaction rather than the read-only GET path.
    const capabilities = await capabilitySnapshot(client, pairing.team_id, true);
    return {
      credential_id: credentialId,
      credential,
      protocol_version: 1,
      server_instance_id: serverId,
      remote_team_id: capabilities.team_id,
      remote_team_name: capabilities.team_name,
      capabilities,
    };
  });
}

export async function authenticateCredential(
  pool: Pool,
  teamId: string,
  secret: string,
  includeRevoked = false,
): Promise<CredentialIdentity | undefined> {
  const result = await pool.query<{
    credential_id: string;
    revoked: boolean;
  }>(
    `UPDATE credentials
        SET last_active_at = CASE WHEN revoked_at IS NULL THEN clock_timestamp()
                                  ELSE last_active_at END
      WHERE team_id = $1 AND secret_digest = $2
        AND ($3::boolean OR revoked_at IS NULL)
      RETURNING credential_id::text, revoked_at IS NOT NULL AS revoked`,
    [teamId, digest("credential", secret), includeRevoked],
  );
  const row = result.rows[0];
  return row
    ? { teamId, credentialId: row.credential_id, revoked: row.revoked }
    : undefined;
}

export async function revokeCredential(
  pool: Pool,
  teamId: string,
  credentialId: string,
): Promise<Record<string, unknown>> {
  uuidV7Schema.parse(credentialId);
  return inTransaction(pool, async (client) => {
    const serverId = await serverInstanceId(client);
    const result = await client.query<{
      credential_id: string;
      revoked_at: string;
    }>(
      `UPDATE credentials
          SET revoked_at = COALESCE(revoked_at, clock_timestamp())
        WHERE team_id = $1 AND credential_id = $2
        RETURNING credential_id::text,
                  ${timestampSql("revoked_at")} AS revoked_at`,
      [teamId, credentialId],
    );
    const row = result.rows[0];
    if (!row) {
      throw new ProtocolError(
        404,
        "credential-not-found",
        "credential is not provisioned for this team",
        { credential_id: credentialId },
        { serverInstanceId: serverId, teamId },
      );
    }
    return {
      protocol_version: 1,
      server_instance_id: serverId,
      team_id: teamId,
      credential_id: row.credential_id,
      revoked: true,
      revoked_at: row.revoked_at,
    };
  });
}

export async function listCredentials(
  pool: Pool,
  teamId: string,
): Promise<Array<Record<string, unknown>>> {
  const result = await pool.query<{
    credential_id: string;
    connected_at: string;
    last_active_at: string | null;
    revoked_at: string | null;
  }>(
    `SELECT credential_id::text,
            ${timestampSql("created_at")} AS connected_at,
            ${timestampSql("last_active_at")} AS last_active_at,
            ${timestampSql("revoked_at")} AS revoked_at
       FROM credentials
      WHERE team_id = $1
      ORDER BY created_at, credential_id`,
    [teamId],
  );
  return result.rows.map((row) => ({
    team_id: teamId,
    ...row,
    status: row.revoked_at ? "revoked" : "active",
  }));
}
