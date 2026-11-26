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
          // the database as production had it before the 2026-11-23 release; the suites that test 066 / 083–087 apply
          // them themselves (and release-migrations.test.ts runs the whole db/migrations the way the deploy does)
          await migrate(db, MIGRATIONS_DIR, { skip: (f) => RELEASE_2026_11_23.includes(f) || RELEASE_R2.includes(f) || RELEASE_HANDOVER.includes(f) });
          // most suites create employees without files; the documents suite turns this back on
          await db.query(`UPDATE company_settings SET require_employee_documents = false, gps_required = false,
            payroll_auto_deductions = false, deduction_mode = 'per_minute'`); // suites that test the office check turn it on
        } finally { await db.end(); }
      }
      await c.query(`SELECT pg_advisory_unlock(424242)`);
    } finally { c.release(); await p.end(); }
  })();
  return templateReady;
}

/** the migrations the 2026-11-23 release moved from db/proposed into db/migrations (each also stays in db/proposed) */
export const RELEASE_2026_11_23 = ['066_fine_grained_permissions.sql', '083_financial_year_closing.sql', '084_marketing_company_payment_otp.sql',
  '085_financial_integrity.sql', '086_expense_classification.sql', '087_brokerage_deals.sql',
  '088_brokerage_listings.sql', '089_brokerage_deal_lead.sql'];
/** the R2 release (owner-approved D1 / D3 / D4, 2026-11-25): file storage — not in the template either; suites apply it */
export const RELEASE_R2 = ['091_r2_file_objects.sql'];
/** the brokerage commission handover (owner request 2026-11-25): not in the template either; suites apply it */
export const RELEASE_HANDOVER = ['090_brokerage_handover.sql'];

export interface Harness {
  db: Db; base: string; now: { value: Date }; server: Server; dbName: string;
  call: (token: string | null, method: string, path: string, body?: unknown, extra?: Record<string, string>) => Promise<{ status: number; body: any; headers: Headers; raw: Buffer }>;
  login: (identifier: string, password: string) => Promise<string>;
  close: () => Promise<void>;
}

/**
 * opts.migrationsExcept (optional): instead of the shared template, a fresh database with EVERY file of db/migrations
 * applied in the runner's own order except the named ones ([] = all of them: production's schema). Same settings as
 * the template. Default: the template.
 */
export async function harness(startIso = '2026-03-10T08:00:00Z', opts: { migrationsExcept?: string[] } = {}): Promise<Harness> {
  const dbName = 'hr_t_' + randomBytes(6).toString('hex');
  const u = new URL(ADMIN_URL); u.pathname = '/' + dbName;
  let db: Db;
  if (opts.migrationsExcept) {
    const except = opts.migrationsExcept;
    await admin((p) => p.query(`CREATE DATABASE ${dbName}`));
    db = createDb(u.toString());
    await migrate(db, MIGRATIONS_DIR, { skip: (f) => except.includes(f) });
    await db.query(`UPDATE company_settings SET require_employee_documents = false, gps_required = false,
      payroll_auto_deductions = false, deduction_mode = 'per_minute'`);
  } else {
    await ensureTemplate();
    await admin((p) => p.query(`CREATE DATABASE ${dbName} TEMPLATE ${TEMPLATE}`));
    db = createDb(u.toString());
  }
  const now = { value: new Date(startIso) };
  // TEST_APP_ROLE=1: the API under test connects as a least-privilege runtime role (the production valunivo_app grants,
  // WITHOUT CREATE); test setup / assertions keep the admin connection (h.db)
  const appDb = process.env.TEST_APP_ROLE === '1' ? await appRoleDb(dbName) : null;
  const router = buildRouter({ db: appDb ?? db, clock: () => now.value });
  const server = createServer(createHandler(router, { corsOrigins: ['http://ok.test'], log: (o) => console.error(o) }));
  await new Promise<void>((res) => server.listen(0, '127.0.0.1', () => res()));
  const port = (server.address() as any).port;
  const base = `http://127.0.0.1:${port}`;
  const call = async (token: string | null, method: string, path: string, body?: unknown, extra: Record<string, string> = {}) => {
    const headers: Record<string, string> = { ...extra };
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
      await appDb?.end();
      await admin((p) => p.query(`DROP DATABASE IF EXISTS ${dbName} WITH (FORCE)`));
    },
  };
}

/** the tables the API itself deletes from (src/** "DELETE FROM …"): the only DELETE grants the runtime role gets */
export const RUNTIME_DELETE_TABLES = ['web_push_subscriptions', 'role_permissions', 'push_tokens', 'holidays', 'employee_permissions',
  'employee_documents', 'notifications', 'employee_devices', 'deals', 'tracking_pings', 'payroll_batch_lines', 'meta_pages',
  'marketing_company_files', 'lead_targets', 'lead_routes', 'lead_attachments', 'ex_unit_files', 'evaluations', 'attendance_selfies',
  // proposed 086 (expense groups / categories): granted once the table exists — as db/roles/valunivo_app_least_privilege.sql
  'expense_group_categories',
  // «إنجاز» a repeated lead (leads.ts duplicate-resolve): the repeat — or the original — goes with its own records
  'leads', 'lead_actions', 'lead_checkins', 'lead_logs', 'lead_referrals', 'lead_requests', 'lead_whatsapp'];
