#!/usr/bin/env node

import { timingSafeEqual } from "node:crypto";
import { statSync } from "node:fs";
import { spawnSync } from "node:child_process";
import process from "node:process";

const UUID_V7 = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/u;
const KEY_ID = /^[a-z0-9][a-z0-9._-]{0,63}$/u;
const AGE_RECIPIENT = /^age1[0-9a-z]{58}$/u;
const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u;
const MAGIC = Buffer.concat([Buffer.from("agmsg-age-v1", "ascii"), Buffer.alloc(4)]);
const MAX_BLOB_BYTES = 1_048_576;

export class CipherStateError extends Error {
  constructor(state, message) {
    super(message);
    this.name = "CipherStateError";
    this.state = state;
  }
}

function malformed(message) {
  throw new CipherStateError("malformed", message);
}

function authenticationFailed(message) {
  throw new CipherStateError("authentication_failed", message);
}

function requireName(value, label) {
  if (typeof value !== "string" || value.length < 1 || value.length > 128 ||
      value.startsWith("-") || value === "." || value === ".." ||
      /[./\\"\[\]\u0000-\u001f\u007f]/u.test(value) || value !== value.normalize("NFC")) {
    malformed(`${label} is invalid`);
  }
  return value;
}

function canonicalMessage(projection) {
  if (!projection || Array.isArray(projection) || typeof projection !== "object" ||
      typeof projection.body !== "string" || Buffer.byteLength(projection.body) < 1 ||
      Buffer.byteLength(projection.body) > 1_000_000 ||
      typeof projection.created_at !== "string" || !TIMESTAMP.test(projection.created_at)) {
    malformed("message projection is invalid");
  }
  requireName(projection.from_agent, "from_agent");
  requireName(projection.to_agent, "to_agent");
  return Buffer.from(JSON.stringify({
    body: projection.body,
    created_at: projection.created_at,
    from_agent: projection.from_agent,
    to_agent: projection.to_agent,
  }), "utf8");
}

function parseCanonicalMessage(bytes) {
  let text;
  let value;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    value = JSON.parse(text);
  } catch {
    malformed("message is not valid UTF-8 JSON");
  }
  const canonical = canonicalMessage(value);
  if (!canonical.equals(bytes)) malformed("message is not canonical JCS");
  return value;
}

function canonicalBlob(blob, maxBlobBytes = MAX_BLOB_BYTES) {
  if (typeof blob !== "string" || blob.length < 1 || !BASE64.test(blob)) malformed("blob is not canonical base64");
  const bytes = Buffer.from(blob, "base64");
  if (bytes.length < 1 || bytes.length > maxBlobBytes || bytes.length > MAX_BLOB_BYTES ||
      bytes.toString("base64") !== blob) {
    malformed("blob is outside the canonical size limit");
  }
  return bytes;
}

function u16(value) {
  const result = Buffer.alloc(2);
  result.writeUInt16BE(value);
  return result;
}

function u32(value) {
  const result = Buffer.alloc(4);
  result.writeUInt32BE(value);
  return result;
}

function uuidBytes(value, pattern, label) {
  if (typeof value !== "string" || !pattern.test(value)) malformed(`${label} is invalid`);
  return Buffer.from(value.replaceAll("-", ""), "hex");
}

export function ageBindingContext({ protocol_version: protocolVersion, team_id: teamId,
  wire_id: wireId, cipher = "age-v1", key_id: keyId }) {
  if (!Number.isInteger(protocolVersion) || protocolVersion < 0 || protocolVersion > 0xffff_ffff ||
      cipher !== "age-v1" || typeof keyId !== "string" || !KEY_ID.test(keyId)) {
    malformed("age-v1 binding metadata is invalid");
  }
  const cipherBytes = Buffer.from(cipher, "ascii");
  const keyBytes = Buffer.from(keyId, "ascii");
  return Buffer.concat([
    u32(protocolVersion),
    uuidBytes(teamId, UUID_V7, "team_id"),
    uuidBytes(wireId, UUID_V4, "wire_id"),
    u16(cipherBytes.length), cipherBytes,
    u16(keyBytes.length), keyBytes,
  ]);
}

