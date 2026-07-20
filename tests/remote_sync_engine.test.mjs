import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  ageSnapshotDigest,
  driver,
  isRetryable,
  plaintextWriteEligible,
  request,
  retainAgeCheckpoint,
  selectWriteProfile,
  validateAckMapping,
  validateAgeConfiguration,
  validateConfiguredAgeIdentities,
  validateCapabilities,
  validateErrorBinding,
} from "../scripts/internal/remote-sync.mjs";

const config = {
  local_team: "demo",
  server_instance_id: "018f3f7e-0000-7000-8000-000000000000",
  remote_team_id: "018f3f7e-0000-7000-8000-000000000001",
  protocol_version: 1,
  local_security_history: [{
    local_security_revision: "0", effective_from_seq: "1",
    minimum_security_mode: "plaintext-allowed",
  }],
};

const candidates = [
  { local_position: "1", id: "550e8400-e29b-41d4-a716-446655440001" },
  { local_position: "2", id: "550e8400-e29b-41d4-a716-446655440002" },
];

test("ack mapping rejects reversed and duplicate server sequences", () => {
  assert.throws(() => validateAckMapping(candidates, [
    { id: candidates[0].id, server_seq: "2", disposition: "stored" },
    { id: candidates[1].id, server_seq: "1", disposition: "stored" },
  ]), /strictly increasing/u);
  assert.throws(() => validateAckMapping(candidates, [
    { id: candidates[0].id, server_seq: "1", disposition: "stored" },
    { id: candidates[1].id, server_seq: "1", disposition: "stored" },
  ]), /strictly increasing/u);
  assert.throws(() => validateAckMapping(candidates, [
    { id: candidates[0].id, server_seq: "1", disposition: "stored", extra: true },
    { id: candidates[1].id, server_seq: "2", disposition: "stored" },
  ]), /shape/u);
});

test("resolved protocol errors enforce the immutable binding", () => {
  for (const status of [403, 410]) {
    assert.throws(() => validateErrorBinding(config, status, {
      protocol_version: 1,
      server_instance_id: "018f3f7e-0000-7000-8000-000000000099",
      team_id: config.remote_team_id,
      error: { code: status === 410 ? "resync-required" : "cipher-policy-violation" },
    }), /binding mismatch/u);
  }
  assert.doesNotThrow(() => validateErrorBinding(config, 401, {
    protocol_version: 1, error: { code: "unauthenticated" },
  }));
});

test("run retry classification excludes permanent HTTP and validation failures", () => {
  assert.equal(isRetryable({ retryable: true }), true);
  for (const status of [408, 429, 500, 502, 503, 504]) assert.equal(isRetryable({ status }), true);
  for (const status of [400, 401, 403, 404, 409, 410, 422, 426]) assert.equal(isRetryable({ status }), false);
  assert.equal(isRetryable(new Error("binding mismatch")), false);
});

test("headerless non-JSON intermediary failures remain retryable", async () => {
  const previousFetch = globalThis.fetch;
  const previousToken = process.env.AGMSG_SYNC_TOKEN;
  process.env.AGMSG_SYNC_TOKEN = "fixture-token";
  try {
    for (const status of [502, 503, 504]) {
      globalThis.fetch = async () => new Response("temporary proxy failure", { status });
      await assert.rejects(request({ ...config, server_url: "https://sync.example" }, "/v1/messages"),
        (error) => error.status === status && error.retryable === true);
    }
  } finally {
    globalThis.fetch = previousFetch;
    if (previousToken === undefined) delete process.env.AGMSG_SYNC_TOKEN;
    else process.env.AGMSG_SYNC_TOKEN = previousToken;
  }
});

test("request distinguishes config errors from response transport loss", async () => {
  const previousFetch = globalThis.fetch;
  const previousToken = process.env.AGMSG_SYNC_TOKEN;
  process.env.AGMSG_SYNC_TOKEN = "fixture-token";
  let fetchCalled = false;
  try {
    globalThis.fetch = async () => { fetchCalled = true; throw new Error("unexpected fetch"); };
    await assert.rejects(request({ ...config, server_url: "not a URL" }, "/v1/messages"),
      (error) => error.retryable !== true);
    assert.equal(fetchCalled, false);

    globalThis.fetch = async () => ({
      ok: true, status: 200,
      headers: { get: () => "1" },
      text: async () => { throw new Error("body stream reset"); },
    });
    await assert.rejects(request({ ...config, server_url: "https://sync.example" }, "/v1/messages"),
      (error) => error.retryable === true);
  } finally {
    globalThis.fetch = previousFetch;
    if (previousToken === undefined) delete process.env.AGMSG_SYNC_TOKEN;
    else process.env.AGMSG_SYNC_TOKEN = previousToken;
  }
});

