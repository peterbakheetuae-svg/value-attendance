import { createServer } from 'node:http';
import { createDb } from './db.ts';
import { buildRouter } from './app.ts';
import { createHandler } from './http/router.ts';
import { systemClock } from './lib/time.ts';

const url = process.env.DATABASE_URL;
if (!url) { console.error('DATABASE_URL is required'); process.exit(2); }
const port = Number(process.env.PORT ?? 8095);
const host = process.env.HOST ?? '127.0.0.1';
const corsOrigins = (process.env.CORS_ORIGINS ?? 'http://localhost:8096,http://127.0.0.1:8096').split(',').map((s) => s.trim()).filter(Boolean);

const db = createDb(url);
const router = buildRouter({ db, clock: systemClock });
const log = (o: object) => console.log(JSON.stringify({ t: new Date().toISOString(), ...o }));
createServer(createHandler(router, { corsOrigins, log })).listen(port, host, () => {
  log({ level: 'info', msg: `JPH Real Estate HR API on http://${host}:${port}`, routes: router.list().length });
});
