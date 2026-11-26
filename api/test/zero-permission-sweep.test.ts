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

const FAKE = '00000000-0000-4000-8000-000000000000';

async function sweep(idFor: (param: string) => string) {
  const routes = buildRouter({ db: h.db, clock: () => new Date() }).list();
  const ok: string[] = []; const leaks: string[] = []; const errors: string[] = [];
  const others = [c.ids.owner, c.ids.hr, c.ids.acc, c.ids.sm1, c.ids.sm2, c.ids.e1, c.ids.e2, c.ids.e3];
  for (const r of routes) {
    if (PUBLIC.has(r) || SKIP.has(r)) continue;
    const [method, path] = r.split(' ');
    const url = path.replace(/:([a-zA-Z]+)/g, (_m, p) => idFor(p)) + (path.includes('?') ? '' : '?month=2026-03');
    const res = await h.call(c.t.solo, method, url, method === 'GET' ? undefined : {});
    if (res.status >= 500) errors.push(`${r} → ${res.status}`);
    if (res.status >= 200 && res.status < 300) {
      ok.push(r);
      const text = typeof res.body === 'string' ? res.body : JSON.stringify(res.body ?? '');
      const seen = others.filter((id) => text.includes(id));
      if (seen.length) leaks.push(`${r} → carries ${seen.length} other employee id(s)`);
    }
  }
  // the sweep's own calls must not have ended his session (otherwise later routes were only tested as anonymous)
  assert.equal((await h.call(c.t.solo, 'GET', '/me')).status, 200, 'session still valid after the sweep');
  return { ok: ok.sort(), leaks, errors };
}

before(async () => {
  h = await harness(); c = await cast(h);
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
