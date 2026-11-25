export type ErrorCode =
  | 'bad_request' | 'validation_failed' | 'unauthenticated' | 'forbidden' | 'not_found'
  | 'conflict' | 'locked' | 'unprocessable' | 'payload_too_large' | 'rate_limited' | 'internal_error' | 'service_unavailable';

const STATUS: Record<ErrorCode, number> = {
  bad_request: 400, validation_failed: 400, unauthenticated: 401, forbidden: 403,
  not_found: 404, conflict: 409, locked: 423, unprocessable: 422,
  payload_too_large: 413, rate_limited: 429, internal_error: 500, service_unavailable: 503,
};

export class AppError extends Error {
  readonly status: number;
  constructor(readonly code: ErrorCode, message: string, readonly details?: unknown) {
    super(message);
    this.status = STATUS[code];
  }
}

export const forbidden = (m = 'You do not have permission for this action') => new AppError('forbidden', m);
export const notFound = (m = 'Not found') => new AppError('not_found', m);
export const conflict = (m: string) => new AppError('conflict', m);
export const invalid = (m: string, details?: unknown) => new AppError('validation_failed', m, details);
export const unprocessable = (m: string) => new AppError('unprocessable', m);

/** Map database integrity errors to API errors without leaking SQL detail. */
export function fromDbError(e: any): AppError | null {
  switch (e?.code) {
    case '23505': return new AppError('conflict', 'Duplicate record');
    case '23503': return new AppError('unprocessable', 'Referenced record does not exist');
    case '23514': return new AppError('unprocessable', cleanMsg(e.message) ?? 'Rule violated');
    case '23502': return new AppError('validation_failed', 'Missing required field');
    // our own triggers RAISE this code with a readable message; a real database privilege error is not shown as-is
    case '42501': return new AppError('conflict', /^permission denied for /.test(String(e?.message)) ? 'Operation not allowed' : (cleanMsg(e.message) ?? 'Operation not allowed'));
    // 22021 / 22P05: text the database cannot store (e.g. a NUL character) — the caller's input, not a server fault
    case '22P02': case '22007': case '22008': case '22003': case '22021': case '22P05':
      return new AppError('validation_failed', 'Invalid value');
    default: return null;
  }
}

function cleanMsg(m: unknown): string | undefined {
  if (typeof m !== 'string') return undefined;
  // only our own RAISE messages are human-readable; constraint names are not
  return /violates check constraint/.test(m) ? 'Rule violated' : m;
}
