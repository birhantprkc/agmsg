#!/usr/bin/env node
import { spawn } from "node:child_process";
import { appendFile, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import process from "node:process";

const UUID_V7 = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const SEQUENCE = /^(0|[1-9][0-9]*)$/;
const TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/;
const PROTOCOL = "1";
const MAX_SEQUENCE = 9_223_372_036_854_775_807n;

function usage() {
  return `usage:
  remote-sync.sh configure --team NAME --server URL --team-id UUID --minimum-security plaintext-allowed
  remote-sync.sh once --team NAME [--limit N]
  remote-sync.sh run --team NAME [--limit N] [--interval SECONDS]

AGMSG_SYNC_TOKEN is required and is never written to config or argv.`;
}

function options(args) {
  const result = { _: [] };
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    if (!value.startsWith("--")) { result._.push(value); continue; }
    const next = args[index + 1];
    if (next === undefined || next.startsWith("--")) throw new Error(`missing value for ${value}`);
    result[value.slice(2)] = next;
    index += 1;
  }
  return result;
}

function requireName(value, label) {
  if (typeof value !== "string" || value.length < 1 || value.length > 128 ||
      value.startsWith("-") || value === "." || value === ".." ||
      /[./\\"\[\]\u0000-\u001f\u007f]/u.test(value) || value !== value.normalize("NFC")) {
    throw new Error(`${label} is invalid`);
  }
  return value;
}

function sequence(value, label) {
  if (typeof value !== "string" || !SEQUENCE.test(value) || BigInt(value) > MAX_SEQUENCE) {
    throw new Error(`${label} is not a canonical sequence`);
  }
  return value;
}

function configPath(team) {
  const root = process.env.AGMSG_SYNC_STORAGE_DIR;
  if (!root) throw new Error("AGMSG_SYNC_STORAGE_DIR is not set");
  return join(root, "remote-sync", `${encodeURIComponent(team)}.json`);
}

async function writeConfig(path, value) {
  const directory = dirname(path);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const temporary = join(directory, `.${basename(path)}.${process.pid}.tmp`);
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  await rename(temporary, path);
}

async function loadConfig(team) {
  const value = JSON.parse(await readFile(configPath(team), "utf8"));
  if (value.local_team !== team || value.protocol_version !== 1 ||
      !UUID_V7.test(value.server_instance_id) || !UUID_V7.test(value.remote_team_id)) {
    throw new Error("sync config binding is invalid");
  }
  return value;
}

function endpoint(base, path) {
  const root = new URL(base);
  if (root.username || root.password || root.search || root.hash) {
    throw new Error("server URL must not contain credentials, query, or fragment");
  }
  const prefix = root.pathname.replace(/\/$/, "");
  const separator = path.indexOf("?");
  const pathname = separator === -1 ? path : path.slice(0, separator);
  const query = separator === -1 ? "" : path.slice(separator + 1);
  root.pathname = `${prefix}${pathname}`;
  root.search = query;
  return root;
}

async function request(config, path, init = {}) {
  const token = process.env.AGMSG_SYNC_TOKEN;
  if (!token) throw new Error("AGMSG_SYNC_TOKEN is required");
  const headers = {
    "Agmsg-Protocol-Version": PROTOCOL,
    "Agmsg-Team-ID": config.remote_team_id,
    Authorization: `Bearer ${token}`,
    ...init.headers,
  };
  const response = await fetch(endpoint(config.server_url, path), {
    ...init, headers, redirect: "error", signal: AbortSignal.timeout(15_000),
  });
  const protocol = response.headers.get("agmsg-protocol-version");
  if (protocol !== PROTOCOL) throw new Error("response protocol version mismatch");
  const text = await response.text();
  let body;
  try { body = JSON.parse(text); } catch { throw new Error(`HTTP ${response.status} returned invalid JSON`); }
  if (!response.ok) {
    const code = body?.error?.code ?? "unknown-error";
    const error = new Error(`HTTP ${response.status} ${code}`);
    error.status = response.status; error.code = code; error.body = body;
    throw error;
  }
  validateBinding(config, body);
  return body;
}

async function health(serverUrl) {
  const response = await fetch(endpoint(serverUrl, "/v1/health"), {
    redirect: "error", signal: AbortSignal.timeout(15_000),
  });
  if (response.headers.get("agmsg-protocol-version") !== PROTOCOL) {
    throw new Error("health protocol version mismatch");
  }
  const body = await response.json();
  if (!response.ok || body.status !== "ok" || body.database !== "ok" || !UUID_V7.test(body.server_instance_id)) {
    throw new Error("server health is unavailable or unbound");
  }
  return body;
}

function validateBinding(config, body) {
  if (body?.protocol_version !== 1 || body?.server_instance_id !== config.server_instance_id ||
      body?.team_id !== config.remote_team_id) {
    throw new Error("server/team binding mismatch");
  }
}

async function driver(operation, config, input, extra = []) {
  const script = process.env.AGMSG_SYNC_DRIVER;
  if (!script) throw new Error("AGMSG_SYNC_DRIVER is not set");
  const args = [script, operation, config.local_team, config.server_instance_id,
    config.remote_team_id, String(config.protocol_version), ...extra];
  return new Promise((resolve, reject) => {
    const child = spawn("bash", args, { stdio: ["pipe", "pipe", "pipe"], env: process.env });
    let stdout = ""; let stderr = "";
    child.stdout.setEncoding("utf8"); child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) resolve(parseJsonl(stdout));
      else reject(new Error(`storage sync ${operation} failed (${code}): ${stderr.trim()}`));
    });
    child.stdin.end(input.map((record) => `${JSON.stringify(record)}\n`).join(""));
  });
}

