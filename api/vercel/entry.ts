/**
 * Vercel Function entry (free Hobby plan, no card). Serves every path of the API.
 * DATABASE_URL and the other secrets come from the Vercel project's environment variables — never from Git.
 */
import type { IncomingMessage, ServerResponse } from 'node:http';
import { createDb, type Db } from '../src/db.ts';
import { buildRouter } from '../src/app.ts';
import { createHandler } from '../src/http/router.ts';
import { systemClock } from '../src/lib/time.ts';

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
const direct = process.env.DATABASE_URL;
const url = pooledUrl(direct);

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

const handler = url
  ? createHandler(buildRouter({ db: resilientDb(url, direct!), clock: systemClock }), { corsOrigins, log })
  : async (_req: IncomingMessage, res: ServerResponse) => {
      res.writeHead(503, { 'Content-Type': 'application/json' })
        .end(JSON.stringify({ error: { code: 'not_configured', message: 'DATABASE_URL is not set' } }));
    };

export default handler;
