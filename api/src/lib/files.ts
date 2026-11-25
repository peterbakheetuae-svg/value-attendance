/**
 * File storage (R2 + migration 091). One place decides where a new file's bytes go and how stored bytes are read back.
 *
 * - R2 is used only when BOTH are true: the R2_* variables are set on the API host AND migration 091 is installed.
 *   Otherwise the caller keeps the bytes in its own bytea column exactly as before (nothing changes for old rows).
 * - A file is written ONLY by the server, to a server-made key (<env>/<category>/<yyyy>/<mm>/<uuid>), never overwriting.
 *   Lifecycle (enforced by 091's triggers): pending → stored (object written) → verified (re-read: size + SHA-256 match)
 *   → the business row links it (ref_count 1, retention class). A failed write leaves an 'orphan' record, never a link.
 * - Reads go through the API (the caller has already checked the user's permission on the business row); the bytes are
 *   integrity-checked against the recorded SHA-256. No public or long-lived URL is ever produced.
 * - Nothing here deletes or purges an object. Purging is a separate, evidence-gated procedure (091), not automated.
 */
import { randomUUID } from 'node:crypto';
import type { Q } from '../db.ts';
import { one } from '../db.ts';
import { AppError } from '../http/errors.ts';
import { R2Client, R2Error, r2ConfigFromEnv, sha256Hex } from './r2.ts';

export type FileCategory =
  | 'employee_photo' | 'employee_document' | 'attendance_selfie' | 'advance_attachment' | 'receipt_attachment'
  | 'expense_attachment' | 'cash_attachment' | 'adjustment_attachment' | 'unit_sale_attachment' | 'lead_attachment'
  | 'unit_file' | 'marketing_company_file' | 'project_image' | 'developer_image' | 'listing_photo' | 'company_logo';

const ALLOWED_MIME = new Set([
  'image/jpeg', 'image/png', 'image/webp', 'application/pdf', 'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
]);
const MAX_BYTES = 20 * 1024 * 1024;

let client: R2Client | null | undefined;
let bucket = '';
/** test hook: inject a client (or null to force Postgres storage); undefined = read the environment again */
export function setFileStorageForTests(c: R2Client | null | undefined, bucketName = 'valunivo-files') {
  client = c; bucket = bucketName; installed = undefined;
}
function r2(): R2Client | null {
  if (client === undefined) {
    const cfg = r2ConfigFromEnv();
    client = cfg ? new R2Client(cfg) : null;
    bucket = cfg?.bucket ?? '';
  }
  return client;
}

let installed: boolean | undefined;
async function schemaReady(q: Q): Promise<boolean> {
  if (installed === undefined) {
    installed = !!(await one(q, `SELECT to_regclass('public.file_objects') IS NOT NULL AS ok`))?.ok;
  }
  return installed;
}

/** true when migration 091 (file references) is installed — for list flags that must also count R2-stored files */
export async function fileSchemaInstalled(q: Q): Promise<boolean> { return schemaReady(q); }

/** true when new files go to R2 (both the credentials and migration 091 are present) */
export async function r2Enabled(q: Q): Promise<boolean> {
  return !!r2() && (await schemaReady(q));
}

const envPrefix = () => (process.env.VERCEL_ENV === 'production' || process.env.FILES_ENV === 'prod' ? 'prod' : 'staging');

/**
 * Stores bytes the caller has ALREADY validated (type by content, size, permission). Returns the file id to put in the
 * row's <col>_file_id, or null when R2 is not in use (then the caller stores the bytes in its bytea column as before).
 * Runs outside the caller's transaction on purpose: the object exists before any row can point at it.
 */