function parseJsonl(value) {
  return value.split(/\r?\n/u).filter(Boolean).map((line) => JSON.parse(line));
}

async function event(name, fields = {}) {
  const record = { at: new Date().toISOString(), event: name, ...fields };
  const line = `${JSON.stringify(record)}\n`;
  process.stdout.write(line);
  if (process.env.AGMSG_SYNC_LOG_FILE) {
    await appendFile(process.env.AGMSG_SYNC_LOG_FILE, line, { encoding: "utf8", mode: 0o600 });
  }
}

function currentPolicy(capabilities, serverSeq) {
  const target = BigInt(serverSeq);
  const candidates = capabilities.policy_history.filter((entry) =>
    BigInt(sequence(entry.effective_from_seq, "policy effective_from_seq")) <= target);
  if (candidates.length === 0) throw new Error("policy history has no effective entry");
  return candidates.reduce((best, entry) => BigInt(entry.policy_revision) > BigInt(best.policy_revision) ? entry : best);
}

function currentLocalPolicy(config, serverSeq) {
  const target = BigInt(serverSeq);
  const candidates = config.local_security_history.filter((entry) => BigInt(entry.effective_from_seq) <= target);
  if (candidates.length === 0) throw new Error("local security history has no effective entry");
  return candidates.reduce((best, entry) => BigInt(entry.local_security_revision) > BigInt(best.local_security_revision) ? entry : best);
}

function canonicalPlaintext(envelope) {
  if (envelope.v !== 1 || envelope.cipher !== "none" || envelope.key_id !== null ||
      typeof envelope.blob !== "string" || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(envelope.blob)) {
    throw new Error("malformed envelope");
  }
  const bytes = Buffer.from(envelope.blob, "base64");
  if (bytes.length < 1 || bytes.length > 1024 * 1024 || bytes.toString("base64") !== envelope.blob) {
    throw new Error("malformed base64 blob");
  }
  const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  const value = JSON.parse(text);
  const keys = Object.keys(value);
  if (JSON.stringify(keys) !== JSON.stringify(["body", "created_at", "from_agent", "to_agent"]) ||
      typeof value.body !== "string" || Buffer.byteLength(value.body) < 1 || Buffer.byteLength(value.body) > 1_000_000 ||
      typeof value.created_at !== "string" || !TIMESTAMP.test(value.created_at)) {
    throw new Error("malformed plaintext projection");
  }
  requireName(value.from_agent, "from_agent"); requireName(value.to_agent, "to_agent");
  const canonical = JSON.stringify({ body: value.body, created_at: value.created_at,
    from_agent: value.from_agent, to_agent: value.to_agent });
  if (canonical !== text) throw new Error("plaintext is not canonical JCS");
  return value;
}

