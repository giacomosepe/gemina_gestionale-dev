// One error format for every domain function: { ok: false, error: { code, message, details? } }.
// `message` is Italian and safe to show to the person; the real cause of an unexpected error goes to the log, never to the response.

export type ErrorCode =
  | "unauthorized" | "forbidden" | "not_found" | "invalid_input" | "conflict" | "method_not_allowed" | "unknown_action" | "internal";

export const STATUS: Record<ErrorCode, number> = {
  unauthorized: 401, forbidden: 403, not_found: 404, invalid_input: 400, conflict: 409, method_not_allowed: 405, unknown_action: 404, internal: 500,
};

export const MESSAGE_IT: Record<ErrorCode, string> = {
  unauthorized: "Accesso non autorizzato: effettua di nuovo l'accesso.",
  forbidden: "Non hai i permessi per questa operazione.",
  not_found: "Elemento non trovato.",
  invalid_input: "I dati inviati non sono validi.",
  conflict: "L'operazione è in conflitto con lo stato attuale dei dati.",
  method_not_allowed: "Metodo non consentito.",
  unknown_action: "Operazione sconosciuta.",
  internal: "Si è verificato un errore. Riprova tra poco; se continua, avvisa Giacomo.",
};

export class AppError extends Error {
  constructor(public code: ErrorCode, message?: string, public details?: unknown) {
    super(message ?? MESSAGE_IT[code]);
    this.name = "AppError";
  }
}

// What a database error means for the person. Row-level security and missing grants arrive as 42501; the rest is a data problem.
export function fromDatabaseError(e: unknown): AppError | null {
  const code = (e as { code?: string } | null)?.code;
  if (typeof code !== "string") return null;
  if (code === "42501") return new AppError("forbidden");
  if (code === "23505" || code === "23503" || code === "40001" || code === "40P01") return new AppError("conflict");
  if (code === "22P02" || code === "23502" || code === "23514" || code === "22007" || code === "22003") return new AppError("invalid_input");
  return null;
}

export function toAppError(e: unknown): AppError {
  if (e instanceof AppError) return e;
  return fromDatabaseError(e) ?? new AppError("internal");
}

export function errorBody(e: AppError) {
  return { ok: false as const, error: { code: e.code, message: e.message, ...(e.details === undefined ? {} : { details: e.details }) } };
}
