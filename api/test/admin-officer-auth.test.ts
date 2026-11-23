import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, insertEmployee, PW, type Harness } from './helpers.ts';
import { seesDuplicates } from '../src/modules/leads.ts';

/**
 * The «مسؤول إداري» (administrative officer) is recognised by its position — whatever its key (migration 057 created
 * «admin_officer» or renamed an existing «HR ومحاسب» position, keeping that key) — and the offline attendance notices go to
 * the HR desk by permission. HR / the accountant / the owner keep exactly what they had. No role or permission is changed:
 * the second position below copies admin_officer's grants the way 057 would have left a renamed one.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
const ids: Record<string, string> = {}; const t: Record<string, string> = {};

async function person(code: string, role: string, position: string | null) {
  const id = await insertEmployee(h.db, { code, name: code, role, joining: '2025-01-01' });
  if (position) await h.db.query(`UPDATE employees SET position_key = $2 WHERE id = $1`, [id, position]);
  ids[code] = id; t[code] = await h.login(code, PW);
}

before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  // a renamed position (another key, the same name and grants)
  await h.db.query(`INSERT INTO roles (key, name_ar, name_en, rank, base_key, builtin, description)
                    VALUES ('hr_acc_old', 'مسؤول إداري', 'Administrative Officer', 70, 'accountant', false, 'renamed by 057')`);
  await h.db.query(`INSERT INTO role_permissions (role_key, perm_key) SELECT 'hr_acc_old', perm_key FROM role_permissions WHERE role_key = 'admin_officer'`);
  await person('AO1', 'accountant', 'admin_officer');
  await person('AO2', 'accountant', 'hr_acc_old');
});
after(async () => { await h.close(); });

test('offline attendance from an earlier day: HR and the administrative officer (either key) are told; the accountant and the owner are not', async () => {
  const r = await h.call(c.t.e1, 'POST', '/attendance/check-in', { offlineAt: '2026-03-09T08:00:00Z' });
  assert.equal(r.status, 409); assert.equal(r.body.error.details.reason, 'offline_other_day');
  const told = async (tok: string) => ((await h.call(tok, 'GET', '/notifications')).body.notifications ?? []).some((n: any) => n.type === 'offline_attendance');
  assert.equal(await told(c.t.hr), true, 'HR (as before)');
  assert.equal(await told(t.AO1), true, 'the administrative officer');
  assert.equal(await told(t.AO2), true, 'the administrative officer under the old key');
  assert.equal(await told(c.t.acc), false, 'the accountant alone (no attendance correction)');
  assert.equal(await told(c.t.owner), false, 'the owner (as before)');
  assert.equal(await told(c.t.sm1), false);
});

test('a late offline record (same day): the same HR desk is told', async () => {
  h.now.value = new Date('2026-03-10T09:30:00Z');
  await h.db.query(`UPDATE sessions SET last_seen_at = '2026-03-09T16:00:00Z' WHERE employee_id = $1`, [c.ids.e2]);
  const r = await h.call(c.t.e2, 'POST', '/attendance/check-in', { offlineAt: '2026-03-10T08:50:00Z' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const late = async (tok: string) => ((await h.call(tok, 'GET', '/notifications')).body.notifications ?? [])
    .filter((n: any) => n.type === 'offline_attendance' && /بعد 40 دقيقة/.test(n.body)).length;
  assert.deepEqual([await late(c.t.hr), await late(t.AO1), await late(t.AO2), await late(c.t.acc), await late(c.t.owner)], [1, 1, 1, 0, 0]);
});

test('«الموظفين دلوقتي»: HR and the administrative officer (either key) — as HR; the office as before; the accountant not', async () => {
  const p = async (tok: string) => h.call(tok, 'GET', '/dashboard/presence');
  for (const tok of [c.t.hr, t.AO1, t.AO2]) {
    const r = await p(tok);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.hr, true);
    // the admin officer's main dashboard shows the square too (like the GM's); HR keeps it on the attendance page
    assert.equal(r.body.adminOfficer, tok !== c.t.hr);
  }
  const o = await p(c.t.owner);
  assert.equal(o.status, 200); assert.equal(o.body.hr, false); assert.equal(o.body.adminOfficer, false);
  assert.equal((await p(c.t.acc)).status, 403);
  assert.equal((await p(c.t.e1)).status, 403);
});

test('sales board: the administrative officer (either key) sees who holds a repeated lead and is not ranked as a salesman', async () => {
  assert.equal(await seesDuplicates(h.db, ids.AO1), true);
  assert.equal(await seesDuplicates(h.db, ids.AO2), true);
  assert.equal(await seesDuplicates(h.db, c.ids.sm1), true, 'a sales manager (as before)');
  assert.equal(await seesDuplicates(h.db, c.ids.acc), false);
  assert.equal(await seesDuplicates(h.db, c.ids.hr), false);
  const best = (await h.call(c.t.owner, 'GET', '/leads/dashboard')).body.best ?? [];
  const names = best.map((x: any) => x.name ?? x.fullName ?? x.full_name);
  assert.ok(!names.includes('AO1') && !names.includes('AO2'), JSON.stringify(names));
});

test('marketing companies: the administrative officer (either key) is the direct manager the profile accepts; no one else', async () => {
  const opts = await h.call(c.t.owner, 'GET', '/marketing-companies/options');
  assert.equal(opts.status, 200, JSON.stringify(opts.body));
  const managers = opts.body.options.managers.map((x: any) => x.id).sort();
  assert.deepEqual(managers, [ids.AO1, ids.AO2].sort());
  const mk = await h.call(c.t.owner, 'POST', '/marketing-companies', { name: 'ميديا', kind: 'commission', defaultPct: 1 });
  const id = mk.body.company.id;
  assert.equal((await h.call(c.t.owner, 'PATCH', `/marketing-companies/${id}/profile`, { managerId: ids.AO2 })).status, 200);
  assert.equal((await h.call(c.t.owner, 'PATCH', `/marketing-companies/${id}/profile`, { managerId: ids.AO1 })).status, 200);
  assert.equal((await h.call(c.t.owner, 'PATCH', `/marketing-companies/${id}/profile`, { managerId: c.ids.hr })).status, 400);
  assert.equal((await h.call(c.t.owner, 'PATCH', `/marketing-companies/${id}/profile`, { managerId: c.ids.acc })).status, 400);
});

test('nothing about the roles changed: the positions and their grants are as they were', async () => {
  const n = (await h.db.query(`SELECT count(*)::int AS n FROM role_permissions WHERE role_key = 'admin_officer'`)).rows[0].n;
  const m = (await h.db.query(`SELECT count(*)::int AS n FROM role_permissions WHERE role_key = 'hr_acc_old'`)).rows[0].n;
  assert.equal(n, m);
  assert.equal((await h.db.query(`SELECT key FROM roles WHERE key = 'admin_officer'`)).rows.length, 1);
});
