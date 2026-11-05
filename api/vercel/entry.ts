/**
 * Vercel Function entry (free Hobby plan, no card). Serves every path of the API.
 * DATABASE_URL and the other secrets come from the Vercel project's environment variables — never from Git.
 */
import type { IncomingMessage, ServerResponse } from 'node:http';
import { createDb } from '../src/db.ts';
import { buildRouter } from '../src/app.ts';
import { createHandler } from '../src/http/router.ts';
import { systemClock } from '../src/lib/time.ts';

const url = process.env.DATABASE_URL;
const corsOrigins = (process.env.CORS_ORIGINS ?? 'https://peterbakheetuae-svg.github.io').split(',').map((s) => s.trim()).filter(Boolean);
const log = (o: object) => console.log(JSON.stringify({ t: new Date().toISOString(), ...o }));

const handler = url
  ? createHandler(buildRouter({ db: createDb(url, 3), clock: systemClock }), { corsOrigins, log })
  : async (_req: IncomingMessage, res: ServerResponse) => {
      res.writeHead(503, { 'Content-Type': 'application/json' })
        .end(JSON.stringify({ error: { code: 'not_configured', message: 'DATABASE_URL is not set' } }));
    };

export default handler;
