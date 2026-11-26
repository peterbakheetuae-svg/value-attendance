import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { harness, cast, PW, type Harness, confirmPayout, regrantAppRole } from './helpers.ts';

/**
 * Owner decisions 2026-11-26:
 *  F-1 — an advance / work expense is paid only against an approved request of the same employee and kind (API), and the
 *        database refuses an unlinked or mismatched one (proposed 093);
 *  F-2 — an approved (or waiting, or cancelled) payroll sheet and its lines cannot be changed or deleted, even by direct
 *        SQL as the table owner (proposed 093); the normal workflow keeps working.
 */
const SQL093 = readFileSync(new URL('../../db/proposed/093_payroll_sheet_protection.sql', import.meta.url), 'utf8');
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let tGm = '';

const request = async (employeeId: string, kind: 'advance' | 'work_expense', amount: number, status = 'confirmed', paidOutside = false) =>
  (await h.db.query(`INSERT INTO advance_requests (employee_id, kind, period, amount_egp, status, created_by, decided_by, decided_at, paid_outside)
                     VALUES ($1,$2,'2026-03-01',$3,$4,$1,$5,now(),$6) RETURNING id`, [employeeId, kind, amount, status, c.ids.owner, paidOutside])).rows[0].id as string;
const payout = (body: Record<string, unknown>) => h.call(c.t.hr, 'POST', '/payouts', { month: '2026-03', ...body });
const reason = (r: any) => r.body?.error?.details?.reason;
const dbRefuses = async (sql: string, params: unknown[] = []) => {
  await assert.rejects(h.db.query(sql, params), (e: any) => e.code === '23514', sql);
};

before(async () => {
  h = await harness('2026-03-10T08:00:00Z', { migrationsExcept: [] }); c = await cast(h);
  await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE code = 'GM1'`);
  tGm = await h.login('GM1', PW);
  for (const [id, sal] of [[c.ids.e1, 10000], [c.ids.e2, 8000]] as const) {
    await h.db.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1, $2, $3)`, [id, sal, c.ids.owner]);
  }
  await h.db.query(`UPDATE employees SET attendance_exempt = true WHERE id = ANY($1)`, [[c.ids.e1, c.ids.e2]]);
});
after(async () => { await h.close(); });

// ------------------------------------------------------------------------------------------------ F-1, API (before 093)
test('F-1 API: no request → refused; the request decides employee, kind, status and amount', async () => {
  for (const kind of ['advance', 'work_expense']) {
    const r = await payout({ employeeId: c.ids.e1, kind, amount: 100 });
    assert.equal(r.status, 422); assert.equal(reason(r), 'request_required');
  }
  const mine = await request(c.ids.e1, 'advance', 500);
  assert.equal((await payout({ employeeId: c.ids.e2, kind: 'advance', amount: 500, advanceId: mine })).status, 400, 'another employee');
  assert.equal((await payout({ employeeId: c.ids.e1, kind: 'work_expense', amount: 500, advanceId: mine })).status, 400, 'another kind');
  assert.equal((await payout({ employeeId: c.ids.e1, kind: 'advance', amount: 499, advanceId: mine })).status, 400, 'another amount');
  for (const st of ['pending', 'rejected', 'cancelled']) {
    const x = await request(c.ids.e1, 'advance', 200, st);
    assert.equal((await payout({ employeeId: c.ids.e1, kind: 'advance', amount: 200, advanceId: x })).status, 400, st);
  }
  const outside = await request(c.ids.e1, 'advance', 300, 'confirmed', true);
  assert.equal((await payout({ employeeId: c.ids.e1, kind: 'advance', amount: 300, advanceId: outside })).status, 409, 'handed over outside');
  assert.equal((await payout({ employeeId: c.ids.e1, kind: 'fund', amount: 500, advanceId: mine })).status, 400, 'a request never rides on a cash handover');
  const ok = await payout({ employeeId: c.ids.e1, kind: 'advance', amount: 500, advanceId: mine });
  assert.equal(ok.status, 201, JSON.stringify(ok.body));
  assert.equal((await payout({ employeeId: c.ids.e1, kind: 'advance', amount: 500, advanceId: mine })).status, 409, 'paid once');
});

