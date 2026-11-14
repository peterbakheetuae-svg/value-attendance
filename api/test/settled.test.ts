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
