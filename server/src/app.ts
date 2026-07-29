import Fastify, {
  type FastifyInstance,
  type FastifyRequest,
} from "fastify";
import fp from "fastify-plugin";
import * as duplicateKeyJson from "json-dup-key-validator";
import type { Pool } from "pg";
import { ZodError, z } from "zod";
import type { Config } from "./config.js";
import {
  authenticateCredential,
  credentialBinding,
  exchangePairingToken,
  revokeCredential,
  type CredentialIdentity,
} from "./credentials.js";
import { errorBody, ProtocolError } from "./errors.js";
import {
  MAX_REQUEST_BYTES,
  connectSchema,
  messagesQuerySchema,
  parseSequence,
  postMessagesSchema,
  readStateSyncSchema,
  teamNameSchema,
  uuidV7Schema,
} from "./protocol.js";
import {
  connectTeam,
  getCapabilities,
  getMembers,
  getTeamSnapshot,
  resolveTeamsByName,
  getMessages,
  health,
  postMessages,
  syncReadState,
} from "./storage.js";

const emptyQuerySchema = z.object({}).strict();
const pairingExchangeSchema = z.object({ token: z.string().min(32).max(256) }).strict();
const credentialParamsSchema = z.object({ credentialId: uuidV7Schema }).strict();
const teamParamsSchema = z.object({ teamId: uuidV7Schema }).strict();
const teamLookupQuerySchema = z.object({ name: teamNameSchema }).strict();

function requireProtocol(request: FastifyRequest): void {
  const version = request.headers["agmsg-protocol-version"];
  if (version !== "1") {
    throw new ProtocolError(
      426,
      "unsupported-protocol-version",
      "Agmsg-Protocol-Version must match /v1",
      { requested_version: version ?? null, supported_versions: [1] },
    );
  }
}

function requestedTeamId(request: FastifyRequest): string {
  const parsed = uuidV7Schema.safeParse(request.headers["agmsg-team-id"]);
  if (!parsed.success) {
    throw new ProtocolError(400, "invalid-request", "Agmsg-Team-ID is invalid");
  }
  return parsed.data;
}

function bearerSecret(request: FastifyRequest): string | undefined {
  const authorization = request.headers.authorization;
  return typeof authorization === "string" && authorization.startsWith("Bearer ")
    ? authorization.slice("Bearer ".length)
    : undefined;
}

async function scopedCredential(
  pool: Pool,
  request: FastifyRequest,
  includeRevoked = false,
): Promise<{ teamId: string; credential?: CredentialIdentity }> {
  requireProtocol(request);
  const teamId = requestedTeamId(request);
  const secret = bearerSecret(request);
  if (!secret) {
    throw new ProtocolError(401, "unauthenticated", "valid credentials are required");
  }
  const credential = await authenticateCredential(pool, teamId, secret, includeRevoked);
  if (!credential) {
    throw new ProtocolError(401, "unauthenticated", "valid credentials are required");
  }
  return { teamId, credential };
}

async function scopedTeamId(
  _pool: Pool,
  request: FastifyRequest,
): Promise<string> {
  // No credential — deliberately. On the remote-sync path, reaching the server
  // IS the permission, the same way reaching the filesystem is the permission
  // for a local team. The trust boundary is the network the server sits on
  // (LAN / tailscale / VPN, or loopback for self-host), not a per-request
  // secret; see docs/design/remote-sync.md. The team comes from the
  // Agmsg-Team-ID header alone, and the data-plane operations already reject a
  // team that does not exist (404), so an unknown id cannot read another team's
  // data. Do NOT "restore" a credential check here reading this as an
  // oversight. (scopedCredential itself stays: /v1/pairing/exchange and
  // /v1/credentials/:id/revoke — the pre-connect path this replaces — still use
  // it, and are removed separately.)
  requireProtocol(request);
  return requestedTeamId(request);
}

export function createApp(pool: Pool, config: Config): FastifyInstance {
  const app = Fastify({
    logger: config.logLevel === "silent" ? false : {
      level: config.logLevel,
      redact: {
        paths: [
          "req.headers.authorization",
          "req.body.token",
          "res.body.credential",
          "token",
          "credential",
        ],
        censor: "[REDACTED]",
      },
    },
    bodyLimit: MAX_REQUEST_BYTES,
  });

  void app.register(dataPlane, { pool, config });
  return app;
}