export async function storeFile(db: Q, f: {
  category: FileCategory; bytes: Buffer; mime: string; name: string; createdBy: string | null;
}): Promise<string | null> {
  if (!(await r2Enabled(db))) return null;
  const c = r2()!;
  if (!ALLOWED_MIME.has(f.mime)) throw new AppError('validation_failed', 'نوع الملف مش مسموح', { field: 'data' });
  if (f.bytes.length < 1 || f.bytes.length > MAX_BYTES) throw new AppError('validation_failed', 'حجم الملف مش مسموح', { field: 'data' });
  if (!contentMatches(f.bytes, f.mime)) throw new AppError('validation_failed', 'محتوى الملف مش مطابق لنوعه', { field: 'data' });
  const sha = sha256Hex(f.bytes);
  const now = new Date();
  const key = `${envPrefix()}/${f.category}/${now.getUTCFullYear()}/${String(now.getUTCMonth() + 1).padStart(2, '0')}/${randomUUID()}`;
  const name = (f.name || 'file').replace(/[\u0000-\u001f]/g, '').slice(0, 200) || 'file';
  const rec = await one(db, `INSERT INTO file_objects (client_ref, bucket, object_key, category, original_name, mime, size_bytes,
      sha256, upload_expires_at, created_by) VALUES ($1,$2,$3,$4,$5,$6,$7,$8, now() + interval '10 minutes', $9) RETURNING id`,
    [randomUUID(), bucket, key, f.category, name, f.mime, f.bytes.length, sha, f.createdBy]);
  const id = String(rec!.id);
  try {
    await c.put(key, new Uint8Array(f.bytes.buffer, f.bytes.byteOffset, f.bytes.byteLength), f.mime, sha);
  } catch (e) {
    // the object may or may not exist: the record says 'orphan' (never linkable); the reconciler settles it later
    await db.query(`UPDATE file_objects SET status = 'orphan' WHERE id = $1 AND status = 'pending'`, [id]).catch(() => undefined);
    throw storageError(e);
  }
  await db.query(`UPDATE file_objects SET status = 'stored' WHERE id = $1`, [id]);
  // verify what R2 actually holds before anything may link it
  const h = await c.head(key).catch((e) => { throw storageError(e); });
  if (!h || h.size !== f.bytes.length || (h.sha256 && h.sha256 !== sha)) {
    await db.query(`UPDATE file_objects SET status = 'orphan' WHERE id = $1 AND status = 'stored'`, [id]).catch(() => undefined);
    throw new AppError('service_unavailable', 'الملف ما اتحفظش صح — جرّب تاني', { reason: 'storage_verify_failed' });
  }
  await db.query(`UPDATE file_objects SET status = 'verified', verified_size = $2, verified_sha256 = $3, verified_at = now()
                   WHERE id = $1`, [id, h.size, sha]);
  return id;
}

/** Bytes of a row's file: from R2 when the row has a file id, otherwise its bytea column (legacy / Postgres storage). */
export async function readFileBytes(db: Q, inline: Buffer | Uint8Array | null | undefined, fileId: string | null | undefined): Promise<Buffer> {
  if (!fileId) {
    if (inline == null) throw new AppError('not_found', 'Not found');
    return Buffer.from(inline);
  }
  const f = await one(db, `SELECT object_key, sha256, status FROM file_objects WHERE id = $1`, [fileId]);
  if (!f || !['verified', 'detached'].includes(f.status)) throw new AppError('not_found', 'Not found');
  const c = r2();
  if (!c) throw new AppError('service_unavailable', 'تخزين الملفات مش متاح دلوقتي — جرّب بعد شوية', { reason: 'storage_not_configured' });
  const got = await c.get(f.object_key, f.sha256).catch((e) => { throw storageError(e); });
  if (!got) throw new AppError('service_unavailable', 'الملف مش موجود في التخزين — بلّغ الإدارة', { reason: 'storage_object_missing' });
  return Buffer.from(got.data);
}

function storageError(e: unknown): AppError {
  if (e instanceof AppError) return e;
  const code = e instanceof R2Error ? e.code ?? String(e.status) : 'unknown';
  // never the URL, key, or credentials in the error or the logs
  console.error(`[files] storage error: ${code}`);
  return new AppError('service_unavailable', 'تخزين الملفات مش متاح دلوقتي — جرّب بعد شوية', { reason: 'storage_unavailable' });
}


export { withFile } from './files-sql.ts';

/** the file's first bytes must be what its MIME type says (never trust a declared type alone) */
export function contentMatches(b: Buffer, mime: string): boolean {
  const s = (i: number, n: number) => b.subarray(i, i + n).toString('latin1');
  switch (mime) {
    case 'image/jpeg': return b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;
    case 'image/png': return s(0, 8) === '\x89PNG\r\n\x1a\n';
    case 'image/webp': return s(0, 4) === 'RIFF' && s(8, 4) === 'WEBP';
    case 'application/pdf': return s(0, 5) === '%PDF-';
    case 'application/msword': return b.subarray(0, 8).equals(Buffer.from([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]));
    case 'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
    case 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': return s(0, 4) === 'PK\x03\x04';
    default: return false;
  }
}

/** the MIME type a file's own bytes say it is (null when it is none of the accepted types) */
export function sniffMime(b: Buffer): string | null {
  for (const m of ['image/jpeg', 'image/png', 'image/webp', 'application/pdf']) if (contentMatches(b, m)) return m;
  return null;
}

/** storeFile for an image-or-PDF attachment whose type the route does not state: the bytes decide (null type → Postgres) */
export async function storeAttachment(db: Q, category: FileCategory, bytes: Buffer | null, name: string, createdBy: string | null) {
  if (!bytes) return null;
  const mime = sniffMime(bytes);
  if (!mime) return null;   // an odd legacy format stays in Postgres exactly as the route accepted it
  return storeFile(db, { category, bytes, mime, name, createdBy });
}