test("write-ineligible capabilities still validate for pull", () => {
  const base = {
    protocol_version: 1,
    server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id,
    min_available_seq: "0",
    current_seq: "4",
    next_sequence_boundary: "5",
    accepted_envelope_versions: [1],
    write_allowed_ciphers: ["future-aead"],
    policy_revision: "1",
    effective_from_seq: "1",
    max_blob_bytes: "1048576",
    policy_history: [{
      policy_revision: "1", effective_from_seq: "1",
      accepted_envelope_versions: [1], write_allowed_ciphers: ["future-aead"],
    }],
  };
  assert.equal(plaintextWriteEligible(config, base), false);
  assert.equal(plaintextWriteEligible(config, {
    ...base,
    current_seq: "9223372036854775807",
    next_sequence_boundary: null,
  }), false);
});

test("capability policy history must be canonical and match current policy", () => {
  const base = {
    protocol_version: 1,
    server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id,
    min_available_seq: "0", current_seq: "4", next_sequence_boundary: "5",
    accepted_envelope_versions: [1], write_allowed_ciphers: ["future-aead"],
    policy_revision: "2", effective_from_seq: "3", max_blob_bytes: "1048576",
    policy_history: [
      { policy_revision: "0", effective_from_seq: "1",
        accepted_envelope_versions: [1], write_allowed_ciphers: ["none"] },
      { policy_revision: "2", effective_from_seq: "3",
        accepted_envelope_versions: [1], write_allowed_ciphers: ["future-aead"] },
    ],
  };
  assert.doesNotThrow(() => validateCapabilities(config, base));
  assert.throws(() => validateCapabilities(config, {
    ...base, write_allowed_ciphers: ["none"],
  }), /does not match/u);
  assert.throws(() => validateCapabilities(config, {
    ...base,
    policy_history: [...base.policy_history,
      { policy_revision: "3", effective_from_seq: "3",
        accepted_envelope_versions: [1], write_allowed_ciphers: ["future-aead"] }],
    policy_revision: "3",
  }), /canonical ascending/u);
  assert.throws(() => validateCapabilities(config, {
    ...base,
    policy_history: [base.policy_history[1], base.policy_history[0]],
  }), /canonical ascending|begin at sequence 1/u);
});

test("storage driver subprocess cannot observe HTTP or age identity secrets", async () => {
  const root = await mkdtemp(join(tmpdir(), "agmsg-sync-driver-env-"));
  const mock = join(root, "driver.sh");
  await writeFile(mock, `#!/usr/bin/env bash
[ -z "\${AGMSG_SYNC_TOKEN:-}" ] || exit 99
[ -z "\${AGMSG_SYNC_TRUST_DIR:-}" ] || exit 95
[ -z "\${AGMSG_AGE_IDENTITY:-}" ] || exit 98
[ -z "\${AGMSG_AGE_IDENTITY_FILE:-}" ] || exit 97
[ -z "\${AGMSG_SYNC_AGE_IDENTITY_EPOCH_1:-}" ] || exit 96
printf '{"type":"mock-ok"}\\n'
`, { mode: 0o700 });
  const previousDriver = process.env.AGMSG_SYNC_DRIVER;
  const previousToken = process.env.AGMSG_SYNC_TOKEN;
  const previousIdentity = process.env.AGMSG_AGE_IDENTITY;
  const previousIdentityFile = process.env.AGMSG_AGE_IDENTITY_FILE;
  const previousSyncIdentity = process.env.AGMSG_SYNC_AGE_IDENTITY_EPOCH_1;
  const previousTrust = process.env.AGMSG_SYNC_TRUST_DIR;
  process.env.AGMSG_SYNC_DRIVER = mock;
  process.env.AGMSG_SYNC_TOKEN = "must-not-cross-driver-boundary";
  process.env.AGMSG_AGE_IDENTITY = "AGE-SECRET-KEY-1FIXTURE";
  process.env.AGMSG_AGE_IDENTITY_FILE = "/secret/identity";
  process.env.AGMSG_SYNC_AGE_IDENTITY_EPOCH_1 = "/secret/identity";
  process.env.AGMSG_SYNC_TRUST_DIR = "/durable/trust";
  try {
    assert.deepEqual(await driver("prepare", config, [], ["1"]), [{ type: "mock-ok" }]);
  } finally {
    if (previousDriver === undefined) delete process.env.AGMSG_SYNC_DRIVER;
    else process.env.AGMSG_SYNC_DRIVER = previousDriver;
    if (previousToken === undefined) delete process.env.AGMSG_SYNC_TOKEN;
    else process.env.AGMSG_SYNC_TOKEN = previousToken;
    if (previousIdentity === undefined) delete process.env.AGMSG_AGE_IDENTITY;
    else process.env.AGMSG_AGE_IDENTITY = previousIdentity;
    if (previousIdentityFile === undefined) delete process.env.AGMSG_AGE_IDENTITY_FILE;
    else process.env.AGMSG_AGE_IDENTITY_FILE = previousIdentityFile;
    if (previousSyncIdentity === undefined) delete process.env.AGMSG_SYNC_AGE_IDENTITY_EPOCH_1;
    else process.env.AGMSG_SYNC_AGE_IDENTITY_EPOCH_1 = previousSyncIdentity;
    if (previousTrust === undefined) delete process.env.AGMSG_SYNC_TRUST_DIR;
    else process.env.AGMSG_SYNC_TRUST_DIR = previousTrust;
    if (!root.startsWith(join(tmpdir(), "agmsg-sync-driver-env-"))) throw new Error("unsafe test root");
    await rm(root, { recursive: true });
  }
});

