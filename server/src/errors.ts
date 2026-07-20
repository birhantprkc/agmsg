export class ProtocolError extends Error {
  constructor(
    readonly statusCode: number,
    readonly code: string,
    message: string,
    readonly details: Record<string, unknown> = {},
    readonly binding: { serverInstanceId?: string; teamId?: string } = {},
  ) {
    super(message);
    this.name = "ProtocolError";
  }
}

export function errorBody(error: ProtocolError): Record<string, unknown> {
  return {
    protocol_version: 1,
    ...(error.binding.serverInstanceId
      ? { server_instance_id: error.binding.serverInstanceId }
      : {}),
    ...(error.binding.teamId ? { team_id: error.binding.teamId } : {}),
    error: {
      code: error.code,
      message: error.message,
      details: error.details,
    },
  };
}
