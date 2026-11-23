import { createHmac, timingSafeEqual } from 'node:crypto';

/**
 * A production API: a Vercel production deployment, a Netlify production context, or NODE_ENV=production.
 * Local runs, CI and the test suite are none of these.
 */
export function isProductionRuntime(env: Record<string, string | undefined> = process.env): boolean {
  return env.VERCEL_ENV === 'production' || env.CONTEXT === 'production' || env.NODE_ENV === 'production';
}

/** the Meta app secrets configured on the host (comma-separated, one per Meta app) */
export function metaAppSecrets(env: Record<string, string | undefined> = process.env): string[] {
  return (env.META_APP_SECRETS ?? '').split(',').map((x) => x.trim()).filter(Boolean);
}

/**
 * VA-09: Meta signs every delivery with the app secret (X-Hub-Signature-256 = sha256=HMAC(raw body)).
 *  - secrets configured: only a delivery signed with one of them is accepted (missing / malformed / wrong / modified → false)
 *  - no secrets in PRODUCTION: refused — fail closed (2026-11-24; before, a missing configuration accepted everything)
 *  - no secrets outside production (a laptop, CI): accepted, as before, so local development keeps working
 */
export function metaSignatureOk(raw: Buffer | undefined, header: unknown, env: Record<string, string | undefined> = process.env): boolean {
  const secrets = metaAppSecrets(env);
  if (!secrets.length) return !isProductionRuntime(env);
  const h = typeof header === 'string' ? header.trim() : '';
  if (!/^sha256=[0-9a-f]{64}$/i.test(h) || !raw?.length) return false;
  const got = Buffer.from(h.slice(7).toLowerCase(), 'hex');
  return secrets.some((s) => {
    const want = createHmac('sha256', s).update(raw).digest();
    return want.length === got.length && timingSafeEqual(want, got);
  });
}
