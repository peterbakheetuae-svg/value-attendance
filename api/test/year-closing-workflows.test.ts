import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { harness, cast, PW, type Harness, confirmPayout } from './helpers.ts';
import { forgetPermissionKeys } from '../src/auth/context.ts';

/**
 * 083's closed-period guards against the real workflows, through the API (throwaway database; 083 and 066 applied here
 * only). 2025 is marked closed directly (a frozen closing row) so each workflow can be tried on a closed month and on an
 * open one side by side: the closed one is refused, the open one works as before; December's salary is paid in January.
 * Then a closed year's records — reconciliations, notes, the closing log, the cash lines — for people with different
 * permissions: the detail of an area someone may not see is withheld from the answer, the stored records stay complete.
 */
const SQL083 = readFileSync(new URL('../../db/proposed/083_financial_year_closing.sql', import.meta.url), 'utf8');
const SQL066 = readFileSync(new URL('../../db/proposed/066_fine_grained_permissions.sql', import.meta.url), 'utf8');
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let tGm = ''; let gmId = '';
const JPG = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(64, 3)]).toString('base64');
const ids: Record<string, string> = {};

before(async () => {
  h = await harness('2026-01-10T08:00:00Z'); c = await cast(h);
  const gm = await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  gmId = gm.body.id;
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE id = $1`, [gmId]);
  tGm = await h.login('GM1', PW);
  for (const [id, sal] of [[c.ids.e1, 10000], [c.ids.e2, 8000]] as const) {
    await h.db.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1, $2, $3)`, [id, sal, c.ids.owner]);
  }
  await h.db.query(`UPDATE employees SET attendance_exempt = true, joining_date = '2025-01-01' WHERE id IN ($1, $2)`, [c.ids.e1, c.ids.e2]);
  await h.db.tx(async (q) => { await q.query(SQL083); });

  // two approved commissions: December 2025 and January 2026
  const p = await h.call(tGm, 'POST', '/commissions/projects', { name: 'Kayan', totalPct: 1.5, salesPct: 0.3, managerPct: 0.4, companyPct: 0.8 });
  assert.equal(p.status, 201, JSON.stringify(p.body));
  for (const [k, unit, month] of [['com25', 'A-1', '2025-12'], ['com26', 'A-2', '2026-01']]) {
    const r = await h.call(c.t.e1, 'POST', '/commissions/requests', { projectId: p.body.project.id, unitNo: unit, pricePerM2: 30000, areaM2: 100 });
    assert.equal(r.status, 201, JSON.stringify(r.body));
    const d = await h.call(tGm, 'POST', `/commissions/requests/${r.body.request.id}/decision`, { decision: 'approve', month });
    assert.equal(d.status, 200, JSON.stringify(d.body));
    ids[k] = r.body.request.id;
  }
  // an approved advance with two hand-set deductions: December 2025 and January 2026
  const adv = await h.db.query(`INSERT INTO advance_requests (employee_id, kind, period, amount_egp, status, created_by, decided_by, decided_at)
                                VALUES ($1,'advance','2025-12-01',6000,'confirmed',$1,$2,now()) RETURNING id`, [c.ids.e2, c.ids.owner]);
  for (const [k, month] of [['ded25', '2025-12'], ['ded26', '2026-01']]) {
    const d = await h.call(c.t.hr, 'POST', `/advances/${adv.rows[0].id}/deductions`, { month, amount: 3000 });
    assert.equal(d.status, 201, JSON.stringify(d.body));
  }
  const ded = await h.db.query(`SELECT id, to_char(period, 'YYYY-MM') AS m FROM advance_deductions ORDER BY period`);
  ids.ded25 = ded.rows.find((x) => x.m === '2025-12').id; ids.ded26 = ded.rows.find((x) => x.m === '2026-01').id;
  // two payroll sheets prepared and sent for approval: December 2025 and January 2026
  for (const [k, month] of [['batch25', '2025-12'], ['batch26', '2026-01']]) {
    const b = await h.call(c.t.hr, 'POST', '/payroll-batches', { month });
    assert.equal(b.status, 201, JSON.stringify(b.body));
    ids[k] = b.body.batch.id;
    assert.equal((await h.call(c.t.hr, 'POST', `/payroll-batches/${ids[k]}/submit`, {})).status, 200);
  }
  // 2025 is closed (a frozen closing, as /close leaves it)
  await h.db.query(`INSERT INTO fy_closings (fiscal_year, version, status, started_by, approved_by, approved_at, approved_hash, closed_by, closed_at, snapshot, snapshot_hash)
                    VALUES (2025, 1, 'closed', $1, $1, now(), 'h', $1, now(), '{"figures":{},"review":{}}', 'h')`, [c.ids.owner]);
});
after(async () => { await h.close(); });

