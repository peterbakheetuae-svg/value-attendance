import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { harness, cast, type Harness } from './helpers.ts';

/**
 * db/ops/2026-11-23-clear-attendance-finance-former-employees.sql (the owner's clean-up, NOT run anywhere real):
 * removes ONLY attendance, every financial transaction and the «تم التصفيه» / inactive employees; everything else stays.
 * Run on synthetic throw-away databases — once on today's schema, once with the proposed 066 / 083–087 applied.
 */
const SCRIPT = readFileSync(new URL('../../db/ops/2026-11-23-clear-attendance-finance-former-employees.sql', import.meta.url), 'utf8');
const proposed = (n: string) => readFileSync(new URL(`../../db/proposed/${n}`, import.meta.url), 'utf8');
const ATTENDANCE = ['attendance', 'attendance_breaks', 'attendance_corrections', 'attendance_selfies'];
const MONEY = ['cash_receipts', 'cash_expenses', 'cash_transfers', 'cash_adjustments', 'cash_bank_moves', 'cash_attachments', 'payouts',
  'advance_requests', 'advance_deductions', 'salary_adjustments', 'payroll_batches', 'payroll_batch_lines', 'commission_entitlements',
  'commission_requests', 'unit_sales', 'sale_installments', 'ex_payments', 'ex_installments', 'ex_commission_transfers'];

async function seed(h: Harness, c: Awaited<ReturnType<typeof cast>>) {
  // attendance of active and soon-removed employees
  for (const t of [c.t.e1, c.t.e2, c.t.e3]) { const r = await h.call(t, 'POST', '/attendance/check-in', {}); assert.ok([200, 201].includes(r.status), JSON.stringify(r.body)); }
  // money: an opening balance, a receipt, an expense, an advance (work expense)
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/adjustments', { cashbox: 'office', kind: 'opening', amount: 50000, reason: 'رصيد افتتاحي' })).status, 201);
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'reservation', amount: 2000, payerName: 'عميل', purpose: 'حجز', clientRef: randomUUID() })).status, 201);
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/expenses', { cashbox: 'office', amount: 50, category: 'ضيافة', reason: 'قهوة', beneficiary: 'محل', clientRef: randomUUID() })).status, 201);
  assert.equal((await h.call(c.t.acc, 'POST', '/advances', { kind: 'work_expense', amount: 250, period: '2026-03-01', employeeId: c.ids.e1 })).status, 201);
  // kept activity: an outing of an active employee and of a soon-removed one, a request of a soon-removed one
  assert.equal((await h.call(c.t.e1, 'POST', '/outings', { kind: 'visit', expectedReturn: '17:00', reason: 'معاينة عميل' })).status, 201);
  assert.equal((await h.call(c.t.e3, 'POST', '/outings', { kind: 'visit', expectedReturn: '17:00', reason: 'معاينة' })).status, 201);
  // e2 → inactive, e3 → «تم التصفيه» (still active in status, like the app's legacy field)
  await h.db.query(`UPDATE employees SET status = 'inactive' WHERE id = $1`, [c.ids.e2]);
  await h.db.query(`UPDATE employees SET legacy_fields = COALESCE(legacy_fields, '{}'::jsonb) || '{"status":"تم التصفيه"}' WHERE id = $1`, [c.ids.e3]);
  // a removed employee who never did anything (no audit trail) is deleted outright
  await h.db.query(`INSERT INTO employees (code, full_name, role_key, job_title, password_hash, status, email, phone)
    VALUES ('GONE1', 'موظف مستقيل', 'sales_employee', 'مستشار', '!x', 'inactive', 'gone@value.test', '0100')`);
}

const count = async (h: Harness, t: string) => Number((await h.db.query(`SELECT count(*) n FROM ${t}`)).rows[0].n);
async function runScript(h: Harness) {
  return h.db.tx(async (q) => {
    await q.query(SCRIPT);
    return (await q.query(`SELECT step, what, rows::int FROM c_report ORDER BY step, what`)).rows as { step: number; what: string; rows: number }[];
  });
}

