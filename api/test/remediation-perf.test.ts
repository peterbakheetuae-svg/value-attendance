import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { harness, cast, type Harness } from './helpers.ts';
import { receiptListSelect } from '../src/modules/cash.ts';

/**
 * Remediation R3–R6 (docs/SPEED_ENGINEER_AUDIT.md §7): the faster queries must return exactly what the old ones did.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-03-10T08:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });

const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(4000, 7)]).toString('base64');

test('R3: receipt and expense lists no longer read the photo, and return exactly what the single-record read returns', async () => {
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/adjustments', { cashbox: 'hr', kind: 'opening', amount: 90000, reason: 'رصيد افتتاحي' })).status, 201);
  const rc = await h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'reservation', amount: 1500, payerName: 'عميل', purpose: 'حجز',
    clientRef: randomUUID(), attachment: jpeg });
  assert.equal(rc.status, 201, JSON.stringify(rc.body));
  const rcPlain = await h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'reservation', amount: 700, payerName: 'عميل ٢', purpose: 'حجز', clientRef: randomUUID() });
  const ex = await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 300, category: 'ضيافة', reason: 'بوفيه', beneficiary: 'محل', attachment: jpeg });
  assert.equal(ex.status, 201, JSON.stringify(ex.body));

  const receipts = await h.call(c.t.hr, 'GET', '/cash/receipts');
  const expenses = await h.call(c.t.hr, 'GET', '/cash/expenses');
  assert.equal(receipts.status, 200); assert.equal(expenses.status, 200);
  const raw = JSON.stringify(receipts.body) + JSON.stringify(expenses.body);
  assert.ok(!raw.includes(jpeg.slice(0, 40)), 'no image bytes in a list');
  // identical to the record the full (unchanged) select returned at creation — every field, including hasAttachment
  assert.deepEqual(receipts.body.receipts.find((x: any) => x.id === rc.body.receipt.id), rc.body.receipt);
  assert.deepEqual(receipts.body.receipts.find((x: any) => x.id === rcPlain.body.receipt.id), rcPlain.body.receipt);
  assert.deepEqual(expenses.body.expenses.find((x: any) => x.id === ex.body.expense.id), ex.body.expense);
  assert.equal(rc.body.receipt.hasAttachment, true);
  assert.equal(rcPlain.body.receipt.hasAttachment, false);
  // the photo is still served by its own permission-checked route
  const photo = await h.call(c.t.owner, 'GET', `/cash/attachment/receipt/${rc.body.receipt.id}`);
  assert.equal(photo.status, 200);
  assert.equal(photo.body.attachment, jpeg);
});

test('R3: the list column set is every column of the table except the photo (follows future migrations)', async () => {
  const sql = await receiptListSelect(h.db);
  assert.ok(!/\br\.\*/.test(sql), 'no r.*');
  assert.ok(!/\br\.(?:"attachment"|attachment)\s*,/.test(sql), 'the photo column itself is not selected');
  assert.match(sql, /\(r\.attachment IS NOT NULL\) AS has_attachment/);
  const cols = (await h.db.query(`SELECT count(*)::int AS n FROM information_schema.columns WHERE table_name = 'cash_receipts' AND table_schema = current_schema()`)).rows[0].n;
  const listed = sql.slice(sql.indexOf('SELECT ') + 7, sql.indexOf(', (r.attachment')).split(', ').length;
  assert.equal(listed, cols - 1);
});

import { ensurePeriod, ensurePeriods, loadPeriod, loadPeriods } from '../src/modules/kpi.ts';

