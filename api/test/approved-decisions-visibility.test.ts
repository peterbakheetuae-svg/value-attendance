import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

/**
 * Owner decisions 2026-11-26:
 *  P-1 — every signed-in employee sees the team directory (team, department, manager's name, member count) and nothing more;
 *        the editing ids stay with org.manage.
 *  P-2 — a sales manager sees the online status of his own team only (server-side, whatever the request asks).
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => {
  h = await harness('2026-03-10T08:00:00Z', { migrationsExcept: [] }); c = await cast(h);
  // every cast account signed in moments ago (cast() logs everyone in): mark the sessions as just seen
  await h.db.query(`UPDATE sessions SET last_seen_at = now()`);
});
after(async () => { await h.close(); });

const DIRECTORY = ['active', 'department_name', 'id', 'manager_name', 'member_count', 'name'];

test('P-1: an employee sees the team directory — exactly its fields, no employee id, contact or salary', async () => {
  for (const t of [c.t.e1, c.t.e3, c.t.acc, c.t.solo]) {
    const r = await h.call(t, 'GET', '/teams');
    assert.equal(r.status, 200);
    assert.equal(r.body.teams.length, 2);
    for (const x of r.body.teams) assert.deepEqual(Object.keys(x).sort(), DIRECTORY);
    const a = r.body.teams.find((x: any) => x.id === c.ids.teamA);
    assert.equal(a.manager_name, 'مدير فريق أ');
    assert.equal(a.member_count, 2);
    const text = JSON.stringify(r.body);
    for (const id of [c.ids.sm1, c.ids.sm2, c.ids.e1, c.ids.e2, c.ids.e3]) assert.ok(!text.includes(id), 'no employee id');
  }
});

test('P-1: org.manage (owner / HR) still gets the editing fields; nothing else about employees opened', async () => {
  const r = await h.call(c.t.owner, 'GET', '/teams');
  assert.equal(r.body.teams.find((x: any) => x.id === c.ids.teamA).manager_id, c.ids.sm1);
  // the directory did not widen employee records: a salesman still cannot open a colleague's file or list
  assert.ok([403, 404].includes((await h.call(c.t.e3, 'GET', `/employees/${c.ids.e1}`)).status));
  const list = await h.call(c.t.e3, 'GET', '/employees');
  assert.ok(!(list.body.employees ?? []).some((x: any) => x.id === c.ids.e1));
});

const onlineOf = async (t: string, query = '') => {
  const r = await h.call(t, 'GET', `/leads/dashboard${query}`);
  assert.equal(r.status, 200);
  return { ids: (r.body.online as any[]).map((x) => x.id), of: r.body.onlineOf, rows: r.body.online as any[] };
};

test('P-2: a sales manager sees his own team online — never the other team, whatever the request asks', async () => {
  for (const q of ['', '?view=all', `?employeeId=${c.ids.e3}`, `?view=all&employeeId=${c.ids.e3}`]) {
    const a = await onlineOf(c.t.sm1, q);
    assert.ok(a.ids.includes(c.ids.e1) && a.ids.includes(c.ids.e2), `team A visible (${q})`);
    for (const other of [c.ids.e3, c.ids.sm2, c.ids.solo]) assert.ok(!a.ids.includes(other), `no other team (${q})`);
    assert.ok(a.of <= 3, 'the online count is of his team');
    const b = await onlineOf(c.t.sm2, q);
    assert.ok(b.ids.includes(c.ids.e3), `team B visible (${q})`);
    for (const other of [c.ids.e1, c.ids.e2, c.ids.sm1]) assert.ok(!b.ids.includes(other), `no team A (${q})`);
  }
  // minimum fields only
  for (const x of (await onlineOf(c.t.sm1)).rows) assert.deepEqual(Object.keys(x).sort(), ['id', 'me', 'name', 'seen']);
});

test('P-2: a salesman sees no online list; the company-wide scope keeps its existing policy', async () => {
  assert.deepEqual((await onlineOf(c.t.e1)).ids, []);
  const own = await onlineOf(c.t.owner);
  for (const id of [c.ids.e1, c.ids.e2, c.ids.e3]) assert.ok(own.ids.includes(id), 'owner / GM: company-wide as before');
});
