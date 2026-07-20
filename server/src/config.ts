import { z } from "zod";

const environmentSchema = z.object({
  DATABASE_URL: z.string().min(1),
  AGMSG_SERVER_TOKEN: z.string().min(16),
  HOST: z.string().default("127.0.0.1"),
  PORT: z.coerce.number().int().min(1).max(65535).default(8787),
  LOG_LEVEL: z
    .enum(["fatal", "error", "warn", "info", "debug", "trace", "silent"])
    .default("info"),
});

export type Config = {
  databaseUrl: string;
  token: string;
  host: string;
  port: number;
  logLevel: z.infer<typeof environmentSchema>["LOG_LEVEL"];
};

export function loadConfig(environment: NodeJS.ProcessEnv = process.env): Config {
  const parsed = environmentSchema.parse(environment);
  return {
    databaseUrl: parsed.DATABASE_URL,
    token: parsed.AGMSG_SERVER_TOKEN,
    host: parsed.HOST,
    port: parsed.PORT,
    logLevel: parsed.LOG_LEVEL,
  };
}