const APP_ROLE = 'va_app_test', APP_PW = 'app-role-test-only';
/** DELETE on the runtime tables that exist now (idempotent) — like rerunning the role script after a migration */
async function grantRuntimeDeletes(q: { query: (sql: string) => Promise<unknown> }) {
  for (const t of RUNTIME_DELETE_TABLES) await q.query(`DO $$ BEGIN IF to_regclass('public.${t}') IS NOT NULL THEN EXECUTE 'GRANT DELETE ON ${t} TO ${APP_ROLE}'; END IF; END $$`);
}
/** after a test applies a (proposed) migration: the runtime role gets the grants the role script gives in production */
export async function regrantAppRole(h: { db: Db }) {
  if (process.env.TEST_APP_ROLE === '1') await grantRuntimeDeletes(h.db);
}
async function appRoleDb(dbName: string): Promise<Db> {
  await admin(async (p) => {
    await p.query(`DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${APP_ROLE}') THEN
      CREATE ROLE ${APP_ROLE} LOGIN PASSWORD '${APP_PW}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS; END IF;
      -- test files run in parallel: another one may create the role between the check and the CREATE
      EXCEPTION WHEN unique_violation OR duplicate_object THEN NULL; END $$`);
  });
  const u = new URL(ADMIN_URL); u.pathname = '/' + dbName;
  const own = new pg.Pool({ connectionString: u.toString(), max: 1 });
  try {
    await own.query(`GRANT CONNECT ON DATABASE ${dbName} TO ${APP_ROLE}`);
    await own.query(`GRANT USAGE ON SCHEMA public TO ${APP_ROLE}`);
    await own.query(`REVOKE CREATE ON SCHEMA public FROM ${APP_ROLE}`);
    await own.query(`GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO ${APP_ROLE}`);
    await own.query(`REVOKE UPDATE ON audit_log FROM ${APP_ROLE}`);
    await own.query(`GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ${APP_ROLE}`);
    // as in production (ALTER DEFAULT PRIVILEGES FOR ROLE neondb_owner): tables the owner adds later are usable too
    await own.query(`ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE ON TABLES TO ${APP_ROLE}`);
    await own.query(`ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO ${APP_ROLE}`);
    await grantRuntimeDeletes(own);
  } finally { await own.end(); }
  const a = new URL(u.toString()); a.username = APP_ROLE; a.password = APP_PW;
  return createDb(a.toString());
}

export const PW = 'Passw0rd!x';
/** Stable fake device id per account (device binding is on by default). */
export const dev = (identifier: string) => `testdevice-${identifier.toUpperCase()}`.padEnd(16, '0');

/** Insert an employee directly (bootstrap) with a known password and no forced change. */
export async function insertEmployee(db: Db, f: { code: string; name?: string; role: string; jobTitle?: string; teamId?: string | null; managerId?: string | null; joining?: string }) {
  const hash = await hashPassword(PW);
  const r = await db.query(`INSERT INTO employees (code, full_name, role_key, job_title, team_id, sales_manager_id, joining_date, password_hash, must_change_password, device_lock)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,false,$3 <> 'owner') RETURNING id`,
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

/**
 * A payment confirmed the way the app does it now (no more «تم الاستلام»): the recipient's app gets the 4-digit code,
 * the person who paid enters it. Returns the verify answer (or the code request's, when that failed).
 */
export async function confirmPayout(h: Harness, recipientToken: string, payerToken: string, payoutId: string) {
  const c = await h.call(recipientToken, 'POST', `/payouts/${payoutId}/code`, {});
  if (c.status !== 200) return c;
  return h.call(payerToken, 'POST', `/payouts/${payoutId}/verify`, { code: c.body.code });
}

/**
 * A reservation / contract / sale's client is ALWAYS an existing lead (the client is never typed): turns a body written
 * with clientName / clientPhone (and a hand-picked marketingCompanyId) into one with a fresh lead of that name and phone,
 * assigned to `assignee` — on a campaign of that marketing company when one was given (the source is then automatic).
 */
let leadSeq = 0;
export async function asLead(h: { db: Db }, assignee: string, body: Record<string, any>) {
  // a unit sale names them buyerName / buyerPhone
  const { clientName: cn, clientPhone: cp, buyerName, buyerPhone, marketingCompanyId, ...rest } = body;
  const clientName = cn ?? buyerName; const clientPhone = cp ?? buyerPhone;
  leadSeq++;
  const typed = String(clientPhone ?? '').trim();
  const phone = typed.length >= 5 ? typed : `0105${String(5000000 + leadSeq)}`; // a lead's phone is at least 5 characters
  const digits = phone.replace(/\D/g, '');
  let campaign: string | null = null;
  if (marketingCompanyId) {
    campaign = (await h.db.query(`INSERT INTO lead_campaigns (name, project_id, marketing_company_id) VALUES ($1, $2, $3) RETURNING id`,
      [`حملة اختبار ${leadSeq}`, typeof rest.projectId === 'string' ? rest.projectId : null, marketingCompanyId])).rows[0].id;
  }
  const l = await h.db.query(`INSERT INTO leads (full_name, phone, phone_norm, project_id, campaign_id, assigned_to, assigned_at, stage)
                              VALUES ($1, $2, $3, $4, $5, $6, now(), 'interested') RETURNING id`,
    [String(clientName ?? `عميل ${leadSeq}`), phone, digits, typeof rest.projectId === 'string' ? rest.projectId : null, campaign, assignee]);
  return { ...rest, leadId: l.rows[0].id as string };
}