const refusedClosed = (r: { status: number; body: any }, what: string) => {
  assert.equal(r.status, 409, `${what}: ${JSON.stringify(r.body)}`);
  assert.match(r.body.error.message, /2025 مقفولة/, what);
};

test('cancelling an approved commission: refused for a closed month, works for an open one', async () => {
  refusedClosed(await h.call(c.t.owner, 'POST', `/commissions/requests/${ids.com25}/void`, { reason: 'غلطة في الوحدة' }), 'void 2025-12');
  assert.equal((await h.db.query(`SELECT status FROM commission_requests WHERE id = $1`, [ids.com25])).rows[0].status, 'approved', 'nothing half-done');
  const ok = await h.call(c.t.owner, 'POST', `/commissions/requests/${ids.com26}/void`, { reason: 'غلطة في الوحدة' });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
});

test('cancelling an advance deduction: refused for a closed month, works for an open one', async () => {
  refusedClosed(await h.call(c.t.hr, 'POST', `/advances/deductions/${ids.ded25}/cancel`, {}), 'cancel 2025-12');
  const ok = await h.call(c.t.hr, 'POST', `/advances/deductions/${ids.ded26}/cancel`, {});
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
});

test('approving a payroll sheet: refused for a closed month, works for an open one; no new sheet inside the closed year', async () => {
  refusedClosed(await h.call(tGm, 'POST', `/payroll-batches/${ids.batch25}/decision`, { decision: 'approve' }), 'approve 2025-12');
  const ok = await h.call(tGm, 'POST', `/payroll-batches/${ids.batch26}/decision`, { decision: 'approve' });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  refusedClosed(await h.call(c.t.hr, 'POST', '/payroll-batches', { month: '2025-11' }), 'new sheet 2025-11');
});

test('recording past advances (a request and the owner\'s «سلفة قديمة»): refused inside the closed year, accepted after it', async () => {
  refusedClosed(await h.call(c.t.e1, 'POST', '/advances', { kind: 'advance', amount: 500, period: '2025-06-01', note: 'سلفة قديمة', attachment: JPG }), 'request 2025-06');
  const r26 = await h.call(c.t.e1, 'POST', '/advances', { kind: 'advance', amount: 500, period: '2026-02-01', note: 'سلفة', attachment: JPG });
  assert.equal(r26.status, 201, JSON.stringify(r26.body));
  refusedClosed(await h.call(c.t.owner, 'POST', '/admin/opening-advance', { employeeId: c.ids.e2, amount: 1000, month: '2025-06' }), 'opening advance 2025-06');
  const o26 = await h.call(c.t.owner, 'POST', '/admin/opening-advance', { employeeId: c.ids.e2, amount: 1000, month: '2026-01' });
  assert.ok(o26.status < 300, JSON.stringify(o26.body));
});

test('December\'s salary handed over in January: paid and received (a payment of the open year)', async () => {
  const p = await h.call(c.t.hr, 'POST', '/payouts/salary', { employeeId: c.ids.e1, month: '2025-12' });
  assert.equal(p.status, 201, JSON.stringify(p.body));
  assert.equal((await confirmPayout(h, c.t.e1, c.t.hr, p.body.payout.id)).status, 200);
  const x = (await h.db.query(`SELECT to_char(period, 'YYYY-MM') AS m, status, (received_at AT TIME ZONE 'Africa/Cairo')::date::text AS d FROM payouts WHERE id = $1`,
    [p.body.payout.id])).rows[0];
  assert.deepEqual([x.m, x.status, x.d.slice(0, 4)], ['2025-12', 'received', '2026'], 'December\'s salary, dated when received');
  // a payment that belongs to an open month (a work expense of January) — as before
  const j = await h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.e2, kind: 'work_expense', amount: 300, month: '2026-01', note: 'مواصلات' });
  assert.equal(j.status, 201, JSON.stringify(j.body));
  assert.equal((await confirmPayout(h, c.t.e2, c.t.hr, j.body.payout.id)).status, 200);
});

