/**
 * Throwaway CPU probe (no database, no secrets): measures, on real Cloudflare Workers, the CPU cost of the exact
 * production password check (src/auth/password.ts, unchanged parameters). Deployed and deleted by
 * .github/workflows/cloudflare-staging.yml; CPU figures come from Cloudflare's own analytics, not from this code
 * (inside Workers the clock does not advance during pure computation).
 *
 * The password below is a public test value, not any real account's; the hash uses the production parameters.
 */
import { verifyPassword } from '../src/auth/password.ts';

const PROBE_PASSWORD = 'probe-only--not-a-real-password';
const PROBE_HASH = 'scrypt$16384$8$1$sRpJhHCpxUTbrclUb6OIww==$KQLlBKBC/V2f9QqLLyaPBLzMj7hNgNSGnfsK+a+ARvM=';

export default {
  async fetch(req: Request): Promise<Response> {
    const path = new URL(req.url).pathname;
    if (path === '/noop') return Response.json({ ok: true });
    if (path === '/verify') return Response.json({ ok: await verifyPassword(PROBE_PASSWORD, PROBE_HASH) });
    return new Response('not found', { status: 404 });
  },
};