// The v1 protocol data plane — its content-type parser, hooks, error handling,
// and routes — as a registerable Fastify plugin, so the reference server can be
// embedded as a sub-app in another Fastify host, not only run standalone.
//
// `fastify-plugin` keeps the parser/hooks/error handler applied to the
// registration context (so a standalone createApp answers byte-for-byte as
// before, unknown-route 404s included); a host that wants isolation registers
// this inside its own encapsulating scope.
//
// Embedding contract: the plugin owns the responses for the v1 routes it
// registers, and their content-type parsing, protocol header, and error
// mapping. Everything else — unknown routes, and the host's own routes — is the
// host's responsibility, by contract, not by accident. Register before
// ready()/listen(); routes are not introspectable until then (register runs
// asynchronously).
async function dataPlaneRoutes(
  app: FastifyInstance,
  opts: { pool: Pool; config: Config },
): Promise<void> {
  const { pool, config } = opts;
  app.removeContentTypeParser("application/json");
  app.addContentTypeParser(
    "application/json",
    { parseAs: "buffer" },
    (_request, body, done) => {
      try {
        const bytes = typeof body === "string" ? Buffer.from(body) : body;
        const source = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
        done(null, duplicateKeyJson.parse(source, false));
      } catch (error) {
        const parsingError = error instanceof Error ? error : new Error("invalid JSON");
        Object.assign(parsingError, { statusCode: 400 });
        done(parsingError, undefined);
      }
    },
  );

  app.addHook("onRequest", async (request) => {
    const encoding = request.headers["content-encoding"];
    if (encoding !== undefined && encoding !== "identity") {
      throw new ProtocolError(
        400,
        "invalid-request",
        "Content-Encoding must be identity",
      );
    }
  });

  app.addHook("onSend", async (_request, reply, payload) => {
    reply.header("Agmsg-Protocol-Version", "1");
    return payload;
  });

  app.setErrorHandler((error, _request, reply) => {
    if (error instanceof ProtocolError) {
      void reply.status(error.statusCode).send(errorBody(error));
      return;
    }
    if (
      error instanceof ZodError ||
      error instanceof SyntaxError ||
      statusCode(error) === 400 ||
      statusCode(error) === 415
    ) {
      const protocolError = new ProtocolError(
        400,
        "invalid-request",
        "request body, query, or JSON framing is invalid",
      );
      void reply.status(400).send(errorBody(protocolError));
      return;
    }
    if (statusCode(error) === 413) {
      const protocolError = new ProtocolError(
        413,
        "request-too-large",
        "request body exceeds 2 MiB",
      );
      void reply.status(413).send(errorBody(protocolError));
      return;
    }
    requestLog(reply, error);
    const protocolError = new ProtocolError(
      500,
      "internal-error",
      "an internal server error occurred",
    );
    void reply.status(500).send(errorBody(protocolError));
  });

  app.get("/v1/health", async (_request, reply) => {
    try {
      return await health(pool);
    } catch {
      return reply.status(503).send({
        status: "unavailable",
        protocol: { supported_versions: [1] },
        database: "unavailable",
      });
    }
  });

  app.get("/v1/capabilities", async (request, reply) => {
    emptyQuerySchema.parse(request.query);
    const teamId = await scopedTeamId(pool, request);
    reply.header("Cache-Control", "no-store");
    return getCapabilities(pool, teamId);
  });

  app.get("/v1/members", async (request) => {
    emptyQuerySchema.parse(request.query);
    return getMembers(pool, await scopedTeamId(pool, request));
  });

  app.get("/v1/messages", async (request) => {
    const teamId = await scopedTeamId(pool, request);
    const query = messagesQuerySchema.parse(request.query);
    return getMessages(pool, teamId, parseSequence(query.after), query.limit);
  });

  app.post("/v1/messages", { bodyLimit: MAX_REQUEST_BYTES }, async (request) => {
    const teamId = await scopedTeamId(pool, request);
    const body = postMessagesSchema.parse(request.body);
    return postMessages(pool, teamId, body.messages,
      config.retentionMaxLiveMessages, (notice) => {
        app.log.info({ event: "retention.applied", ...notice },
          "automatic live-message retention applied");
      });
  });

  app.post("/v1/read-state/sync", { bodyLimit: MAX_REQUEST_BYTES }, async (request, reply) => {
    emptyQuerySchema.parse(request.query);
    const teamId = await scopedTeamId(pool, request);
    const body = readStateSyncSchema.parse(request.body);
    reply.header("Cache-Control", "no-store");
    return syncReadState(pool, teamId, body);
  });

  app.post("/v1/pairing/exchange", { bodyLimit: MAX_REQUEST_BYTES }, async (request, reply) => {
    requireProtocol(request);
    emptyQuerySchema.parse(request.query);
    const body = pairingExchangeSchema.parse(request.body);
    reply.header("Cache-Control", "no-store");
    return exchangePairingToken(pool, body.token);
  });

  // Registers a team the client owns. No credential: reaching the server is the
  // permission, the way reaching the filesystem is locally. The client mints
  // the team_id, so this route never scopes to an existing one.
  app.post("/v1/connect", { bodyLimit: MAX_REQUEST_BYTES }, async (request, reply) => {
    requireProtocol(request);
    emptyQuerySchema.parse(request.query);
    const body = connectSchema.parse(request.body);
    reply.header("Cache-Control", "no-store");
    return connectTeam(pool, body);
  });

  // The other half of connect: a second machine takes a team it does not have.
  // Scoped by the id in the path rather than by a credential, for the reason
  // /v1/connect has none — reaching the server is the permission. Knowing a
  // team_id is therefore enough to read a team, which the design records as
  // accepted for this minimum rather than overlooked.
  // Look a team up by name, so a second machine does not have to be handed a
  // UUID by a human. A name is not unique -- only team_id is -- so this always
  // answers with a list and the caller decides; one match is the ordinary case,
  // not a guarantee.
  app.get("/v1/teams", async (request, reply) => {
    requireProtocol(request);
    const query = teamLookupQuerySchema.parse(request.query);
    reply.header("Cache-Control", "no-store");
    return resolveTeamsByName(pool, query.name);
  });

  app.get("/v1/teams/:teamId", async (request, reply) => {
    requireProtocol(request);
    emptyQuerySchema.parse(request.query);
    const params = teamParamsSchema.parse(request.params);
    reply.header("Cache-Control", "no-store");
    return getTeamSnapshot(pool, params.teamId);
  });

  // History is paged rather than returned whole: a team that has been running
  // is thousands of messages, and the caller already has to handle a cursor
  // because retention can move min_available_seq under it mid-pull.
  app.get("/v1/teams/:teamId/messages", async (request, reply) => {
    requireProtocol(request);
    const params = teamParamsSchema.parse(request.params);
    const query = messagesQuerySchema.parse(request.query);
    reply.header("Cache-Control", "no-store");
    return getMessages(pool, params.teamId, parseSequence(query.after), query.limit);
  });

  app.post("/v1/credentials/:credentialId/revoke", { bodyLimit: MAX_REQUEST_BYTES }, async (request, reply) => {
    emptyQuerySchema.parse(request.query);
    z.undefined().parse(request.body);
    const params = credentialParamsSchema.parse(request.params);
    const authenticated = await scopedCredential(pool, request, true);
    if (
      authenticated.credential &&
      authenticated.credential.credentialId !== params.credentialId
    ) {
      const binding = await credentialBinding(pool, authenticated.teamId);
      throw new ProtocolError(
        403,
        "credential-scope-violation",
        "a credential may revoke only itself",
        { credential_id: params.credentialId },
        binding,
      );
    }
    reply.header("Cache-Control", "no-store");
    return revokeCredential(pool, authenticated.teamId, params.credentialId);
  });
}

export const dataPlane = fp(dataPlaneRoutes, {
  name: "agmsg-data-plane",
  fastify: "5.x",
});

function requestLog(reply: { log: { error: (value: unknown) => void } }, error: unknown) {
  // Log a safe, structured record rather than the raw Error: when the plugin is
  // embedded in another host, that host's logger may not redact, so the plugin
  // must not hand it an object that could carry sensitive fields. The class name
  // is enough to correlate an internal-error 500 with its cause in the source.
  reply.log.error({
    event: "internal-error",
    error_name: error instanceof Error ? error.name : typeof error,
  });
}

function statusCode(error: unknown): number | undefined {
  if (typeof error !== "object" || error === null || !("statusCode" in error)) {
    return undefined;
  }
  return typeof error.statusCode === "number" ? error.statusCode : undefined;
}
