/**
 * Vercel Function entry (free Hobby plan, no card). Serves every path of the API.
 * DATABASE_URL and the other secrets come from the Vercel project's environment variables — never from Git.
 *
 * C1 (2026-11-24): which deployment may run the API is decided FIRST, from Vercel's own project identity
 * (scripts/deployment-guard.mjs). Only the guard and node:http types are imported statically; the database layer, the
 * router and every module (sweeps, push, e-mail, backups, webhooks) are loaded only after the guard says «serve» —
 * a retired or unidentified deployment never even loads them.
 */
import type { IncomingMessage, ServerResponse } from 'node:http';
import type { Db } from '../src/db.ts';
// @ts-ignore — plain .mjs shared with the build script
import { combinedStatus } from '../scripts/deployment-guard.mjs';

// the build's verdict (baked by scripts/vercel-build.mjs) AND this instance's own — either one not «serve» refuses
declare const __VA_BUILD_STATUS__: string | undefined;
const built = typeof __VA_BUILD_STATUS__ === 'undefined' ? undefined : __VA_BUILD_STATUS__;
const status: 'retired' | 'serve' | 'unverified' = combinedStatus(built, process.env);

type Handler = (req: IncomingMessage, res: ServerResponse) => unknown;
const refuse = (code: number, error: object): Handler => async (_req, res) => {
  res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }).end(JSON.stringify({ error }));
};

/**
 * Neon's connection pooler (same database, host name with "-pooler"): opening a connection through it is much
 * faster than a direct one, which matters because every cold start of the function opens new connections.
 * Only plain transaction-scoped features are used by the API, which the pooler supports. VA_DB_DIRECT=1 turns it off.
 */
export function pooledUrl(raw: string | undefined): string | undefined {
  if (!raw || process.env.VA_DB_DIRECT === '1') return raw;
  try {
    const u = new URL(raw);
    const [first, ...rest] = u.hostname.split('.');
    if (!u.hostname.endsWith('.neon.tech') || first.endsWith('-pooler')) return raw;
    u.hostname = [`${first}-pooler`, ...rest].join('.');
    return u.toString();
  } catch {
    return raw;
  }
}

/** the real API: loaded once per instance, only when the guard allows it */
async function loadApi(): Promise<Handler> {
  const [{ createDb }, { buildRouter }, { createHandler }, { systemClock }] = await Promise.all([
    import('../src/db.ts'), import('../src/app.ts'), import('../src/http/router.ts'), import('../src/lib/time.ts'),
  ]);
  const direct = process.env.DATABASE_URL;
  const url = pooledUrl(direct);
  if (!url) return refuse(503, { code: 'not_configured', message: 'DATABASE_URL is not set' });

  /** Uses the pooler; if it cannot be reached at all, falls back to the direct connection for the rest of this instance. */
  function resilientDb(pooled: string, plain: string): Db {
    let db = createDb(pooled, 3);
    let switched = pooled === plain;
    const unreachable = (e: any) => !switched && /ENOTFOUND|ECONNREFUSED|EAI_AGAIN|ETIMEDOUT|endpoint|pooler/i.test(`${e?.code ?? ''} ${e?.message ?? ''}`);
    const fallback = () => { switched = true; const old = db; db = createDb(plain, 3); old.end().catch(() => {}); };
    return {
      async query(t, v) {
        try { return await db.query(t, v); } catch (e) { if (!unreachable(e)) throw e; fallback(); return db.query(t, v); }
      },
      async tx(fn) {
        try { return await db.tx(fn); } catch (e) { if (!unreachable(e)) throw e; fallback(); return db.tx(fn); }
      },
      end: () => db.end(),
    };
  }
  // browser origins allowed to call the API: GitHub Pages (fallback) and the Hostinger copy at jaurea.com/valunivo/,
  // plus anything listed in CORS_ORIGINS
  const corsOrigins = [...new Set([
    'https://peterbakheetuae-svg.github.io', 'https://jaurea.com', 'https://www.jaurea.com',
    ...(process.env.CORS_ORIGINS ?? '').split(','),
  ].map((s) => s.trim()).filter(Boolean))];
  const log = (o: object) => console.log(JSON.stringify({ t: new Date().toISOString(), ...o }));
  return createHandler(buildRouter({ db: resilientDb(url, direct!), clock: systemClock }), { corsOrigins, log });
}

let api: Promise<Handler> | null = null;
const handler: Handler = status === 'retired'
  ? refuse(410, { code: 'gone', message: 'This deployment is retired. The API is at valunivo.vercel.app' })
  : status === 'unverified'
    ? refuse(503, { code: 'deployment_unverified', message: 'This deployment could not be identified as the VALUNIVO API' })
    : async (req, res) => {
        api ??= loadApi().catch((e) => { api = null; throw e; });
        return (await api)(req, res);
      };

export default handler;
