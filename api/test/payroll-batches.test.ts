import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, type Harness } from './helpers.ts';

/** Financial system phase 3: hand-set advance deductions (≤ 2 stages) and monthly payroll batches. */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let tGm = ''; let advId = ''; let batchId = '';

before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE code = 'GM1'`);
  tGm = await h.login('GM1', PW);
  for (const [id, sal] of [[c.ids.e1, 10000], [c.ids.e2, 8000]] as const) {
    await h.db.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1, $2, $3)`, [id, sal, c.ids.owner]);
  }
  // an approved advance of 18,000 for e1 in March
  const adv = await h.db.query(`INSERT INTO advance_requests (employee_id, kind, period, amount_egp, status, created_by, decided_by, decided_at)
                                VALUES ($1,'advance','2026-03-01',18000,'confirmed',$1,$2,now()) RETURNING id`, [c.ids.e1, c.ids.owner]);
  advId = adv.rows[0].id;
});
after(async () => { await h.close(); });

const pay = async (id: string, m: string) => (await h.call(c.t.hr, 'GET', `/payroll/employee/${id}?month=${m}`)).body.payroll;

test('advance: old rule until a deduction is set; then hand-set amounts, two stages at most, never over or twice', async () => {
  assert.equal((await pay(c.ids.e1, '2026-03')).advances, 18000, 'default: whole advance in its month (as before)');
  const d1 = await h.call(c.t.hr, 'POST', `/advances/${advId}/deductions`, { month: '2026-03', amount: 10000 });
  assert.equal(d1.status, 201, JSON.stringify(d1.body));
  assert.equal(d1.body.advance.remaining, 8000);
  assert.equal((await pay(c.ids.e1, '2026-03')).advances, 10000);
  assert.equal((await h.call(c.t.hr, 'POST', `/advances/${advId}/deductions`, { month: '2026-03', amount: 1000 })).body.error.details.reason, 'already_deducted');
  assert.equal((await h.call(c.t.hr, 'POST', `/advances/${advId}/deductions`, { month: '2026-04', amount: 9000 })).body.error.details.reason, 'over_deduct');
  assert.equal((await h.call(c.t.hr, 'POST', `/advances/${advId}/deductions`, { month: '2026-04', amount: 8000 })).status, 201);
  assert.equal((await pay(c.ids.e1, '2026-04')).advances, 8000);
  // a third stage is refused even after cancelling nothing
  const third = await h.call(c.t.hr, 'POST', `/advances/${advId}/deductions`, { month: '2026-05', amount: 1 });
  assert.ok(['max_stages', 'over_deduct'].includes(third.body.error.details.reason));
  assert.equal((await h.call(c.t.e1, 'POST', `/advances/${advId}/deductions`, { month: '2026-05', amount: 1 })).status, 403);
  const mine = (await h.call(c.t.e1, 'GET', '/advances/mine')).body.advances;
  assert.equal(mine[0].deductions.length, 2);
  assert.equal(mine[0].remaining, 0);
});

test('batch: HR prepares (snapshot), submits; the manager approves — never the preparer', async () => {
  assert.equal((await h.call(c.t.e1, 'POST', '/payroll-batches', { month: '2026-03' })).status, 403);
  const b = await h.call(c.t.hr, 'POST', '/payroll-batches', { month: '2026-03' });
  assert.equal(b.status, 201, JSON.stringify(b.body));
  batchId = b.body.batch.id;
  const e1 = b.body.lines.find((l: any) => l.employeeId === c.ids.e1);
  assert.ok(e1 && e1.snapshot.advances === 10000, 'calculation details kept per employee');
  assert.equal((await h.call(c.t.hr, 'POST', '/payroll-batches', { month: '2026-03' })).body.error.details.reason, 'batch_exists');
  assert.equal((await h.call(c.t.hr, 'POST', `/payroll-batches/${batchId}/lines/${e1.id}/pay`, {})).status, 409, 'not approved yet');
  assert.equal((await h.call(c.t.hr, 'POST', `/payroll-batches/${batchId}/submit`, {})).status, 200);
  assert.equal((await h.call(c.t.hr, 'POST', `/payroll-batches/${batchId}/decision`, { decision: 'approve' })).status, 403);
  const ret = await h.call(tGm, 'POST', `/payroll-batches/${batchId}/decision`, { decision: 'return', reason: 'راجع الخصومات' });
  assert.equal(ret.body.batch.status, 'returned');
  assert.equal((await h.call(c.t.hr, 'POST', `/payroll-batches/${batchId}/refresh`, {})).status, 200);
  await h.call(c.t.hr, 'POST', `/payroll-batches/${batchId}/submit`, {});
  const ok = await h.call(tGm, 'POST', `/payroll-batches/${batchId}/decision`, { decision: 'approve' });
  assert.equal(ok.body.batch.status, 'approved');
});

