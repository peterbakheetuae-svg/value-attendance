/**
 * Controlled real-bucket check of the R2 credentials (run by the owner or a protected CI job — never with production data).
 *
 *   R2_ACCOUNT_ID=… R2_ACCESS_KEY_ID=… R2_SECRET_ACCESS_KEY=… R2_BUCKET=valunivo-files \
 *     node --experimental-transform-types --no-warnings scripts/r2-smoke.ts
 *
 * Uses ONLY synthetic bytes under the key prefix `staging/smoke/<yyyy>/<mm>/<uuid>` (never prod/, never a business file),
 * prints PASS/FAIL per check and never prints a credential, a signature or a full presigned URL.
 * Leaves nothing behind: every object it writes is deleted at the end (and the deletion is verified).
 */
import { randomBytes, randomUUID } from 'node:crypto';
import { R2Client, R2Error, r2ConfigFromEnv, sha256Hex } from '../src/lib/r2.ts';

const cfg = r2ConfigFromEnv();
if (!cfg) { console.error('R2_* variables are not set'); process.exit(2); }
const c = new R2Client(cfg);
const now = new Date();
const key = `staging/smoke/${now.getUTCFullYear()}/${String(now.getUTCMonth() + 1).padStart(2, '0')}/${randomUUID()}`;
// a synthetic PDF-looking payload: random bytes after a PDF header — no real document
const data = Buffer.concat([Buffer.from('%PDF-1.4 valunivo r2 smoke\n'), randomBytes(4096)]);
const sha = sha256Hex(data);
let failed = 0;
const check = async (name: string, f: () => Promise<boolean>) => {
  try { const ok = await f(); console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}`); if (!ok) failed++; }
  catch (e) { failed++; console.log(`FAIL  ${name} (${e instanceof R2Error ? `${e.status} ${e.code ?? ''}` : (e as Error).name})`); }
};
const status = async (url: string, init?: RequestInit) => (await fetch(url, init)).status;
const host = `${cfg.accountId}.${cfg.jurisdiction ? cfg.jurisdiction + '.' : ''}r2.cloudflarestorage.com`;

await check('upload (signed PUT, no-overwrite, sha256 metadata)', async () => { await c.put(key, data, 'application/pdf', sha); return true; });
await check('HEAD: size and sha256 metadata as uploaded', async () => {
  const h = await c.head(key); return !!h && h.size === data.length && h.sha256 === sha;
});
await check('download is byte-identical (integrity-checked GET)', async () => {
  const g = await c.get(key, sha); return !!g && Buffer.from(g.data).equals(data);
});
await check('second upload to the same key is refused (412), the object is unchanged', async () => {
  try { await c.put(key, Buffer.concat([data, Buffer.from('x')]), 'application/pdf', sha256Hex(Buffer.concat([data, Buffer.from('x')]))); return false; }
  catch (e) { return e instanceof R2Error && e.status === 412 && (await c.head(key))?.sha256 === sha; }
});
await check('anonymous GET of the object is refused (bucket is private)', async () => {
  const s = await status(`https://${host}/${cfg.bucket}/${key}`); return s === 400 || s === 401 || s === 403;
});
await check('presigned GET (60 s) works', async () => {
  const r = await fetch(c.presignGet(key, 'smoke.pdf', 60)); return r.status === 200 && Buffer.from(await r.arrayBuffer()).equals(data);
});
await check('presigned GET with a tampered signature is refused', async () => {
  const u = new URL(c.presignGet(key, 'smoke.pdf', 60));
  const sig = u.searchParams.get('X-Amz-Signature')!;
  u.searchParams.set('X-Amz-Signature', (sig[0] === 'a' ? 'b' : 'a') + sig.slice(1));
  return (await status(u.toString())) === 403;
});
await check('the token cannot reach another bucket (least privilege)', async () => {
  const other = new R2Client({ ...cfg, bucket: `${cfg.bucket}-not-granted` });
  try { await other.head(key); return false; } catch (e) { return e instanceof R2Error && (e.status === 403 || e.status === 404); }
});
await check('cleanup: the smoke object is deleted and gone', async () => { await c.delete(key); return (await c.head(key)) === null; });

console.log(failed ? `\n${failed} check(s) FAILED` : '\nall checks passed');
process.exit(failed ? 1 : 0);