test('F-1 API: the same request fired in parallel → one payment', async () => {
  const x = await request(c.ids.e2, 'work_expense', 750);
  const rs = await Promise.all(Array.from({ length: 6 }, () => payout({ employeeId: c.ids.e2, kind: 'work_expense', amount: 750, advanceId: x })));
  assert.equal(rs.filter((r) => r.status === 201).length, 1, rs.map((r) => r.status).join(','));
  assert.equal(Number((await h.db.query(`SELECT count(*) FROM payouts WHERE advance_id = $1`, [x])).rows[0].count), 1);
});

// ---------------------------------------------------------------------------------- apply 093 (historical row kept)
let historic = '';
test('093 applies on a database that already holds an unlinked advance payment — which stays as it is and still works', async () => {
  // a payment made before the rule (inserted directly, as older versions allowed): preserved, never re-checked
  historic = (await h.db.query(`INSERT INTO payouts (employee_id, kind, amount_egp, period, note, created_by)
                                VALUES ($1,'advance',123,'2026-03-01','older version',$2) RETURNING id`, [c.ids.e1, c.ids.hr])).rows[0].id;
  await h.db.tx(async (q) => { await q.query(SQL093); });
  await h.db.tx(async (q) => { await q.query(SQL093); }); // a second run changes nothing
  await regrantAppRole(h);
  const before = (await h.db.query(`SELECT to_jsonb(p) AS j FROM payouts p WHERE id = $1`, [historic])).rows[0].j;
  assert.equal(before.advance_id, null);
  // its normal life goes on: the employee's code confirms it
  const r = await confirmPayout(h, c.t.e1, c.t.hr, historic);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal((await h.db.query(`SELECT status FROM payouts WHERE id = $1`, [historic])).rows[0].status, 'received');
});

test('F-1 database: an unlinked or mismatched advance / work-expense payment is refused even by direct SQL', async () => {
  const ins = `INSERT INTO payouts (employee_id, kind, amount_egp, period, note, created_by, advance_id) VALUES ($1,$2,$3,'2026-03-01','sql',$4,$5)`;
  await dbRefuses(ins, [c.ids.e1, 'advance', 50, c.ids.hr, null]);
  await dbRefuses(ins, [c.ids.e1, 'work_expense', 50, c.ids.hr, null]);
  const other = await request(c.ids.e2, 'advance', 50);
  await dbRefuses(ins, [c.ids.e1, 'advance', 50, c.ids.hr, other]);                      // another employee's request
  await dbRefuses(ins, [c.ids.e2, 'work_expense', 50, c.ids.hr, other]);                 // another kind
  await dbRefuses(ins, [c.ids.e2, 'advance', 50, c.ids.hr, await request(c.ids.e2, 'advance', 50, 'pending')]);
  await dbRefuses(ins, [c.ids.e2, 'commission', 50, c.ids.hr, other]);                   // a request on another kind
  // the API path still pays a valid request with 093 installed
  assert.equal((await payout({ employeeId: c.ids.e2, kind: 'advance', amount: 50, advanceId: other })).status, 201);
});

// ------------------------------------------------------------------------------------------------ F-2 (093 installed)
let batchId = ''; let lineId = '';
test('F-2 workflow still works with 093: prepare, refresh, submit, return, refresh, submit, approve, pay a line', async () => {
  const b = await h.call(c.t.hr, 'POST', '/payroll-batches', { month: '2026-03' });
  assert.equal(b.status, 201, JSON.stringify(b.body));
  batchId = b.body.batch.id; lineId = b.body.lines.find((l: any) => l.employeeId === c.ids.e2).id;
  assert.equal((await h.call(c.t.hr, 'POST', `/payroll-batches/${batchId}/refresh`, {})).status, 200);
  assert.equal((await h.call(c.t.hr, 'POST', `/payroll-batches/${batchId}/submit`, {})).status, 200);
  assert.equal((await h.call(tGm, 'POST', `/payroll-batches/${batchId}/decision`, { decision: 'return', reason: 'راجع' })).status, 200);
  const re = await h.call(c.t.hr, 'POST', `/payroll-batches/${batchId}/refresh`, {});
  assert.equal(re.status, 200, JSON.stringify(re.body));
  lineId = re.body.lines.find((l: any) => l.employeeId === c.ids.e2).id;
  assert.equal((await h.call(c.t.hr, 'POST', `/payroll-batches/${batchId}/submit`, {})).status, 200);
  assert.equal((await h.call(tGm, 'POST', `/payroll-batches/${batchId}/decision`, { decision: 'approve' })).status, 200);
  const p = await h.call(c.t.hr, 'POST', `/payroll-batches/${batchId}/lines/${lineId}/pay`, { amount: 1000 });
  assert.equal(p.status, 200, JSON.stringify(p.body));
});

