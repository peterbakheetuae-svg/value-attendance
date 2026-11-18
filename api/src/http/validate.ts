import { invalid } from './errors.ts';

/** Tiny declarative validators — explicit and dependency-free. */
type Obj = Record<string, unknown>;

export function obj(body: unknown): Obj {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw invalid('Body must be an object');
  return body as Obj;
}

export function str(o: Obj, k: string, opts: { min?: number; max?: number; optional?: boolean; pattern?: RegExp } = {}): string | undefined {
  const v = o[k];
  if (v === undefined || v === null || v === '') {
    if (opts.optional) return undefined;
    throw invalid(`${k} is required`, { field: k });
  }
  if (typeof v !== 'string') throw invalid(`${k} must be text`, { field: k });
  const t = v.trim();
  if (opts.min !== undefined && t.length < opts.min) throw invalid(`${k} is too short`, { field: k });
  if (t.length > (opts.max ?? 2000)) throw invalid(`${k} is too long`, { field: k });
  if (opts.pattern && !opts.pattern.test(t)) throw invalid(`${k} has an invalid format`, { field: k });
  return t;
}
export const reqStr = (o: Obj, k: string, opts: { min?: number; max?: number; pattern?: RegExp } = {}) =>
  str(o, k, opts) as string;

export function num(o: Obj, k: string, opts: { min?: number; max?: number; optional?: boolean; int?: boolean } = {}): number | undefined {
  const v = o[k];
  if (v === undefined || v === null || v === '') {
    if (opts.optional) return undefined;
    throw invalid(`${k} is required`, { field: k });
  }
  if (typeof v !== 'number' || !Number.isFinite(v)) throw invalid(`${k} must be a number`, { field: k });
  if (opts.int && !Number.isInteger(v)) throw invalid(`${k} must be a whole number`, { field: k });
  if (opts.min !== undefined && v < opts.min) throw invalid(`${k} is below the minimum`, { field: k });
  if (opts.max !== undefined && v > opts.max) throw invalid(`${k} is above the maximum`, { field: k });
  return v;
}

export function bool(o: Obj, k: string, optional = true): boolean | undefined {
  const v = o[k];
  if (v === undefined || v === null) {
    if (optional) return undefined;
    throw invalid(`${k} is required`, { field: k });
  }
  if (typeof v !== 'boolean') throw invalid(`${k} must be true/false`, { field: k });
  return v;
}

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const TIME = /^([01]\d|2[0-3]):[0-5]\d$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function date(o: Obj, k: string, optional = false): string | undefined {
  const v = str(o, k, { optional });
  if (v === undefined) return undefined;
  if (!DATE.test(v) || Number.isNaN(Date.parse(v + 'T00:00:00Z'))) throw invalid(`${k} must be YYYY-MM-DD`, { field: k });
  return v;
}
export function time(o: Obj, k: string, optional = false): string | undefined {
  const v = str(o, k, { optional });
  if (v === undefined) return undefined;
  if (!TIME.test(v)) throw invalid(`${k} must be HH:MM`, { field: k });
  return v;
}
export function uuid(o: Obj, k: string, optional = false): string | undefined {
  const v = str(o, k, { optional });
  if (v === undefined) return undefined;
  if (!UUID.test(v)) throw invalid(`${k} must be an id`, { field: k });
  return v;
}
export function isUuid(v: string) { return UUID.test(v); }
export function oneOf<T extends string>(o: Obj, k: string, values: readonly T[], optional = false): T | undefined {
  const v = str(o, k, { optional });
  if (v === undefined) return undefined;
  if (!values.includes(v as T)) throw invalid(`${k} must be one of ${values.join(', ')}`, { field: k });
  return v as T;
}

/** 'YYYY-MM' → first day of month 'YYYY-MM-01'. */
export function monthParam(v: string | null, field = 'month'): string {
  if (!v || !/^\d{4}-(0[1-9]|1[0-2])$/.test(v)) throw invalid(`${field} must be YYYY-MM`, { field });
  return `${v}-01`;
}

/** What a file really is, by its first bytes (never by the name / the mime the client sent): a photo, or null. */
export function imageType(buf: Buffer): string | null {
  const s = buf.subarray(0, 12);
  if (s[0] === 0xff && s[1] === 0xd8 && s[2] === 0xff) return 'image/jpeg';
  if (s.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';
  if (s.subarray(0, 4).toString('latin1') === 'RIFF' && s.subarray(8, 12).toString('latin1') === 'WEBP') return 'image/webp';
  if (s.subarray(0, 4).toString('latin1') === 'GIF8') return 'image/gif';
  if (s.subarray(4, 8).toString('latin1') === 'ftyp' && /^(heic|heix|mif1|msf1|hevc)$/.test(s.subarray(8, 12).toString('latin1'))) return 'image/heic';
  return null;
}

/** an attachment that must be a photo: [field] base64 (a data: prefix is allowed), at most [max] bytes */
export function imageAttachment(v: unknown, field: string, max: number, msg = 'The attachment must be a photo'): Buffer {
  if (typeof v !== 'string') throw invalid(`${field} must be base64`, { field });
  const raw = v.replace(/^data:[^,]*,/, '');
  if (!/^[A-Za-z0-9+/=\s]*$/.test(raw)) throw invalid(`${field} must be base64`, { field });
  const buf = Buffer.from(raw, 'base64');
  if (buf.length > max) throw invalid('Attachment is too large', { field });
  if (!buf.length || !imageType(buf)) throw invalid(msg, { field });
  return buf;
}
