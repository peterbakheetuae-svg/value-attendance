import { createServer, type Server } from 'node:http';
import { randomBytes } from 'node:crypto';
import pg from 'pg';
import { createDb, type Db } from '../src/db.ts';
import { migrate } from '../src/migrate-core.ts';
import { buildRouter } from '../src/app.ts';
import { createHandler } from '../src/http/router.ts';
import { hashPassword } from '../src/auth/password.ts';

/**
 * Every test file gets its own real PostgreSQL database, cloned from a migrated template.
 * TEST_PG_URL must point at a server where the user may CREATE DATABASE (never production).
 */
const ADMIN_URL = process.env.TEST_PG_URL ?? 'postgres://postgres:dev@127.0.0.1:5433/postgres';
import { readdirSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { MIGRATIONS_DIR } from '../src/migrate-core.ts';
// template name changes whenever a migration changes, so a stale template is never reused
const TEMPLATE = 'hr_tpl_' + createHash('sha256').update(readdirSync(MIGRATIONS_DIR).sort()
  .map((f) => f + readFileSync(join(MIGRATIONS_DIR, f), 'utf8')).join('|')).digest('hex').slice(0, 10);

async function admin<T>(fn: (c: InstanceType<typeof pg.Pool>) => Promise<T>): Promise<T> {
  const p = new pg.Pool({ connectionString: ADMIN_URL, max: 1 });
  try { return await fn(p); } finally { await p.end(); }
}

let templateReady: Promise<void> | null = null;
async function ensureTemplate() {
  templateReady ??= (async () => {
    const lockUrl = ADMIN_URL;
    const p = new pg.Pool({ connectionString: lockUrl, max: 1 });
    const c = await p.connect();
    try {
      await c.query(`SELECT pg_advisory_lock(424242)`);
      const exists = await c.query(`SELECT 1 FROM pg_database WHERE datname = $1`, [TEMPLATE]);
      if (!exists.rowCount) {
        await c.query(`CREATE DATABASE ${TEMPLATE}`);
        const u = new URL(ADMIN_URL); u.pathname = '/' + TEMPLATE;
        const db = createDb(u.toString());
        try {
          await migrate(db);
          // most suites create employees without files; the documents suite turns this back on
          await db.query(`UPDATE company_settings SET require_employee_documents = false`);
        } finally { await db.end(); }
      }
      await c.query(`SELECT pg_advisory_unlock(424242)`);
    } finally { c.release(); await p.end(); }
  })();
  return templateReady;
}

export interface Harness {
  db: Db; base: string; now: { value: Date }; server: Server; dbName: string;
  call: (token: string | null, method: string, path: string, body?: unknown) => Promise<{ status: number; body: any; headers: Headers; raw: Buffer }>;
  login: (identifier: string, password: string) => Promise<string>;
  close: () => Promise<void>;
}

export async function harness(startIso = '2026-03-10T08:00:00Z'): Promise<Harness> {
  await ensureTemplate();
  const dbName = 'hr_t_' + randomBytes(6).toString('hex');
  await admin((p) => p.query(`CREATE DATABASE ${dbName} TEMPLATE ${TEMPLATE}`));
  const u = new URL(ADMIN_URL); u.pathname = '/' + dbName;
  const db = createDb(u.toString());
  const now = { value: new Date(startIso) };
  const router = buildRouter({ db, clock: () => now.value });
  const server = createServer(createHandler(router, { corsOrigins: ['http://ok.test'], log: (o) => console.error(o) }));
  await new Promise<void>((res) => server.listen(0, '127.0.0.1', () => res()));
  const port = (server.address() as any).port;
  const base = `http://127.0.0.1:${port}`;
  const call = async (token: string | null, method: string, path: string, body?: unknown) => {
    const headers: Record<string, string> = {};
    if (token) headers.authorization = `Bearer ${token}`;
    if (body !== undefined) headers['content-type'] = 'application/json';
    const res = await fetch(base + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    const raw = Buffer.from(await res.arrayBuffer());
    let parsed: any = null;
    if ((res.headers.get('content-type') ?? '').includes('json')) parsed = JSON.parse(raw.toString('utf8'));
    return { status: res.status, body: parsed, headers: res.headers, raw };
  };
  const login = async (identifier: string, password: string) => {
    const r = await call(null, 'POST', '/auth/login', { identifier, password, deviceId: dev(identifier) });
    if (r.status !== 200) throw new Error(`login ${identifier} failed: ${r.status} ${JSON.stringify(r.body)}`);
    return r.body.token as string;
  };
  return {
    db, base, now, server, dbName, call, login,
    close: async () => {
      await new Promise<void>((res) => server.close(() => res()));
      await db.end();
      await admin((p) => p.query(`DROP DATABASE IF EXISTS ${dbName} WITH (FORCE)`));
    },
  };
}

export const PW = 'Passw0rd!x';
/** Stable fake device id per account (device binding is on by default). */
export const dev = (identifier: string) => `testdevice-${identifier.toUpperCase()}`.padEnd(16, '0');

/** Insert an employee directly (bootstrap) with a known password and no forced change. */
export async function insertEmployee(db: Db, f: { code: string; name?: string; role: string; jobTitle?: string; teamId?: string | null; managerId?: string | null; joining?: string }) {
  const hash = await hashPassword(PW);
  const r = await db.query(`INSERT INTO employees (code, full_name, role_key, job_title, team_id, sales_manager_id, joining_date, password_hash, must_change_password)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,false) RETURNING id`,
    [f.code, f.name ?? f.code, f.role, f.jobTitle ?? '', f.teamId ?? null, f.managerId ?? null, f.joining ?? '2026-01-01', hash]);
  await db.query(`INSERT INTO leave_balances (employee_id, year) VALUES ($1, 2026)`, [r.rows[0].id]);
  return r.rows[0].id as string;
}

/** Standard cast: owner, HR, accountant, two sales managers with teams, three sales employees. */
export async function cast(h: Harness) {
  const owner = await insertEmployee(h.db, { code: 'OWNER', name: 'المالك', role: 'owner' });
  const hr = await insertEmployee(h.db, { code: 'HR1', name: 'مديرة الموارد البشرية', role: 'hr_manager' });
  const acc = await insertEmployee(h.db, { code: 'ACC1', name: 'المحاسب', role: 'accountant' });
  const sm1 = await insertEmployee(h.db, { code: 'SM1', name: 'مدير فريق أ', role: 'sales_manager', jobTitle: 'مدير مبيعات' });
  const sm2 = await insertEmployee(h.db, { code: 'SM2', name: 'مدير فريق ب', role: 'sales_manager', jobTitle: 'مدير مبيعات' });
  const teamA = (await h.db.query(`INSERT INTO teams (name, manager_id) VALUES ('فريق أ', $1) RETURNING id`, [sm1])).rows[0].id;
  const teamB = (await h.db.query(`INSERT INTO teams (name, manager_id) VALUES ('فريق ب', $1) RETURNING id`, [sm2])).rows[0].id;
  const e1 = await insertEmployee(h.db, { code: 'E1', name: 'موظف ١', role: 'sales_employee', jobTitle: 'مستشار عقاري', teamId: teamA });
  const e2 = await insertEmployee(h.db, { code: 'E2', name: 'موظف ٢', role: 'sales_employee', jobTitle: 'مستشار عقاري', teamId: teamA });
  const e3 = await insertEmployee(h.db, { code: 'E3', name: 'موظف ٣', role: 'sales_employee', jobTitle: 'مستشار عقاري', teamId: teamB });
  const solo = await insertEmployee(h.db, { code: 'SOLO', name: 'بدون مدير', role: 'sales_employee', jobTitle: 'مستشار عقاري' });
  const t: Record<string, string> = {};
  for (const [k, code] of [['owner', 'OWNER'], ['hr', 'HR1'], ['acc', 'ACC1'], ['sm1', 'SM1'], ['sm2', 'SM2'], ['e1', 'E1'], ['e2', 'E2'], ['e3', 'E3'], ['solo', 'SOLO']]) {
    t[k] = await h.login(code, PW);
  }
  return { ids: { owner, hr, acc, sm1, sm2, e1, e2, e3, solo, teamA, teamB }, t };
}