test('R4: batched KPI snapshot + load = the per-employee functions, for every set scope, evaluation state and no set', async () => {
  const db = h.db;
  const ownerId = (await db.query(`SELECT id FROM employees WHERE code = 'OWNER'`)).rows[0].id;
  await db.tx(async (q) => {
    await q.query(`INSERT INTO kpi_definitions (id, key, name_ar, measurement_type, higher_is_better) VALUES
      ('00000000-0000-0000-0000-0000000000d1','r4_deals','ر٤ صفقات','count',true),
      ('00000000-0000-0000-0000-0000000000d2','r4_late','ر٤ تأخير','count',false),
      ('00000000-0000-0000-0000-0000000000d3','r4_rev','ر٤ إيراد','amount_egp',true)`);
    const e1 = (await q.query(`SELECT id FROM employees WHERE code = 'E1'`)).rows[0].id;
    await q.query(`INSERT INTO kpi_sets (id, name, scope_type, job_title, version, active, created_by) VALUES
      ('00000000-0000-0000-0000-0000000000a1','title','job_title','مستشار عقاري',1,true,$1),
      ('00000000-0000-0000-0000-0000000000a4','title old','job_title','مستشار عقاري',0,false,$1)`, [ownerId]);
    await q.query(`INSERT INTO kpi_sets (id, name, scope_type, position_key, version, active, created_by) VALUES
      ('00000000-0000-0000-0000-0000000000a2','position','position','sales_manager',1,true,$1)`, [ownerId]);
    await q.query(`INSERT INTO kpi_sets (id, name, scope_type, employee_id, version, active, created_by) VALUES
      ('00000000-0000-0000-0000-0000000000a3','E1 own','employee',$2,1,true,$1)`, [ownerId, e1]);
    // SM1 has all three (own > position > title); SM2 has position + title (position wins)
    const sm1 = (await q.query(`SELECT id FROM employees WHERE code = 'SM1'`)).rows[0].id;
    await q.query(`INSERT INTO kpi_sets (id, name, scope_type, employee_id, version, active, created_by) VALUES
      ('00000000-0000-0000-0000-0000000000a6','SM1 own','employee',$2,1,true,$1)`, [ownerId, sm1]);
    await q.query(`INSERT INTO kpi_sets (id, name, scope_type, job_title, version, active, created_by) VALUES
      ('00000000-0000-0000-0000-0000000000a7','manager title','job_title','مدير مبيعات',1,true,$1)`, [ownerId]);
    await q.query(`INSERT INTO kpi_set_items (set_id, kpi_id, weight, target) VALUES
      ('00000000-0000-0000-0000-0000000000a6','00000000-0000-0000-0000-0000000000d2',100,2),
      ('00000000-0000-0000-0000-0000000000a7','00000000-0000-0000-0000-0000000000d1',100,8)`);
    await q.query(`INSERT INTO kpi_set_items (set_id, kpi_id, weight, target) VALUES
      ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000d1',60,10),
      ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000d2',40,3),
      ('00000000-0000-0000-0000-0000000000a2','00000000-0000-0000-0000-0000000000d3',100,50000),
      ('00000000-0000-0000-0000-0000000000a3','00000000-0000-0000-0000-0000000000d1',50,4),
      ('00000000-0000-0000-0000-0000000000a3','00000000-0000-0000-0000-0000000000d3',50,9000),
      ('00000000-0000-0000-0000-0000000000a4','00000000-0000-0000-0000-0000000000d2',100,1)`);
  });
  const ids = (await db.query(`SELECT id FROM employees WHERE status = 'active' ORDER BY code`)).rows.map((r) => r.id as string);
  assert.ok(ids.length >= 8);
  const rowsOf = async (period: string) => (await db.query(`SELECT employee_id, set_id, kpi_id, weight_snapshot, target_snapshot, actual, state
      FROM kpi_results WHERE period = $1 ORDER BY employee_id, kpi_id`, [period])).rows;

  // snapshot: batch (2026-01) vs one by one (2026-02), and a concurrent double batch (2026-03)
  await ensurePeriods(db, ids, '2026-01-01');
  for (const id of ids) await ensurePeriod(db, id, '2026-02-01');
  await Promise.all([ensurePeriods(db, ids, '2026-03-01'), ensurePeriods(db, ids, '2026-03-01')]);
  const jan = await rowsOf('2026-01-01');
  assert.ok(jan.length > 0);
  assert.deepEqual(jan, await rowsOf('2026-02-01'));
  assert.deepEqual(jan, await rowsOf('2026-03-01'), 'concurrent snapshot is idempotent');
  const scopes = new Set(jan.map((r) => r.set_id));
  const byCode = Object.fromEntries((await db.query(`SELECT code, id FROM employees`)).rows.map((r) => [r.code, r.id]));
  const setOf = async (code: string) => new Set(jan.filter((r) => r.employee_id === byCode[code]).map((r) => r.set_id));
  assert.deepEqual([...await setOf('SM1')], ['00000000-0000-0000-0000-0000000000a6'], 'own set beats position and title');
  assert.deepEqual([...await setOf('SM2')], ['00000000-0000-0000-0000-0000000000a2'], 'position beats title');
  assert.deepEqual([...await setOf('E1')], ['00000000-0000-0000-0000-0000000000a3'], 'own set beats title');
  for (const s of ['a1', 'a2', 'a3']) assert.ok(scopes.has(`00000000-0000-0000-0000-0000000000${s}`), `set ${s} used`);
  assert.ok(!scopes.has('00000000-0000-0000-0000-0000000000a4'), 'retired set never used');
  // an employee who already has rows is never re-snapshotted, even if their set changed
  const before = await rowsOf('2026-01-01');
  await db.tx(async (q) => {
    const e2 = (await q.query(`SELECT id FROM employees WHERE code = 'E2'`)).rows[0].id;
    await q.query(`INSERT INTO kpi_sets (id, name, scope_type, employee_id, version, active, created_by) VALUES
      ('00000000-0000-0000-0000-0000000000a5','E2 own (added later)','employee',$2,1,true,$1)`, [ownerId, e2]);
    await q.query(`INSERT INTO kpi_set_items (set_id, kpi_id, weight, target) VALUES ('00000000-0000-0000-0000-0000000000a5','00000000-0000-0000-0000-0000000000d3',100,1)`);
  });
  await ensurePeriods(db, ids, '2026-01-01');
  assert.deepEqual(await rowsOf('2026-01-01'), before);

  // evaluate a mix: completed at target, completed below target, in progress, untouched
  const res = (await db.query(`SELECT id FROM kpi_results WHERE period = '2026-01-01' ORDER BY employee_id, kpi_id`)).rows;
  for (const [i, r] of res.entries()) {
    if (i % 4 === 0) await db.query(`UPDATE kpi_results SET actual = target_snapshot, state = 'completed' WHERE id = $1`, [r.id]);
    if (i % 4 === 1) await db.query(`UPDATE kpi_results SET actual = target_snapshot / 2, state = 'completed' WHERE id = $1`, [r.id]);
    if (i % 4 === 2) await db.query(`UPDATE kpi_results SET actual = 1, state = 'in_progress', entered_by = $2 WHERE id = $1`, [r.id, ownerId]);
  }
  for (const period of ['2026-01-01', '2026-02-01', '2025-12-01']) {
    const batch = await loadPeriods(db, ids, period);
    for (const id of ids) assert.deepEqual(batch.get(id), await loadPeriod(db, id, period), `${id} ${period}`);
  }
  const statuses = new Set([...(await loadPeriods(db, ids, '2026-01-01')).values()].map((s) => s.status));
  assert.ok(statuses.has('no_kpis') && statuses.size >= 2, [...statuses].join(','));
  assert.deepEqual([...(await loadPeriods(db, [], '2026-01-01')).keys()], []);
});

test('R4: /kpi/overview and the dashboard KPI block answer as before', async () => {
  const ov = await h.call(c.t.owner, 'GET', '/kpi/overview?month=2026-01');
  assert.equal(ov.status, 200);
  for (const e of ov.body.employees) {
    const one = await loadPeriod(h.db, e.employee.id, '2026-01-01');
    assert.deepEqual({ status: e.status, weightedScore: e.weightedScore, belowTarget: e.belowTarget, kpiCount: e.kpiCount },
      { status: one.status, weightedScore: one.weightedScore, belowTarget: one.belowTarget, kpiCount: one.items.length });
  }
  const d = await h.call(c.t.owner, 'GET', '/dashboard');
  assert.equal(d.status, 200);
  assert.ok(d.body.kpiOverview && typeof d.body.kpiOverview.employees === 'number');
});
