import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { evaluatePull } from "../scripts/internal/remote-sync.mjs";
import { openEnvelope, sealEnvelope } from "../scripts/internal/sync-cipher.mjs";

const manifest = JSON.parse(await readFile(
  new URL("../docs/spec/vectors/age-v1-vectors.json", import.meta.url), "utf8"));
const byName = new Map(manifest.vectors.map((vector) => [vector.name, vector]));

function resolveEnvelope(vector) {
  const source = vector.envelope_from ? byName.get(vector.envelope_from) : vector;
  return { ...source.envelope, ...(vector.envelope_override || {}) };
}

function capabilities(config, cipher) {
  return {
    protocol_version: 1,
    server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id,
    min_available_seq: "0",
    current_seq: "1",
    next_sequence_boundary: "2",
    accepted_envelope_versions: [1],
    write_allowed_ciphers: [cipher],
    policy_revision: "0",
    effective_from_seq: "1",
    max_blob_bytes: "1048576",
    policy_history: [{ policy_revision: "0", effective_from_seq: "1",
      accepted_envelope_versions: [1], write_allowed_ciphers: [cipher] }],
  };
}

test("age-v1 shared vectors preserve every pinned quarantine state", async () => {
  const scratch = await mkdtemp(join(tmpdir(), "agmsg-age-v1-contract-"));
  try {
    const identityPaths = {};
    for (const [name, recipientSet] of Object.entries(manifest.recipient_sets)) {
      const path = join(scratch, `${name}.identity`);
      await writeFile(path, `${recipientSet.identity}\n`, { mode: 0o600 });
      identityPaths[name] = path;
    }
    for (const vector of manifest.vectors) {
      const envelope = resolveEnvelope(vector);
      const trustedKeyId = vector.trusted_epoch_key_id || manifest.binding.key_id;
      const config = {
        local_team: "demo",
        server_instance_id: "018f3f7e-0000-7000-8000-000000000000",
        remote_team_id: vector.binding_override?.team_id || manifest.binding.team_id,
        protocol_version: vector.binding_override?.protocol_version || manifest.binding.protocol_version,
        cipher_profile: "age-v1",
        local_security_history: [{ local_security_revision: "0", effective_from_seq: "1",
          minimum_security_mode: "e2ee-required" }],
        age_v1: {
          epoch_snapshot: { history: [{ epoch_revision: "0", effective_from_seq: "1",
            cipher: "age-v1", key_id: trustedKeyId,
            recipients: [manifest.recipient_sets.team_a.recipient] }] },
          identity_files: { [trustedKeyId]: identityPaths[vector.identity] },
        },
      };
      const message = {
        server_seq: "1",
        id: vector.binding_override?.wire_id || manifest.binding.wire_id,
        server_received_at: "2026-07-20T06:30:01.000000Z",
        envelope,
      };
      const result = await evaluatePull(config, capabilities(config, envelope.cipher), message);
      assert.equal(result.status, vector.expected_state, vector.name);
      if (result.status === "importable") assert.deepEqual(result.projection, manifest.canonical_message);
      else assert.equal(result.projection, undefined, vector.name);
    }
  } finally {
    await rm(scratch, { recursive: true });
  }
});

test("none and age-v1 profiles share one seal/open registry", async () => {
  const base = {
    type: "sync_seal",
    envelope_v: 1,
    max_blob_bytes: 1_048_576,
    wire_id: manifest.binding.wire_id,
    team_id: manifest.binding.team_id,
    protocol_version: 1,
    projection: manifest.canonical_message,
  };
  const none = sealEnvelope({ ...base, cipher: "none", key_id: null, recipients: [] });
  assert.deepEqual(await openEnvelope({ envelope: none, max_blob_bytes: 1_048_576 }), manifest.canonical_message);

  const scratch = await mkdtemp(join(tmpdir(), "agmsg-age-v1-roundtrip-"));
  try {
    const identity = join(scratch, "identity");
    await writeFile(identity, `${manifest.recipient_sets.team_a.identity}\n`, { mode: 0o600 });
    const age = sealEnvelope({ ...base, cipher: "age-v1", key_id: manifest.binding.key_id,
      recipients: [manifest.recipient_sets.team_a.recipient] });
    assert.deepEqual(await openEnvelope({ envelope: age, protocol_version: 1,
      team_id: base.team_id, wire_id: base.wire_id, identity_file: identity,
      max_blob_bytes: 1_048_576 }), manifest.canonical_message);
  } finally {
    await rm(scratch, { recursive: true });
  }
});