test('a closed year\'s records by permission: reconciliations, notes, issues, the closing log, cash lines', async () => {
  // a 2026 review with a partner reconciliation, an employees note, a manual partner issue — then 066 and four kinds of viewer
  assert.equal((await h.call(tGm, 'POST', '/closing/2026/start', {})).status, 201);
  const rec = await h.call(tGm, 'POST', '/closing/2026/reconciliations', { type: 'partner', source: 'cash_expenses', sourceId: 'x', amount: 2500, reason: 'سحب شريك اتسجل في البنك' });
  assert.equal(rec.status, 201);
  const recT = await h.call(tGm, 'POST', '/closing/2026/reconciliations', { type: 'treasury', source: 'cash_ledger', sourceId: 'hr', amount: -50, reason: 'فكة ناقصة في الجرد' });
  assert.equal(recT.status, 201);
  assert.equal((await h.call(tGm, 'POST', '/closing/2026/items', { key: 'partners.withdrawals', status: 'needs_attention', note: 'سحب 2500 من الشريك الأول' })).status, 200);
  assert.equal((await h.call(tGm, 'POST', '/closing/2026/items', { key: 'employees.salaries', status: 'needs_attention', note: 'مرتب موظف ١ اتصرف مرتين' })).status, 200);
  assert.equal((await h.call(tGm, 'POST', '/closing/2026/issues', { category: 'partners', severity: 'review', description: 'الشريك سحب أكتر من نصيبه', amount: 7000 })).status, 201);
  await h.db.tx(async (q) => { await q.query(SQL066); });
  forgetPermissionKeys();
  const deny = async (keys: string[]) => {
    await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [gmId]).catch(() => {});
    for (const k of keys) await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, $2, false)`, [gmId, k]);
  };
  const look = async () => {
    const r = (await h.call(tGm, 'GET', '/closing/2026')).body;
    const audit = (await h.call(tGm, 'GET', '/closing/2026/audit')).body.events;
    const item = (k: string) => r.checklist.flatMap((x: any) => x.items).find((i: any) => i.key === k);
    return { r, audit, item, text: JSON.stringify({ r: { recs: r.reconciliations, issues: r.issues, checklist: r.checklist }, audit }) };
  };

  // 1) the main cashbox only: nothing of the partners or the salaries
  await deny(['finance.company_income', 'cash.owner_funds', 'exclusive.view_finance', 'employee.salary_read']);
  let v = await look();
  const pr = v.r.reconciliations.find((x: any) => x.type === 'partner');
  assert.deepEqual([pr.amount, pr.redacted], [null, true]);
  assert.ok(!v.text.includes('سحب شريك اتسجل في البنك') && !v.text.includes('2500') && !v.text.includes('7000'), 'no partner amount / reason anywhere');
  assert.ok(!v.text.includes('الشريك سحب أكتر من نصيبه') && !v.text.includes('مرتب موظف ١ اتصرف مرتين'));
  assert.equal(v.r.reconciliations.find((x: any) => x.type === 'treasury').reason, 'فكة ناقصة في الجرد', 'a cashbox reconciliation stays visible');
  assert.equal(v.item('partners.withdrawals').status, 'needs_attention', 'what happened stays visible');
  assert.ok(v.audit.some((e: any) => e.action === 'closing.reconciliation' && e.after.redacted));
  assert.ok(v.audit.some((e: any) => e.action === 'closing.reconciliation' && e.after.reason === 'فكة ناقصة في الجرد'));
  // 2) + the owners' funds: the partners' detail comes back, the salaries stay hidden
  await deny(['finance.company_income', 'exclusive.view_finance', 'employee.salary_read']);
  v = await look();
  assert.ok(v.text.includes('سحب شريك اتسجل في البنك') && v.text.includes('الشريك سحب أكتر من نصيبه'));
  assert.ok(!v.text.includes('مرتب موظف ١ اتصرف مرتين'));
  // 3) + the salaries, without the owners' funds
  await deny(['finance.company_income', 'cash.owner_funds', 'exclusive.view_finance']);
  v = await look();
  assert.ok(v.text.includes('مرتب موظف ١ اتصرف مرتين') && !v.text.includes('سحب شريك اتسجل في البنك'));
  // cash lines: an owner's withdrawal / an employee's payout without its amount for whoever may not see it
  const lines = (await h.call(tGm, 'GET', '/closing/2026/transactions?kind=ledger')).body.rows;
  const pay = lines.filter((x: any) => x.source === 'payouts');
  assert.ok(pay.length > 0 && pay.every((x: any) => x.amount !== null), `salaries visible with «عرض المرتبات» ${JSON.stringify(lines).slice(0, 600)}`);
  await deny(['employee.salary_read']);
  const hid = (await h.call(tGm, 'GET', '/closing/2026/transactions?kind=ledger')).body.rows.filter((x: any) => x.source === 'payouts');
  assert.ok(hid.length > 0 && hid.every((x: any) => x.amount === null && x.redacted === true));
  // 4) the owner: everything; and the stored records were never touched
  const o = JSON.stringify((await h.call(c.t.owner, 'GET', '/closing/2026')).body);
  assert.ok(o.includes('سحب شريك اتسجل في البنك') && o.includes('مرتب موظف ١ اتصرف مرتين') && o.includes('الشريك سحب أكتر من نصيبه'));
  const stored = (await h.db.query(`SELECT reason, amount FROM fy_reconciliations WHERE id = $1`, [rec.body.reconciliation.id])).rows[0];
  assert.deepEqual([stored.reason, Number(stored.amount)], ['سحب شريك اتسجل في البنك', 2500]);
});
