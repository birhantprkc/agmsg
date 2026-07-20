import { timingSafeEqual } from "node:crypto";
import Fastify, {
  type FastifyInstance,
  type FastifyRequest,
} from "fastify";
import * as duplicateKeyJson from "json-dup-key-validator";
import type { Pool } from "pg";
import { ZodError, z } from "zod";
import type { Config } from "./config.js";
import { errorBody, ProtocolError } from "./errors.js";
import {
  MAX_REQUEST_BYTES,
  messagesQuerySchema,
  parseSequence,
  postMessagesSchema,
  uuidV7Schema,
} from "./protocol.js";
import {
  getCapabilities,
  getMembers,
  getMessages,
  health,
  postMessages,
} from "./storage.js";

const emptyQuerySchema = z.object({}).strict();

function tokenMatches(expected: string, actual: string): boolean {
  const left = Buffer.from(expected);
  const right = Buffer.from(actual);
  return left.length === right.length && timingSafeEqual(left, right);
}

function scopedTeamId(request: FastifyRequest, token: string): string {
  const version = request.headers["agmsg-protocol-version"];
  if (version !== "1") {
    throw new ProtocolError(
      426,
      "unsupported-protocol-version",
      "Agmsg-Protocol-Version must match /v1",
      { requested_version: version ?? null, supported_versions: [1] },
    );
  }
  const authorization = request.headers.authorization;
  if (
    typeof authorization !== "string" ||
    !authorization.startsWith("Bearer ") ||
    !tokenMatches(token, authorization.slice("Bearer ".length))
  ) {
    throw new ProtocolError(401, "unauthenticated", "valid credentials are required");
  }
  const parsed = uuidV7Schema.safeParse(request.headers["agmsg-team-id"]);
  if (!parsed.success) {
    throw new ProtocolError(400, "invalid-request", "Agmsg-Team-ID is invalid");
  }
  return parsed.data;
}

export function createApp(pool: Pool, config: Config): FastifyInstance {
  const app = Fastify({
    logger: config.logLevel === "silent" ? false : { level: config.logLevel },
    bodyLimit: MAX_REQUEST_BYTES,
  });

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
    const teamId = scopedTeamId(request, config.token);
    reply.header("Cache-Control", "no-store");
    return getCapabilities(pool, teamId);
  });

  app.get("/v1/members", async (request) => {
    emptyQuerySchema.parse(request.query);
    return getMembers(pool, scopedTeamId(request, config.token));
  });

  app.get("/v1/messages", async (request) => {
    const teamId = scopedTeamId(request, config.token);
    const query = messagesQuerySchema.parse(request.query);
    return getMessages(pool, teamId, parseSequence(query.after), query.limit);
  });

  app.post("/v1/messages", async (request) => {
    const teamId = scopedTeamId(request, config.token);
    const body = postMessagesSchema.parse(request.body);
    return postMessages(pool, teamId, body.messages);
  });

  return app;
}

function requestLog(reply: { log: { error: (value: unknown) => void } }, error: unknown) {
  reply.log.error(error);
}

function statusCode(error: unknown): number | undefined {
  if (typeof error !== "object" || error === null || !("statusCode" in error)) {
    return undefined;
  }
  return typeof error.statusCode === "number" ? error.statusCode : undefined;
}
