#!/usr/bin/env node
import { loadConfig } from "./config.js";
import {
  createTeam,
  issuePairingToken,
  listCredentials,
  resolveTeamId,
  revokeCredential,
} from "./credentials.js";
import { createPool, migrate } from "./db.js";

type Arguments = {
  positionals: string[];
  options: Map<string, string | true>;
};

const usage = `usage:
  npm run --silent admin -- team create --name NAME [--team-id UUID] [--json]
  npm run --silent admin -- token issue --team TEAM_OR_ID --endpoint URL [--json]
  npm run --silent admin -- credential list --team TEAM_OR_ID [--json]
  npm run --silent admin -- credential revoke --team TEAM_OR_ID --credential-id UUID [--json]`;

function parseArguments(values: string[]): Arguments {
  const positionals: string[] = [];
  const options = new Map<string, string | true>();
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    if (!value) continue;
    if (!value.startsWith("--")) {
      positionals.push(value);
      continue;
    }
    const name = value.slice(2);
    if (!name || options.has(name)) throw new Error(`invalid or duplicate option ${value}`);
    if (name === "json") {
      options.set(name, true);
      continue;
    }
    const optionValue = values[index + 1];
    if (!optionValue || optionValue.startsWith("--")) {
      throw new Error(`${value} requires a value`);
    }
    options.set(name, optionValue);
    index += 1;
  }
  return { positionals, options };
}

function option(args: Arguments, name: string, required = true): string | undefined {
  const value = args.options.get(name);
  if (value === true) throw new Error(`--${name} requires a value`);
  if (required && value === undefined) throw new Error(`--${name} is required`);
  return value;
}

function expectOptions(args: Arguments, allowed: string[]): void {
  const names = new Set(allowed.concat("json"));
  for (const name of args.options.keys()) {
    if (!names.has(name)) throw new Error(`unknown option --${name}`);
  }
}

function endpoint(value: string): string {
  const parsed = new URL(value);
  if (
    !["http:", "https:"].includes(parsed.protocol) ||
    parsed.username ||
    parsed.password ||
    parsed.search ||
    parsed.hash
  ) {
    throw new Error("--endpoint must be an HTTP(S) URL without credentials, query, or fragment");
  }
  const canonical = parsed.toString().replace(/\/$/u, "");
  if (!/^[A-Za-z0-9._~:/%\[\]-]+$/u.test(canonical)) {
    throw new Error("--endpoint contains characters that are unsafe in a paste-ready command");
  }
  return canonical;
}

function jsonEnabled(args: Arguments): boolean {
  return args.options.get("json") === true;
}

function writeJson(value: unknown): void {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

async function run(): Promise<void> {
  const args = parseArguments(process.argv.slice(2));
  const operation = args.positionals.join(" ");
  if (args.positionals.length !== 2) throw new Error(usage);
  const config = loadConfig();
  const pool = createPool(config.databaseUrl);
  try {
    await migrate(pool);
    if (operation === "team create") {
      expectOptions(args, ["name", "team-id"]);
      const result = await createTeam(
        pool,
        option(args, "name") ?? "",
        option(args, "team-id", false),
      );
      if (jsonEnabled(args)) writeJson(result);
      else process.stdout.write(`${result.team_id}\n`);
      process.stderr.write(`Created team ${result.team_name} (${result.team_id}).\n`);
      return;
    }
    if (operation === "token issue") {
      expectOptions(args, ["team", "endpoint"]);
      const teamId = await resolveTeamId(pool, option(args, "team") ?? "");
      const issued = await issuePairingToken(pool, teamId);
      const serverEndpoint = endpoint(option(args, "endpoint") ?? "");
      const command = `agmsg remote connect --endpoint ${serverEndpoint} ${issued.token}`;
      if (jsonEnabled(args)) writeJson({ ...issued, endpoint: serverEndpoint, command });
      else process.stdout.write(`${command}\n`);
      process.stderr.write(
        `Issued one-time pairing token for team ${teamId}; expires ${issued.expires_at}.\n`,
      );
      return;
    }
    if (operation === "credential list") {
      expectOptions(args, ["team"]);
      const teamId = await resolveTeamId(pool, option(args, "team") ?? "");
      const rows = await listCredentials(pool, teamId);
      if (jsonEnabled(args)) writeJson({ team_id: teamId, credentials: rows });
      else {
        for (const row of rows) {
          process.stdout.write(
            `${row.credential_id}\t${row.status}\t${row.connected_at}\t${row.last_active_at ?? "-"}\n`,
          );
        }
      }
      process.stderr.write(`Listed ${rows.length} credential(s) for team ${teamId}.\n`);
      return;
    }
    if (operation === "credential revoke") {
      expectOptions(args, ["team", "credential-id"]);
      const teamId = await resolveTeamId(pool, option(args, "team") ?? "");
      const result = await revokeCredential(
        pool,
        teamId,
        option(args, "credential-id") ?? "",
      );
      if (jsonEnabled(args)) writeJson(result);
      else process.stdout.write(`${result.credential_id}\n`);
      process.stderr.write(`Revoked credential ${result.credential_id} for team ${teamId}.\n`);
      return;
    }
    throw new Error(usage);
  } finally {
    await pool.end();
  }
}

try {
  await run();
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`error: ${message}\n`);
  process.exitCode = 1;
}