test('F-2 database: an approved sheet and its lines cannot be changed, moved or deleted — not even by the table owner', async () => {
  const lineBefore = (await h.db.query(`SELECT to_jsonb(l) AS j FROM payroll_batch_lines l WHERE id = $1`, [lineId])).rows[0].j;
  await dbRefuses(`UPDATE payroll_batch_lines SET net_egp = net_egp + 1 WHERE id = $1`, [lineId]);
  await dbRefuses(`UPDATE payroll_batch_lines SET snapshot = '{}'::jsonb WHERE id = $1`, [lineId]);
  await dbRefuses(`DELETE FROM payroll_batch_lines WHERE id = $1`, [lineId]);
  await dbRefuses(`INSERT INTO payroll_batch_lines (batch_id, employee_id, snapshot, net_egp) VALUES ($1,$2,'{}',1)`, [batchId, c.ids.e3]);
  await dbRefuses(`UPDATE payroll_batches SET status = 'draft' WHERE id = $1`, [batchId]);
  await dbRefuses(`UPDATE payroll_batches SET status = 'cancelled' WHERE id = $1`, [batchId]);
  await dbRefuses(`UPDATE payroll_batches SET decided_by = NULL WHERE id = $1`, [batchId]);
  await dbRefuses(`UPDATE payroll_batches SET period = '2026-04-01' WHERE id = $1`, [batchId]);
  await dbRefuses(`DELETE FROM payroll_batches WHERE id = $1`, [batchId]);
  const lineAfter = (await h.db.query(`SELECT to_jsonb(l) AS j FROM payroll_batch_lines l WHERE id = $1`, [lineId])).rows[0].j;
  assert.deepEqual(lineAfter, lineBefore, 'values untouched');
  assert.equal((await h.db.query(`SELECT status FROM payroll_batches WHERE id = $1`, [batchId])).rows[0].status, 'approved');
});

test('F-2 database: a sheet waiting for approval has frozen lines; only the approved transitions exist; a draft cannot be born approved', async () => {
  const b = await h.call(c.t.hr, 'POST', '/payroll-batches', { month: '2026-02' });
  assert.equal(b.status, 201, JSON.stringify(b.body));
  const id = b.body.batch.id; const line = b.body.lines[0].id;
  assert.equal((await h.call(c.t.hr, 'POST', `/payroll-batches/${id}/submit`, {})).status, 200);
  await dbRefuses(`UPDATE payroll_batch_lines SET net_egp = 1 WHERE id = $1`, [line]);
  await dbRefuses(`DELETE FROM payroll_batch_lines WHERE batch_id = $1`, [id]);
  await dbRefuses(`UPDATE payroll_batches SET status = 'approved' WHERE id = $1`, [id]);        // no approver recorded
  await dbRefuses(`UPDATE payroll_batches SET status = 'cancelled' WHERE id = $1`, [id]);       // waiting → cancelled is not a step
  // the API refuses the same (unchanged), the approval still works
  assert.equal((await h.call(c.t.hr, 'POST', `/payroll-batches/${id}/refresh`, {})).status, 409);
  assert.equal((await h.call(tGm, 'POST', `/payroll-batches/${id}/decision`, { decision: 'approve' })).status, 200);
  await dbRefuses(`INSERT INTO payroll_batches (period, prepared_by, status, decided_by, decided_at) VALUES ('2025-12-01',$1,'approved',$2,now())`,
    [c.ids.hr, c.ids.owner]);
});

test('F-2: a draft can still be cancelled through the API, and a cancelled sheet is final', async () => {
  const b = await h.call(c.t.hr, 'POST', '/payroll-batches', { month: '2026-01' });
  assert.equal(b.status, 201, JSON.stringify(b.body));
  assert.equal((await h.call(c.t.hr, 'POST', `/payroll-batches/${b.body.batch.id}/cancel`, {})).status, 200);
  await dbRefuses(`UPDATE payroll_batches SET status = 'draft' WHERE id = $1`, [b.body.batch.id]);
});