test('paying a line: HR cashbox payout, partial allowed, never more than the net; employee confirms or disputes', async () => {
  const v = (await h.call(c.t.hr, 'GET', `/payroll-batches/${batchId}`)).body;
  const e2 = v.lines.find((l: any) => l.employeeId === c.ids.e2);
  const part = await h.call(c.t.hr, 'POST', `/payroll-batches/${batchId}/lines/${e2.id}/pay`, { amount: 100 });
  assert.equal(part.status, 200, JSON.stringify(part.body));
  let line = part.body.lines.find((l: any) => l.id === e2.id);
  assert.equal(line.status, 'partly_paid');
  assert.equal((await h.call(c.t.hr, 'POST', `/payroll-batches/${batchId}/lines/${e2.id}/pay`, { amount: line.remaining + 1 })).body.error.details.reason, 'over_pay');
  const rest = await h.call(c.t.hr, 'POST', `/payroll-batches/${batchId}/lines/${e2.id}/pay`, {});
  line = rest.body.lines.find((l: any) => l.id === e2.id);
  assert.equal(line.status, 'awaiting_confirmation', 'not treated as received until the employee confirms');
  assert.equal((await h.call(c.t.hr, 'POST', `/payroll-batches/${batchId}/lines/${e2.id}/pay`, {})).body.error.details.reason, 'already_paid');
  // the employee disputes one payment, confirms the other
  const [p1, p2] = line.payments;
  assert.equal((await h.call(c.t.e2, 'POST', `/payouts/${p1.id}/dispute`, { reason: 'استلمت 900 بس' })).status, 200);
  assert.equal((await h.call(c.t.e2, 'POST', `/payouts/${p2.id}/receive`, {})).status, 200);
  line = (await h.call(c.t.hr, 'GET', `/payroll-batches/${batchId}`)).body.lines.find((l: any) => l.id === e2.id);
  assert.equal(line.status, 'disputed');
  // settled: the employee confirms the disputed one
  assert.equal((await h.call(c.t.e2, 'POST', `/payouts/${p1.id}/receive`, {})).status, 200);
  line = (await h.call(c.t.hr, 'GET', `/payroll-batches/${batchId}`)).body.lines.find((l: any) => l.id === e2.id);
  assert.equal(line.status, 'confirmed');
  // own records for the employee
  const mine = (await h.call(c.t.e2, 'GET', '/payroll-batches/mine/lines')).body.lines;
  assert.equal(mine.length, 1);
  assert.equal(mine[0].payments.length, 2);
  // HR cashbox moved by what was paid
  assert.equal((await h.call(c.t.hr, 'GET', '/cash/summary')).body.hr.bookBalance, -line.net);
});

test('a paid month is closed for advance deductions', async () => {
  const adv2 = await h.db.query(`INSERT INTO advance_requests (employee_id, kind, period, amount_egp, status, created_by, decided_by, decided_at)
                                 VALUES ($1,'advance','2026-03-01',500,'confirmed',$1,$2,now()) RETURNING id`, [c.ids.e2, c.ids.owner]);
  const r = await h.call(c.t.hr, 'POST', `/advances/${adv2.rows[0].id}/deductions`, { month: '2026-03', amount: 500 });
  assert.equal(r.body.error.details.reason, 'month_closed');
  assert.equal((await h.call(c.t.hr, 'POST', `/advances/${adv2.rows[0].id}/deductions`, { month: '2026-04', amount: 500 })).status, 201);
});