test("age-v1 write selection exposes only public epoch material", () => {
  const recipients = ["age1mmqjrejftea4f6xh47lhpc0jn4vw0yuhz349sw2e3sfl22k5gcjsv6xcvp"];
  const ageConfig = {
    ...config,
    cipher_profile: "age-v1",
    local_security_history: [{ local_security_revision: "0", effective_from_seq: "1",
      minimum_security_mode: "e2ee-required" }],
    age_v1: { epoch_snapshot: { history: [{ epoch_revision: "0", effective_from_seq: "1",
      cipher: "age-v1", key_id: "epoch-1", recipients }] },
    identity_files: { "epoch-1": "/secret/identity" } },
  };
  const policy = {
    protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, min_available_seq: "0", current_seq: "4",
    next_sequence_boundary: "5", accepted_envelope_versions: [1],
    write_allowed_ciphers: ["age-v1"], policy_revision: "0", effective_from_seq: "1",
    max_blob_bytes: "1048576", policy_history: [{ policy_revision: "0",
      effective_from_seq: "1", accepted_envelope_versions: [1],
      write_allowed_ciphers: ["age-v1"] }],
  };
  const selected = selectWriteProfile(ageConfig, policy);
  assert.deepEqual(selected, { eligible: true, profile: "age-v1", key_id: "epoch-1", recipients });
  assert.equal(JSON.stringify(selected).includes("identity"), false);
});

test("age-v1 configuration binds its checkpoint and initial history", () => {
  assert.throws(() => ageSnapshotDigest({ bad: "\ud800" }), /lone surrogate/u);
  assert.throws(() => ageSnapshotDigest({ ["\udc00"]: "bad-key" }), /lone surrogate/u);
  const snapshot = {
    profile: "age-v1",
    server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id,
    epoch_revision: "0",
    writer_generation: "0",
    authorized_writers: ["writer-a"],
    previous_snapshot_sha256: null,
    history: [{ epoch_revision: "0", effective_from_seq: "1", cipher: "age-v1",
      key_id: "epoch-1", recipients: [
        "age1mmqjrejftea4f6xh47lhpc0jn4vw0yuhz349sw2e3sfl22k5gcjsv6xcvp",
      ] }],
  };
  const ageConfig = { ...config, cipher_profile: "age-v1", age_v1: {
    epoch_snapshot: snapshot,
    checkpoint: { epoch_revision: "0", writer_generation: "0",
      snapshot_sha256: ageSnapshotDigest(snapshot), confirmed_at: "2026-07-21T00:00:00.000Z" },
    identity_files: {}, age_version: "v1.3.1",
  } };
  assert.doesNotThrow(() => validateAgeConfiguration(ageConfig));
  assert.throws(() => validateAgeConfiguration({ ...ageConfig, age_v1: {
    ...ageConfig.age_v1, checkpoint: { ...ageConfig.age_v1.checkpoint,
      snapshot_sha256: "0".repeat(64) },
  } }), /checkpoint/u);
  assert.throws(() => validateAgeConfiguration({ ...ageConfig, age_v1: {
    ...ageConfig.age_v1, epoch_snapshot: { ...snapshot, previous_snapshot_sha256: "1".repeat(64) },
  } }), /previous digest/u);
  const rotated = { ...snapshot, epoch_revision: "1", previous_snapshot_sha256: "1".repeat(64),
    history: [...snapshot.history, { ...snapshot.history[0], epoch_revision: "1",
      effective_from_seq: "2", key_id: "epoch-2" }] };
  assert.throws(() => validateAgeConfiguration({ ...ageConfig, age_v1: {
    ...ageConfig.age_v1,
    epoch_snapshot: rotated,
    checkpoint: { ...ageConfig.age_v1.checkpoint, epoch_revision: "1",
      snapshot_sha256: ageSnapshotDigest(rotated) },
  } }), /only an initial revision-0/u);
});