export function agePlaintextFrame(binding, projection) {
  const context = ageBindingContext(binding);
  const message = canonicalMessage(projection);
  return Buffer.concat([MAGIC, u32(context.length), context, u32(message.length), message]);
}

function validateAgeHeader(ageFile) {
  let offset = 0;
  let stanzaCount = 0;
  let insideStanza = false;
  function line() {
    const end = ageFile.indexOf(0x0a, offset);
    if (end === -1 || end - offset > 4096) malformed("age header is incomplete");
    const value = ageFile.subarray(offset, end).toString("ascii");
    if (!/^[\x20-\x7e]+$/u.test(value)) malformed("age header is not canonical ASCII");
    offset = end + 1;
    return value;
  }
  if (line() !== "age-encryption.org/v1") malformed("blob is not an age v1 file");
  while (offset < ageFile.length) {
    const value = line();
    if (value.startsWith("-> ")) {
      const fields = value.split(" ");
      if (fields.length !== 3 || fields[1] !== "X25519" || fields[2].length < 1) {
        malformed("age-v1 permits only native X25519 recipient stanzas");
      }
      stanzaCount += 1;
      if (stanzaCount > 256) malformed("age-v1 recipient stanza limit exceeded");
      insideStanza = true;
    } else if (value.startsWith("--- ")) {
      if (!insideStanza || stanzaCount < 1 || value.split(" ").length !== 2 || offset >= ageFile.length) {
        malformed("age header footer is invalid");
      }
      return;
    } else if (!insideStanza || !/^[A-Za-z0-9+/]+={0,2}$/u.test(value)) {
      malformed("age recipient stanza body is invalid");
    }
  }
  malformed("age header footer is missing");
}

function runAge(args, input) {
  const age = process.env.AGMSG_AGE_BIN || "age";
  const result = spawnSync(age, args, { input, maxBuffer: 4 * 1024 * 1024 });
  if (result.error?.code === "ENOENT") {
    throw new CipherStateError("unsupported_cipher", "age executable is unavailable");
  }
  if (result.error) throw result.error;
  return result;
}

export function ageExecutableVersion() {
  const result = runAge(["--version"], Buffer.alloc(0));
  if (result.status !== 0) throw new CipherStateError("unsupported_cipher", "age executable failed preflight");
  return result.stdout.toString("utf8").trim();
}

function sealNone(input, message) {
  if (input.key_id !== null) malformed("none requires null key_id");
  if (message.length > input.max_blob_bytes || message.length > MAX_BLOB_BYTES) {
    malformed("plaintext exceeds max_blob_bytes");
  }
  return { v: 1, cipher: "none", key_id: null, blob: message.toString("base64") };
}

function sealAge(input) {
  if (typeof input.key_id !== "string" || !KEY_ID.test(input.key_id) || !Array.isArray(input.recipients) ||
      input.recipients.length < 1 || input.recipients.length > 256 ||
      input.recipients.some((recipient) => typeof recipient !== "string" || !AGE_RECIPIENT.test(recipient)) ||
      new Set(input.recipients).size !== input.recipients.length) {
    malformed("age-v1 recipient manifest is invalid");
  }
  const frame = agePlaintextFrame({
    protocol_version: input.protocol_version,
    team_id: input.team_id,
    wire_id: input.wire_id,
    cipher: "age-v1",
    key_id: input.key_id,
  }, input.projection);
  const args = input.recipients.flatMap((recipient) => ["--recipient", recipient]);
  const result = runAge(args, frame);
  if (result.status !== 0) throw new Error(`age encryption failed: ${result.stderr.toString("utf8").trim()}`);
  if (result.stdout.length > input.max_blob_bytes || result.stdout.length > MAX_BLOB_BYTES) {
    malformed("encrypted age file exceeds max_blob_bytes");
  }
  validateAgeHeader(result.stdout);
  return { v: 1, cipher: "age-v1", key_id: input.key_id, blob: result.stdout.toString("base64") };
}

export const cipherProfiles = Object.freeze({
  none: Object.freeze({
    seal: sealNone,
    open: ({ envelope, max_blob_bytes: maxBlobBytes }) => openNone(envelope, maxBlobBytes),
  }),
  "age-v1": Object.freeze({ seal: sealAge, open: openAge }),
});

