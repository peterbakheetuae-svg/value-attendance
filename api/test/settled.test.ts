import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

/** «تم التصفيه»: only after the custody is received back; then every page closes (only his own report reads) and
 *  he never shows up for new leads. */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-11-14T08:00:00Z'); c = await cast(h);
  // the leads distributor is «مسؤول إداري» (the accountant alone has no sales board)
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [c.ids.acc]); });
after(async () => { await h.close(); });

test('تم التصفيه needs the custody back, then closes the account and leaves the leads', async () => {
  const asset = await h.call(c.t.hr, 'POST', '/custody/assets', { assetType: 'mobile', name: 'Samsung A15', serialNo: 'IMEI-9' });
  const given = await h.call(c.t.hr, 'POST', `/employees/${c.ids.e1}/custody`, { assetId: asset.body.asset.id });
  assert.equal(given.status, 201, JSON.stringify(given.body));
  const settle = () => h.call(c.t.hr, 'PATCH', `/employees/${c.ids.e1}`, { legacyFields: { status: 'تم التصفيه' } });
  const refused = await settle();
  assert.equal(refused.status, 400, JSON.stringify(refused.body));
  assert.equal(refused.body.error.details?.reason ?? refused.body.error.reason ?? 'open_custody', 'open_custody');
  const itemId = given.body.item?.id ?? given.body.custody?.id ?? (await h.db.query(`SELECT id FROM custody_items WHERE employee_id = $1`, [c.ids.e1])).rows[0].id;
  const back = await h.call(c.t.hr, 'POST', `/custody/${itemId}/close`, { outcome: 'returned', returnedOn: '2026-11-14', condition: 'good' });
  assert.equal(back.status, 200, JSON.stringify(back.body));
  const ok = await settle();
  assert.equal(ok.status, 200, JSON.stringify(ok.body));

  const me = await h.call(c.t.e1, 'GET', '/me');
  assert.equal(me.status, 200);
  assert.equal(me.body.employee.settled, true);
  assert.deepEqual(me.body.permissions, []);
  assert.equal((await h.call(c.t.e1, 'GET', '/leads/meta')).status, 403, 'the sales board is closed');
  assert.equal((await h.call(c.t.e1, 'POST', '/leads', { fullName: 'x', phone: '01000000009' })).status, 403, 'nothing is written');
  const acc = (await h.call(c.t.acc, 'GET', '/leads/meta')).body;
  assert.ok(!acc.assignees.some((e: any) => e.id === c.ids.e1), 'not among the salesmen to give leads to');
  assert.ok(acc.assignees.some((e: any) => e.id === c.ids.e2));
});

test('تم التصفيه: from that day no absence and no attendance counted; out of the boards, the presence and «الأفضل»', async () => {
  // (the previous test settled e1 on 2026-11-14)
  const lf = (await h.db.query(`SELECT legacy_fields FROM employees WHERE id = $1`, [c.ids.e1])).rows[0].legacy_fields;
  assert.equal(lf.settledAt, '2026-11-14', 'the day he was settled is kept');
  await h.db.query(`UPDATE employees SET joining_date = '2026-11-01' WHERE id = ANY($1::uuid[])`, [[c.ids.e1, c.ids.e2]]);
  h.now.value = new Date('2026-11-17T10:00:00Z');   // a Tuesday, 12:00 Cairo
  const month = async (id: string) => (await h.call(c.t.hr, 'GET', `/attendance?employeeId=${id}&month=2026-11`)).body;
  const s = await month(c.ids.e1), o = await month(c.ids.e2);
  const day = (m: any, d: string) => m.days.find((x: any) => x.date === d).status;
  assert.equal(day(s, '2026-11-16'), 'inactive');
  assert.equal(day(s, '2026-11-17'), 'inactive');
  assert.equal(day(o, '2026-11-16'), 'absent');
  assert.equal(day(s, '2026-11-12'), 'absent', 'before he was settled nothing changes');
  assert.ok(s.summary.unapprovedAbsenceDays < o.summary.unapprovedAbsenceDays, JSON.stringify([s.summary, o.summary]));
  const board = (await h.call(c.t.hr, 'GET', '/attendance/board')).body;
  assert.ok(!JSON.stringify(board).includes(c.ids.e1), 'not on today\'s board');
  assert.ok(JSON.stringify(board).includes(c.ids.e2));
  const emp = (await h.call(c.t.owner, 'GET', '/dashboard/owner?view=employees')).body;
  assert.ok(!emp.presence.rows.some((x: any) => x.id === c.ids.e1), 'not in «الموظفين دلوقتي»');
  assert.ok(emp.presence.rows.some((x: any) => x.id === c.ids.e2));
  // «الأفضل»: the salesmen only — not the owner, the general manager or the admin officer, and not the settled one
  const best = (await h.call(c.t.acc, 'GET', '/leads/dashboard?period=month')).body.best.map((x: any) => x.id);
  assert.ok(best.includes(c.ids.e2) && best.includes(c.ids.e3), JSON.stringify(best));
  for (const x of [c.ids.e1, c.ids.owner, c.ids.acc]) assert.ok(!best.includes(x), x);
});