test("retained age checkpoint survives sync config reset and rejects same-revision conflict", async () => {
  const root = await mkdtemp(join(tmpdir(), "agmsg-age-trust-"));
  const previousTrust = process.env.AGMSG_SYNC_TRUST_DIR;
  const previousStorage = process.env.AGMSG_SYNC_STORAGE_DIR;
  process.env.AGMSG_SYNC_TRUST_DIR = join(root, "trust");
  process.env.AGMSG_SYNC_STORAGE_DIR = join(root, "resettable-store");
  const snapshot = {
    profile: "age-v1", server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, epoch_revision: "0", writer_generation: "0",
    authorized_writers: ["writer-a"], previous_snapshot_sha256: null,
    history: [{ epoch_revision: "0", effective_from_seq: "1", cipher: "age-v1",
      key_id: "epoch-1", recipients: [
        "age1mmqjrejftea4f6xh47lhpc0jn4vw0yuhz349sw2e3sfl22k5gcjsv6xcvp",
      ] }],
  };
  const makeConfig = (value) => ({ ...config, cipher_profile: "age-v1", age_v1: {
    epoch_snapshot: value,
    checkpoint: { epoch_revision: "0", writer_generation: "0",
      snapshot_sha256: ageSnapshotDigest(value), confirmed_at: "2026-07-21T00:00:00.000Z" },
    identity_files: {}, age_version: "v1.3.1",
  } });
  try {
    await assert.rejects(retainAgeCheckpoint(makeConfig(snapshot), undefined), /operator-live/u);
    const retained = await retainAgeCheckpoint(makeConfig(snapshot), "operator-live");
    assert.equal(retained.snapshot_sha256, ageSnapshotDigest(snapshot));
    const resettableConfig = join(process.env.AGMSG_SYNC_STORAGE_DIR, "remote-sync", "demo.json");
    await mkdir(join(process.env.AGMSG_SYNC_STORAGE_DIR, "remote-sync"), { recursive: true });
    await writeFile(resettableConfig, "{}\n");
    await unlink(resettableConfig);
    const conflicting = { ...snapshot, authorized_writers: ["writer-b"] };
    await assert.rejects(retainAgeCheckpoint(makeConfig(conflicting), "operator-live"),
      /same-revision conflict/u);
  } finally {
    if (previousTrust === undefined) delete process.env.AGMSG_SYNC_TRUST_DIR;
    else process.env.AGMSG_SYNC_TRUST_DIR = previousTrust;
    if (previousStorage === undefined) delete process.env.AGMSG_SYNC_STORAGE_DIR;
    else process.env.AGMSG_SYNC_STORAGE_DIR = previousStorage;
    await rm(root, { recursive: true });
  }
});

test("configured native identity must belong to its epoch recipient manifest", async () => {
  const root = await mkdtemp(join(tmpdir(), "agmsg-age-identity-"));
  const identity = join(root, "identity");
  await writeFile(identity,
    "AGE-SECRET-KEY-14Z7XMNPZTPEMMM6DG2FSKEH042L7UMU79T645GAQJKU2LLJGPM2S7GWNLQ\n",
    { mode: 0o600 });
  const ageConfig = { ...config, age_v1: {
    identity_files: { "epoch-1": identity },
    epoch_snapshot: { history: [{ key_id: "epoch-1", recipients: [
      "age1mmqjrejftea4f6xh47lhpc0jn4vw0yuhz349sw2e3sfl22k5gcjsv6xcvp",
    ] }] },
  } };
  try {
    assert.throws(() => validateConfiguredAgeIdentities(ageConfig), /does not match/u);
  } finally {
    await rm(root, { recursive: true });
  }
});