export function sealEnvelope(input) {
  if (!input || input.type !== "sync_seal" || input.envelope_v !== 1 ||
      !Number.isInteger(input.max_blob_bytes) || input.max_blob_bytes < 1 ||
      input.max_blob_bytes > MAX_BLOB_BYTES || !UUID_V4.test(input.wire_id ?? "") ||
      !UUID_V7.test(input.team_id ?? "") || input.protocol_version !== 1) {
    malformed("seal request is invalid");
  }
  const profile = cipherProfiles[input.cipher];
  if (!profile) throw new CipherStateError("unsupported_cipher", `unsupported cipher ${input.cipher}`);
  const message = canonicalMessage(input.projection);
  return profile.seal(input, message);
}

function openNone(envelope, maxBlobBytes) {
  if (envelope.v !== 1 || envelope.key_id !== null) malformed("none envelope metadata is invalid");
  return parseCanonicalMessage(canonicalBlob(envelope.blob, maxBlobBytes));
}

function openAge({ envelope, protocol_version: protocolVersion, team_id: teamId, wire_id: wireId,
  identity_file: identityFile, max_blob_bytes: maxBlobBytes = MAX_BLOB_BYTES }) {
  if (envelope.v !== 1 || typeof envelope.key_id !== "string" || !KEY_ID.test(envelope.key_id)) {
    malformed("age-v1 envelope metadata is invalid");
  }
  if (!identityFile) throw new CipherStateError("pending_key", "age identity is not installed");
  try {
    const metadata = statSync(identityFile);
    if (!metadata.isFile() || (process.platform !== "win32" && (metadata.mode & 0o077) !== 0)) {
      throw new Error("identity file is not private");
    }
  } catch {
    throw new CipherStateError("pending_key", "age identity is not readable");
  }
  const ageFile = canonicalBlob(envelope.blob, maxBlobBytes);
  validateAgeHeader(ageFile);
  const result = runAge(["--decrypt", "--identity", identityFile], ageFile);
  if (result.status !== 0) authenticationFailed("age decryption failed");
  const bytes = result.stdout;
  if (bytes.length < 24 || !bytes.subarray(0, 16).equals(MAGIC)) authenticationFailed("age frame magic is invalid");
  const contextLength = bytes.readUInt32BE(16);
  if (contextLength < 47 || contextLength > 110 || contextLength > bytes.length - 24) {
    authenticationFailed("age binding context length is invalid");
  }
  const contextEnd = 20 + contextLength;
  const actualContext = bytes.subarray(20, contextEnd);
  const expectedContext = ageBindingContext({ protocol_version: protocolVersion, team_id: teamId,
    wire_id: wireId, cipher: "age-v1", key_id: envelope.key_id });
  if (actualContext.length !== expectedContext.length || !timingSafeEqual(actualContext, expectedContext)) {
    authenticationFailed("age binding context mismatch");
  }
  const messageLength = bytes.readUInt32BE(contextEnd);
  const messageStart = contextEnd + 4;
  if (messageLength > bytes.length - messageStart || messageStart + messageLength !== bytes.length) {
    authenticationFailed("age plaintext frame length is invalid");
  }
  return parseCanonicalMessage(bytes.subarray(messageStart));
}

export async function openEnvelope(input) {
  const envelope = input?.envelope;
  if (!envelope || typeof envelope !== "object" || typeof envelope.cipher !== "string") {
    malformed("envelope is missing");
  }
  const profile = cipherProfiles[envelope.cipher];
  if (!profile) throw new CipherStateError("unsupported_cipher", `unsupported cipher ${envelope.cipher}`);
  return profile.open(input);
}

async function cli() {
  if (process.argv[2] !== "seal") throw new Error("usage: sync-cipher.mjs seal");
  let input = "";
  for await (const chunk of process.stdin) input += chunk;
  const value = JSON.parse(input);
  process.stdout.write(`${JSON.stringify(sealEnvelope(value))}\n`);
}

if (process.argv[2] === "seal") {
  cli().catch((error) => {
    process.stderr.write(`${error.state ? `${error.state}: ` : ""}${error.message}\n`);
    process.exitCode = 1;
  });
}
