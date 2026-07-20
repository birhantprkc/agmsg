#!/usr/bin/env node

import { appendFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import process from "node:process";

let input = "";
for await (const chunk of process.stdin) input += chunk;
const request = JSON.parse(input);
appendFileSync(process.env.AGMSG_SYNC_TEST_WIRE_LOG, `${request.wire_id}\n`, { mode: 0o600 });
const result = spawnSync(process.execPath,
  [process.env.AGMSG_SYNC_REAL_CIPHER_HELPER, "seal"], { input, maxBuffer: 4 * 1024 * 1024 });
process.stdout.write(result.stdout);
process.stderr.write(result.stderr);
process.exitCode = result.status ?? 1;
