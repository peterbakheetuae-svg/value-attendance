import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';
import { buildRouter } from '../src/app.ts';

/**
 * Release gate «centralized permissions» (2026-11-26): the backend, not the app, decides.
 * An active employee whose every permission is individually denied calls EVERY registered route directly — first with
 * unknown ids, then with the real ids of other people's records. Nothing he reaches may answer 2xx except his own
 * self-service routes (listed below), and no 2xx answer may carry another employee's id.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
after(async () => { await h.close(); });

// anonymous by design (security.test.ts checks each of them)
const PUBLIC = new Set(['GET /healthz', 'GET /healthz/latency', 'GET /readyz', 'POST /auth/login', 'GET /media/:kind/:id',
  'POST /auth/forgot', 'POST /auth/forgot/verify', 'POST /auth/forgot/reset', 'GET /f/:token', 'POST /public/leads/:token',
  'POST /public/hooks/valueaqar', 'GET /public/hooks/meta', 'POST /public/hooks/meta', 'GET /public/meta/oauth/callback',
  'POST /public/meta/deauthorize', 'POST /public/meta/data-deletion', 'GET /public/meta/data-deletion/:code']);
// routes that end his own session — called last / not at all
const SKIP = new Set(['POST /auth/logout', 'POST /auth/logout-all', 'POST /auth/change-password', 'POST /me/password']);

// the org chart (GET /teams: team name, department, its manager's id / name, member count) is readable by every signed-in
// employee — app pickers rely on it. Recorded as release-gate finding P-1 (whether the org chart is visible to everyone is
// the owner's policy); the answer is checked below to carry managers only, never contact, salary or member lists.
const ORG_CHART = 'GET /teams';

const FAKE = '00000000-0000-4000-8000-000000000000';

async function sweep(idFor: (param: string) => string, token = c.t.solo, others0?: string[]) {
  const routes = buildRouter({ db: h.db, clock: () => new Date() }).list();
  const ok: string[] = []; const leaks: string[] = []; const errors: string[] = [];
  const others = others0 ?? [c.ids.owner, c.ids.hr, c.ids.acc, c.ids.sm1, c.ids.sm2, c.ids.e1, c.ids.e2, c.ids.e3];
  for (const r of routes) {
    if (PUBLIC.has(r) || SKIP.has(r)) continue;
    const [method, path] = r.split(' ');
    const url = path.replace(/:([a-zA-Z]+)/g, (_m, p) => idFor(p)) + (path.includes('?') ? '' : '?month=2026-03');
    const res = await h.call(token, method, url, method === 'GET' ? undefined : {});
    if (res.status >= 500) errors.push(`${r} → ${res.status}`);
    if (res.status >= 200 && res.status < 300) {
      ok.push(r);
      const text = typeof res.body === 'string' ? res.body : JSON.stringify(res.body ?? '');
      const seen = others.filter((id) => text.includes(id));
      if (r === 'GET /leads/dashboard') {
        // «الأفضل»: the ranking (rank, id, name) is the company's by design; another team's numbers must be hidden
        const shownOthers = (res.body?.best ?? []).filter((x: any) => seen.includes(x.id) && (x.actions !== null || x.meetings !== null || x.deals !== null));
        // «المستخدمون المتصلون» (online): the owner's decision 2026-11-23 shows it to the GM, the administrative officer and
        // sales managers, company-wide (finding P-2: whether a sales manager should see only his team is the owner's call);
        // it may carry id / name / last-seen only
        const onlineOk = (res.body?.online ?? []).every((x: any) => Object.keys(x).every((k) => ['id', 'name', 'seen', 'me'].includes(k)));
        if (!onlineOk) leaks.push(`${r} → online list carries more than id / name / last seen`);
        const elsewhere = seen.filter((id) => !(res.body?.best ?? []).some((x: any) => x.id === id) || JSON.stringify({ ...res.body, best: [], online: [] }).includes(id));
        if (shownOthers.length || elsewhere.length) {
          const where = Object.keys(res.body ?? {}).filter((k) => k !== 'best' && seen.some((id) => JSON.stringify(res.body[k]).includes(id)));
          leaks.push(`${r} → another team's numbers (${shownOthers.map((x: any) => x.name).join('/')}) or records in [${where.join(', ')}]`);
        }
      } else if (r === 'GET /brokerage/people') {
        // the colleague picker of a brokerage deal: id + name of active employees only (by design), nothing else
        const extraFields = (res.body?.people ?? []).some((x: any) => Object.keys(x).some((k) => !['id', 'name'].includes(k)));
        if (extraFields) leaks.push(`${r} → more than id / name`);
      } else if (r === ORG_CHART) {
        const managers = new Set((res.body?.teams ?? []).map((t: any) => t.manager_id));
        const extra = seen.filter((id) => !managers.has(id));
        if (extra.length || /phone|email|salary|national|address/i.test(text)) leaks.push(`${r} → more than the org chart`);
      } else if (seen.length) leaks.push(`${r} → carries ${seen.length} other employee id(s)`);
    }
  }
  // the sweep's own calls must not have ended his session (otherwise later routes were only tested as anonymous)
  assert.equal((await h.call(token, 'GET', '/me')).status, 200, 'session still valid after the sweep');
  return { ok: ok.sort(), leaks, errors };
}

before(async () => {
  // production's schema (every migration through 092): the fine-grained keys exist, so nothing falls back to an open
  // pre-066 rule (in a pre-066 database cash.attachment_* / cash.receipt_print / exclusive.view_client / report.export
  // are open to everyone by design — the state before those keys existed)
  h = await harness('2026-03-10T08:00:00Z', { migrationsExcept: [] }); c = await cast(h);
  // every permission individually denied (the strongest restriction an owner can set on an account)
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow, by_id)
                    SELECT $1, key, false, $2 FROM permissions`, [c.ids.solo, c.ids.owner]);
  const me = await h.call(c.t.solo, 'GET', '/me');
  assert.equal(me.status, 200);
  const perms: string[] = me.body.permissions ?? me.body.employee?.permissions ?? [];
  assert.deepEqual(perms.filter((p) => !p.startsWith('self.')), [], 'the account holds no permission');
});

test('zero-permission account, unknown ids: no route leaks another employee; no 500', async () => {
  const r = await sweep((p) => (p === 'key' ? 'hr_manager' : FAKE));
  console.log(`2xx (unknown ids): ${r.ok.length}\n${r.ok.join('\n')}`);
  assert.deepEqual(r.errors, []);
  assert.deepEqual(r.leaks, []);
});

test('zero-permission account, REAL ids of other people (IDOR): no route leaks another employee', async () => {
  const real: Record<string, string> = { id: c.ids.e2, employeeId: c.ids.e2, teamId: c.ids.teamA, key: 'hr_manager' };
  const r = await sweep((p) => real[p] ?? c.ids.e2);
  console.log(`2xx (real ids): ${r.ok.length}\n${r.ok.join('\n')}`);
  assert.deepEqual(r.errors, []);
  assert.deepEqual(r.leaks, []);
});

// with their role's default permissions: a sales employee of team B and the manager of team B call every route with the
// real ids of team A's people — nothing of team A may come back (cross-team IDOR), apart from the org chart
const teamA = () => [c.ids.e1, c.ids.e2];
const realA = (p: string) => ({ id: c.ids.e1, employeeId: c.ids.e1, teamId: c.ids.teamA, key: 'hr_manager' } as Record<string, string>)[p] ?? c.ids.e1;

test('sales employee (team B, default permissions) with team A ids: no team A record leaks', async () => {
  const r = await sweep(realA, c.t.e3, teamA());
  console.log(`2xx (e3 → team A ids): ${r.ok.length}`);
  assert.deepEqual(r.errors, []);
  assert.deepEqual(r.leaks, []);
});

test('sales manager of team B (default permissions) with team A ids: no team A record leaks', async () => {
  const r = await sweep(realA, c.t.sm2, teamA());
  console.log(`2xx (sm2 → team A ids): ${r.ok.length}`);
  assert.deepEqual(r.errors, []);
  assert.deepEqual(r.leaks, []);
});