function evaluatePull(config, capabilities, message) {
  sequence(message.server_seq, "message server_seq");
  if (!UUID_V4.test(message.id) || !TIMESTAMP.test(message.server_received_at) || typeof message.envelope !== "object") {
    return { status: "malformed", reason: "invalid message metadata" };
  }
  const serverPolicy = currentPolicy(capabilities, message.server_seq);
  const localPolicy = currentLocalPolicy(config, message.server_seq);
  if (!serverPolicy.accepted_envelope_versions.includes(message.envelope.v) ||
      !serverPolicy.write_allowed_ciphers.includes(message.envelope.cipher) ||
      (localPolicy.minimum_security_mode === "e2ee-required" && message.envelope.cipher === "none")) {
    return { status: "policy_violation", reason: "envelope violates effective policy",
      policy_revision: serverPolicy.policy_revision,
      local_security_revision: localPolicy.local_security_revision };
  }
  if (message.envelope.v !== 1 || message.envelope.cipher !== "none") {
    return { status: "unsupported_cipher", reason: "Stage-1 supports cipher none only",
      policy_revision: serverPolicy.policy_revision,
      local_security_revision: localPolicy.local_security_revision };
  }
  try {
    return { status: "importable", projection: canonicalPlaintext(message.envelope),
      policy_revision: serverPolicy.policy_revision,
      local_security_revision: localPolicy.local_security_revision };
  } catch (error) {
    return { status: "malformed", reason: error.message,
      policy_revision: serverPolicy.policy_revision,
      local_security_revision: localPolicy.local_security_revision };
  }
}

function validateCapabilities(config, value) {
  validateBinding(config, value);
  sequence(value.current_seq, "current_seq"); sequence(value.min_available_seq, "min_available_seq");
  if (!Array.isArray(value.policy_history) || value.policy_history.length < 1 || value.policy_history.length > 4096 ||
      !Array.isArray(value.accepted_envelope_versions) || !Array.isArray(value.write_allowed_ciphers)) {
    throw new Error("capabilities response is invalid");
  }
  if (!value.accepted_envelope_versions.includes(1) || !value.write_allowed_ciphers.includes("none")) {
    throw new Error("server does not currently allow Stage-1 plaintext writes");
  }
  const boundary = value.next_sequence_boundary;
  if (boundary === null) throw new Error("remote sequence is exhausted");
  sequence(boundary, "next_sequence_boundary");
  if (currentLocalPolicy(config, boundary).minimum_security_mode !== "plaintext-allowed") {
    throw new Error("local security policy disallows Stage-1 plaintext writes");
  }
}

async function configure(args) {
  const team = requireName(args.team, "team");
  if (!UUID_V7.test(args["team-id"] ?? "")) throw new Error("team-id must be a canonical UUIDv7");
  if (args["minimum-security"] !== "plaintext-allowed") {
    throw new Error("Stage-1 requires explicit --minimum-security plaintext-allowed");
  }
  if (!process.env.AGMSG_SYNC_TOKEN) throw new Error("AGMSG_SYNC_TOKEN is required");
  const serverUrl = new URL(args.server).toString().replace(/\/$/, "");
  const ready = await health(serverUrl);
  const config = {
    format_version: 1, local_team: team, server_url: serverUrl,
    server_instance_id: ready.server_instance_id, remote_team_id: args["team-id"],
    protocol_version: 1,
    local_security_history: [{ local_security_revision: "0", effective_from_seq: "1",
      minimum_security_mode: "plaintext-allowed" }],
  };
  const capabilities = await request(config, "/v1/capabilities");
  validateCapabilities(config, capabilities);
  await writeConfig(configPath(team), config);
  await event("configured", { team, server_instance_id: config.server_instance_id,
    remote_team_id: config.remote_team_id });
}

