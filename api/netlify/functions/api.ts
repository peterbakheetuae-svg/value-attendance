/**
 * Netlify Functions entry (free plan, no card). Serves every path of the API site.
 * DATABASE_URL and CORS_ORIGINS come from the Netlify site's environment variables — never from Git.
 */
import { createDb } from '../../src/db.ts';
import { buildRouter } from '../../src/app.ts';
import { createFetchHandler } from '../../src/http/router.ts';
import { systemClock } from '../../src/lib/time.ts';

const url = process.env.DATABASE_URL;
const corsOrigins = (process.env.CORS_ORIGINS ?? 'https://peterbakheetuae-svg.github.io').split(',').map((s) => s.trim()).filter(Boolean);
const log = (o: object) => console.log(JSON.stringify({ t: new Date().toISOString(), ...o }));

const handler = url
  ? createFetchHandler(buildRouter({ db: createDb(url, 3), clock: systemClock }), { corsOrigins, log })
  : async () => new Response(JSON.stringify({ error: { code: 'not_configured', message: 'DATABASE_URL is not set' } }), { status: 503, headers: { 'Content-Type': 'application/json' } });

export default handler;
export const config = { path: '/*' };