async function check(h: Harness, c: Awaited<ReturnType<typeof cast>>, extraMoney: string[]) {
  await seed(h, c);
  const before = {
    leads: await count(h, 'leads'), audit: await count(h, 'audit_log'), fixed: await count(h, 'fixed_expenses'),
    custody: await count(h, 'custody_items'), owners: await count(h, 'company_owners'), roles: await count(h, 'roles'),
    activeOutings: Number((await h.db.query(`SELECT count(*) n FROM outing_requests WHERE employee_id = $1`, [c.ids.e1])).rows[0].n),
    money: await count(h, 'cash_receipts') + await count(h, 'cash_expenses') + await count(h, 'cash_adjustments'),
  };
  assert.ok(before.money >= 3 && (await count(h, 'attendance')) >= 3, 'seeded');

  const report = await runScript(h);
  for (const t of [...ATTENDANCE, ...MONEY, ...extraMoney]) assert.equal(await count(h, t), 0, `${t} emptied`);
  assert.ok(report.find((r) => r.what === 'attendance')!.rows >= 3);

  // the active employees are untouched, with their outings and their leave balances
  const e1 = (await h.db.query(`SELECT full_name, status FROM employees WHERE id = $1`, [c.ids.e1])).rows[0];
  assert.deepEqual(e1, { full_name: 'موظف ١', status: 'active' });
  assert.equal(Number((await h.db.query(`SELECT count(*) n FROM outing_requests WHERE employee_id = $1`, [c.ids.e1])).rows[0].n), before.activeOutings);
  assert.equal(Number((await h.db.query(`SELECT count(*) n FROM leave_balances WHERE employee_id = $1`, [c.ids.e1])).rows[0].n), 1);
  for (const id of [c.ids.owner, c.ids.hr, c.ids.acc, c.ids.sm1, c.ids.e1, c.ids.solo])
    assert.equal(Number((await h.db.query(`SELECT count(*) n FROM employees WHERE id = $1 AND full_name <> 'موظف سابق'`, [id])).rows[0].n), 1);

  // the removed ones: gone, or an anonymous signed-out stub (kept only because the append-only audit log names them)
  for (const id of [c.ids.e2, c.ids.e3]) {
    const r = (await h.db.query(`SELECT full_name, email, phone, password_hash, status FROM employees WHERE id = $1`, [id])).rows[0];
    if (r) assert.deepEqual(r, { full_name: 'موظف سابق', email: null, phone: null, password_hash: '!removed', status: 'inactive' });
    for (const [t, col] of [['sessions', 'employee_id'], ['outing_requests', 'employee_id'], ['leave_balances', 'employee_id'], ['notifications', 'recipient_id'], ['requests', 'employee_id']])
      assert.equal(Number((await h.db.query(`SELECT count(*) n FROM ${t} WHERE ${col} = $1`, [id])).rows[0].n), 0, `${t} of a removed employee`);
  }
  assert.equal(await count(h, `employees WHERE code = 'GONE1'`), 0, 'a removed employee nothing points at is deleted');

  // the app's «never deleted» guards are back on after it
  await assert.rejects(() => h.db.query(`DELETE FROM outing_requests`), /never deleted/);
  const off = (await h.db.query(`SELECT count(*) n FROM pg_trigger WHERE NOT tgisinternal AND tgenabled = 'D'`)).rows[0].n;
  assert.equal(Number(off), 0, 'no trigger left disabled');
  // everything else stays
  assert.equal(await count(h, 'leads'), before.leads);
  assert.equal(await count(h, 'audit_log'), before.audit, 'the audit log is never touched');
  assert.equal(await count(h, 'fixed_expenses'), before.fixed);
  assert.equal(await count(h, 'custody_items'), before.custody);
  assert.equal(await count(h, 'company_owners'), before.owners);
  assert.equal(await count(h, 'roles'), before.roles);
  // the app still works after it: balances are zero, a new receipt / check-in goes through
  const s = await h.call(c.t.owner, 'GET', '/cash/summary');
  assert.equal(s.status, 200);
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'reservation', amount: 100, payerName: 'عميل', purpose: 'حجز', clientRef: randomUUID() })).status, 201);
  const out = await h.call(c.t.e1, 'POST', '/attendance/check-out', {});
  assert.ok(out.status >= 400 && out.status < 500, `no open check-in is left (${out.status})`);
  return report;
}

test('clean-up 2026-11-23 on today\'s schema: only attendance, money and «تم التصفيه» / inactive employees go', async () => {
  const h = await harness('2026-03-10T08:00:00Z');
  try { await check(h, await cast(h), []); } finally { await h.close(); }
});

test('clean-up 2026-11-23 after the proposed 066 / 083–087: their money tables go too, their settings stay', async () => {
  const h = await harness('2026-03-10T08:00:00Z');
  try {
    const c = await cast(h);
    for (const f of ['066_fine_grained_permissions.sql', '083_financial_year_closing.sql', '084_marketing_company_payment_otp.sql'])
      await h.db.tx(async (q) => { await q.query(proposed(f)); });
    await h.db.tx(async (q) => { await q.query(`SET LOCAL valunivo.owner_share_baseline = '2026-01-01'`); await q.query(proposed('085_financial_integrity.sql')); });
    for (const f of ['086_expense_classification.sql', '087_brokerage_deals.sql']) await h.db.tx(async (q) => { await q.query(proposed(f)); });
    const groups = (await h.db.query(`INSERT INTO expense_groups (name, created_by) VALUES ('تشغيل', $1) RETURNING id`, [c.ids.owner])).rows.length;
    await check(h, c, ['brokerage_deals', 'brokerage_shares', 'fy_closings', 'fy_issues', 'fy_opening_balances', 'fy_reconciliations', 'fy_review_items']);
    assert.equal(await count(h, 'expense_groups'), groups, 'expense groups (settings) stay');
  } finally { await h.close(); }
});

test('clean-up 2026-11-23 refuses (and changes nothing) when no active owner would be left', async () => {
  const h = await harness('2026-03-10T08:00:00Z');
  try {
    const c = await cast(h);
    await h.db.query(`UPDATE employees SET status = 'inactive' WHERE role_key = 'owner'`);
    await assert.rejects(() => runScript(h), /no active owner would be left/);
    assert.equal(await count(h, `employees WHERE id = '${c.ids.owner}'`), 1);
  } finally { await h.close(); }
});