async function cycle(config, limit) {
  const ready = await health(config.server_url);
  if (ready.server_instance_id !== config.server_instance_id) throw new Error("health server instance changed");
  const capabilities = await request(config, "/v1/capabilities");
  validateCapabilities(config, capabilities);
  await event("capabilities", { team: config.local_team, current_seq: capabilities.current_seq,
    policy_revision: capabilities.policy_revision });

  const prepared = await driver("prepare", config, [{ type: "sync_prepare", envelope_v: 1,
    cipher: "none", key_id: null, max_blob_bytes: Number(capabilities.max_blob_bytes) }], [String(limit)]);
  const state = prepared.find((record) => record.type === "sync_state");
  const candidates = prepared.filter((record) => record.type === "sync_push_candidate");
  if (!state) throw new Error("driver omitted sync_state");
  sequence(state.transport_cursor, "transport_cursor");
  await event("push.prepared", { count: candidates.length, local_positions: candidates.map((item) => item.local_position),
    wire_ids: candidates.map((item) => item.id) });

  if (candidates.length > 0) {
    const posted = await request(config, "/v1/messages", { method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ messages: candidates.map(({ id, envelope }) => ({ id, envelope })) }) });
    if (!Array.isArray(posted.acks) || posted.acks.length !== candidates.length) throw new Error("incomplete ack mapping");
    const ackRecords = posted.acks.map((ack, index) => {
      const candidate = candidates[index];
      if (ack.id !== candidate.id || !["stored", "duplicate"].includes(ack.disposition)) throw new Error("ack order/id mismatch");
      sequence(ack.server_seq, "ack server_seq");
      return { type: "sync_push_ack", local_position: candidate.local_position, id: ack.id,
        server_seq: ack.server_seq, disposition: ack.disposition };
    });
    await event("push.ack", { acks: ackRecords.map(({ id, server_seq, disposition }) => ({ id, server_seq, disposition })) });
    const reconciled = await driver("reconcile", config, ackRecords);
    await event("push.reconciled", { result: reconciled[0] ?? null });
  }

  let cursor = state.transport_cursor;
  let pullCapabilities = capabilities;
  for (;;) {
    const page = await request(config, `/v1/messages?after=${encodeURIComponent(cursor)}&limit=${limit}`);
    sequence(page.next_after, "next_after");
    if (!Array.isArray(page.messages) || page.messages.length > limit || typeof page.has_more !== "boolean") {
      throw new Error("pull page is invalid");
    }
    let expected = BigInt(cursor) + 1n;
    for (const message of page.messages) {
      sequence(message.server_seq, "message server_seq");
      if (BigInt(message.server_seq) !== expected) throw new Error("pull page sequence is not contiguous");
      expected += 1n;
    }
    const expectedNext = page.messages.at(-1)?.server_seq ?? cursor;
    if (page.next_after !== expectedNext || (page.has_more && page.messages.length === 0)) {
      throw new Error("pull page cursor/has_more is inconsistent");
    }
    if (BigInt(page.next_after) > BigInt(pullCapabilities.current_seq)) {
      pullCapabilities = await request(config, "/v1/capabilities");
      validateCapabilities(config, pullCapabilities);
      if (BigInt(page.next_after) > BigInt(pullCapabilities.current_seq)) {
        throw new Error("capability history does not cover the pull page");
      }
    }
    const records = page.messages.map((message) => {
      const evaluated = evaluatePull(config, pullCapabilities, message);
      return { type: "sync_pull_message", ...message, ...evaluated };
    });
    records.push({ type: "sync_pull_cursor", next_after: page.next_after });
    await event("pull.received", { after: cursor, next_after: page.next_after,
      messages: page.messages.map((message) => ({ id: message.id, server_seq: message.server_seq })) });
    const applied = await driver("apply", config, records);
    for (const record of records) {
      if (record.type === "sync_pull_message" && record.projection) {
        await event("pull.import", { id: record.id, server_seq: record.server_seq,
          from_agent: record.projection.from_agent, to_agent: record.projection.to_agent,
          body: record.projection.body });
      }
    }
    await event("pull.applied", { result: applied[0] ?? null });
    cursor = page.next_after;
    if (!page.has_more) break;
  }
}

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  const args = options(rest);
  if (!["configure", "once", "run"].includes(command)) throw new Error(usage());
  if (command === "configure") { await configure(args); return; }
  const team = requireName(args.team, "team");
  const limit = Number(args.limit ?? 100);
  if (!Number.isInteger(limit) || limit < 1 || limit > 1000) throw new Error("limit must be 1..1000");
  const config = await loadConfig(team);
  if (command === "once") { await cycle(config, limit); return; }
  const interval = Number(args.interval ?? 5);
  if (!Number.isFinite(interval) || interval < 0.2) throw new Error("interval must be at least 0.2 seconds");
  for (;;) {
    try { await cycle(config, limit); }
    catch (error) {
      await event("cycle.error", { message: error.message, code: error.code ?? null });
      if (error.status === 410 || error.code === "resync-required") throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, interval * 1000));
  }
}

main().catch(async (error) => {
  await event("fatal", { message: error.message, code: error.code ?? null });
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
