/**
 * Cloudflare Workers entry (migration candidate — staging only until the cutover is approved).
 *
 * The same router, modules and business logic as the Vercel entry (vercel/entry.ts); only the hosting glue differs:
 *  - The database is reached through a Hyperdrive binding (env.HYPERDRIVE), which keeps a warm connection pool next to
 *    Neon. Its origin credential is the least-privilege runtime role, configured in the Cloudflare dashboard — never
 *    in Git. DATABASE_URL (a Worker secret) is accepted as a fallback for a staging Worker without Hyperdrive.
 *  - Workers may not reuse a socket opened by one request in another request, so each request gets its own small
 *    connection pool (Hyperdrive makes opening it cheap), closed after the response with ctx.waitUntil.
 *    The router is built once; it reaches the request's pool through AsyncLocalStorage.
 *  - Secrets / vars (BREVO_API_KEY, FCM_SERVICE_ACCOUNT, BACKUP_TOKEN, VAPID_PRIVATE_KEY, SECRETS_KEY, MAIL_FROM, …)
 *    are Worker secrets / vars; with nodejs_compat they appear in process.env, so the existing code reads them unchanged.
 *
 * No build-time or run-time migrations run here: schema changes stay a separate, explicitly approved step.
 */
import { AsyncLocalStorage } from 'node:async_hooks';
import { createDb, type Db } from '../src/db.ts';
import { buildRouter } from '../src/app.ts';
import { createFetchHandler } from '../src/http/router.ts';
import { systemClock } from '../src/lib/time.ts';

interface Env {
  HYPERDRIVE?: { connectionString: string };
  DATABASE_URL?: string;
  CORS_ORIGINS?: string;
}
interface ExecutionContext {
  waitUntil(p: Promise<unknown>): void;
}

/** at most 3 sockets per request: Workers allow 6 simultaneous outgoing connections per request */
const PER_REQUEST_CONNECTIONS = 3;

const current = new AsyncLocalStorage<Db>();
function requestDb(): Db {
  const db = current.getStore();
  if (!db) throw new Error('no database for this request');
  return db;
}
/** the Db the router holds: every call goes to the pool of the request it runs in */
const db: Db = {
  query: (t, v) => requestDb().query(t, v),
  tx: (fn) => requestDb().tx(fn),
  end: async () => { /* per-request pools are closed by the fetch handler */ },
};

const log = (o: object) => console.log(JSON.stringify({ t: new Date().toISOString(), ...o }));

let handler: ((req: Request) => Promise<Response>) | null = null;
function getHandler(env: Env) {
  if (!handler) {
    // same browser origins as the Vercel entry, plus anything listed in CORS_ORIGINS
    const corsOrigins = [...new Set([
      'https://peterbakheetuae-svg.github.io', 'https://jaurea.com', 'https://www.jaurea.com',
      ...(env.CORS_ORIGINS ?? '').split(','),
    ].map((s) => s.trim()).filter(Boolean))];
    handler = createFetchHandler(buildRouter({ db, clock: systemClock }), { corsOrigins, log });
  }
  return handler;
}

const notConfigured = () => new Response(JSON.stringify({ error: { code: 'not_configured', message: 'Database is not configured' } }),
  { status: 503, headers: { 'Content-Type': 'application/json' } });

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = env.HYPERDRIVE?.connectionString ?? env.DATABASE_URL;
    if (!url) return notConfigured();
    const h = getHandler(env);
    const pool = createDb(url, PER_REQUEST_CONNECTIONS);
    try {
      return await current.run(pool, () => h(req));
    } finally {
      ctx.waitUntil(pool.end().catch(() => {}));
    }
  },
};
