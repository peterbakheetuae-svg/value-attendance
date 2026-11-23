import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { harness, cast, type Harness } from './helpers.ts';
import { forgetPermissionKeys } from '../src/auth/context.ts';

/**
 * Expense groups and categories (PROPOSED migration 086) — classification metadata only:
 * groups / categories CRUD, archive / reactivate, one active name, a category reused by many groups without copies,
 * classified + unclassified expenses, totals counted once, date / status filters, box-scoped visibility,
 * metadata-only (re)classification with an audit trail, allowed in a closed fiscal year; before 086 nothing changes.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
const file = (n: string) => readFileSync(new URL(`../../db/proposed/${n}`, import.meta.url), 'utf8');
const run = (sql: string) => h.db.tx(async (q) => { await q.query(sql); });
const bal = async (box: string) => Number((await h.db.query(`SELECT COALESCE(sum(amount), 0) s FROM cash_ledger WHERE cashbox = $1`, [box])).rows[0].s);

before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
});
after(async () => { await h.close(); });

test('before 086: the app keeps working exactly as today; the classification endpoints say it is not installed', async () => {
  const l = await h.call(c.t.owner, 'GET', '/cash/expense-classes');
  assert.equal(l.status, 200); assert.equal(l.body.installed, false);
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/expense-classes/groups', { name: 'تشغيل المكتب' })).body.error.details.reason, 'classification_not_installed');
  const e = await h.call(c.t.owner, 'POST', '/cash/expenses', { cashbox: 'office', amount: 100, category: 'قهوة', reason: 'ضيافة', beneficiary: 'محل' });
  assert.equal(e.status, 201, JSON.stringify(e.body));
  assert.equal(e.body.expense.expenseGroupId, null);
});

test('086: groups and categories — create, edit, archive, reactivate, search, one active name, a category reused by many groups', async () => {
  // an individual exception on cash.office (the accountant allowed it alone) must carry over to the new keys
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'cash.office', true)`, [c.ids.acc]);
  forgetPermissionKeys();
  const before = { owner: (await h.call(c.t.owner, 'GET', '/me')).body.permissions as string[], hr: (await h.call(c.t.hr, 'GET', '/me')).body.permissions as string[] };
  // the expenses recorded before 086 — every column they had and the balances — must be exactly the same after it
  const recs = () => h.db.query(`SELECT to_jsonb(e) - 'expense_group_id' - 'expense_category_id' AS row FROM cash_expenses e ORDER BY id`).then((r) => r.rows.map((x) => x.row));
  const old = { rows: await recs(), office: await bal('office'), hr: await bal('hr') };
  assert.ok(old.rows.length >= 1, 'there is an expense recorded before 086');
  await run(file('086_expense_classification.sql'));
  await run(file('086_expense_classification.sql')); // a second run changes nothing
  assert.deepEqual(await recs(), old.rows, '086 changes no existing expense');
  assert.equal(await bal('office'), old.office); assert.equal(await bal('hr'), old.hr);
  assert.equal(Number((await h.db.query(`SELECT count(*) n FROM cash_expenses WHERE expense_group_id IS NOT NULL OR expense_category_id IS NOT NULL`)).rows[0].n), 0,
    'nothing is classified by the migration — every existing expense reads «غير مصنف»');
  forgetPermissionKeys();
  // the two keys are split from cash.office: whoever had it has them, nobody else gained anything
  const owner = (await h.call(c.t.owner, 'GET', '/me')).body.permissions as string[];
  assert.ok(owner.includes('expense.classification_manage') && owner.includes('expense.reclassify'));
  assert.deepEqual(owner.filter((k) => !k.startsWith('expense.')).sort(), before.owner.filter((k) => !k.startsWith('expense.')).sort());
  const hrPerms = (await h.call(c.t.hr, 'GET', '/me')).body.permissions as string[];
  assert.ok(!hrPerms.includes('expense.classification_manage') && !hrPerms.includes('expense.reclassify'), 'HR gains nothing');
  assert.deepEqual(hrPerms.slice().sort(), before.hr.slice().sort());
  const acc = await h.call(c.t.acc, 'POST', '/cash/expense-classes/groups', { name: 'مجموعة المحاسب' });
  assert.equal(acc.status, 201, 'the individual cash.office exception carried over');
  await h.call(c.t.owner, 'PATCH', `/cash/expense-classes/groups/${acc.body.group.id}`, { isActive: false });
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/expense-classes/groups', { name: 'X' + 'y' })).status, 403, 'HR does not manage the list');
  const cat = async (name: string) => (await h.call(c.t.owner, 'POST', '/cash/expense-classes/categories', { name })).body.category.id as string;
  const coffee = await cat('قهوة ومشروبات'), paint = await cat('دهانات'), maint = await cat('صيانة');
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/expense-classes/categories', { name: ' قهوة   ومشروبات ' })).body.error.details.reason, 'duplicate_name');
  const g1 = await h.call(c.t.owner, 'POST', '/cash/expense-classes/groups', { name: 'تشغيل المكتب', description: 'مصاريف يومية', categoryIds: [coffee, maint] });
  assert.equal(g1.status, 201, JSON.stringify(g1.body));
  const g2 = await h.call(c.t.owner, 'POST', '/cash/expense-classes/groups', { name: 'صيانة المقر', categoryIds: [paint, maint] });
  const list = (await h.call(c.t.owner, 'GET', '/cash/expense-classes')).body;
  assert.equal(list.installed, true);
  assert.equal(list.categories.length, 3, 'صيانة is ONE category used by two groups');
  assert.deepEqual(list.categories.find((x: any) => x.id === maint).groupIds.sort(), [g1.body.group.id, g2.body.group.id].sort());
  assert.equal((await h.call(c.t.owner, 'GET', '/cash/expense-classes?q=صيانة')).body.groups.length, 1);
  // edit, archive, reactivate — never deleted
  assert.equal((await h.call(c.t.owner, 'PATCH', `/cash/expense-classes/groups/${g2.body.group.id}`, { name: 'صيانة المكتب' })).body.group.name, 'صيانة المكتب');
  assert.equal((await h.call(c.t.owner, 'PATCH', `/cash/expense-classes/groups/${g2.body.group.id}`, { isActive: false })).body.group.isActive, false);
  assert.deepEqual((await h.call(c.t.owner, 'GET', '/cash/expense-classes?active=archived')).body.groups.map((g: any) => g.name).sort(), ['صيانة المكتب', 'مجموعة المحاسب']);
  // an archived name may be used again by a new active one; reactivating the old one then clashes
  const g3 = await h.call(c.t.owner, 'POST', '/cash/expense-classes/groups', { name: 'صيانة المكتب' });
  assert.equal(g3.status, 201);
  assert.equal((await h.call(c.t.owner, 'PATCH', `/cash/expense-classes/groups/${g2.body.group.id}`, { isActive: true })).body.error.details.reason, 'duplicate_name');
  await h.call(c.t.owner, 'PATCH', `/cash/expense-classes/groups/${g3.body.group.id}`, { isActive: false });
  assert.equal((await h.call(c.t.owner, 'PATCH', `/cash/expense-classes/groups/${g2.body.group.id}`, { isActive: true })).body.group.isActive, true);
  await assert.rejects(h.db.query(`DELETE FROM expense_groups WHERE id = $1`, [g3.body.group.id]), /never deleted/);
  const audits = (await h.db.query(`SELECT count(*)::int n FROM audit_log WHERE action LIKE 'expense.%'`)).rows[0].n;
  assert.ok(audits >= 8, 'every change audited');
});

test('086: classified and unclassified expenses; totals once each; filters; the money never moves', async () => {
  const l = (await h.call(c.t.owner, 'GET', '/cash/expense-classes')).body;
  const office = l.groups.find((g: any) => g.name === 'تشغيل المكتب'), maintG = l.groups.find((g: any) => g.name === 'صيانة المكتب');
  const coffee = l.categories.find((x: any) => x.name === 'قهوة ومشروبات'), maint = l.categories.find((x: any) => x.name === 'صيانة'),
    paint = l.categories.find((x: any) => x.name === 'دهانات');
  const add = (body: any, t = c.t.owner) => h.call(t, 'POST', '/cash/expenses', { cashbox: 'office', reason: 'بند', beneficiary: 'مورد', ...body });
  const before = await bal('office');
  assert.equal((await add({ amount: 1000, category: 'قهوة', groupId: office.id, categoryId: coffee.id })).status, 201);
  assert.equal((await add({ amount: 300, category: 'صيانة', groupId: office.id, categoryId: maint.id })).status, 201);
  assert.equal((await add({ amount: 700, category: 'صيانة', groupId: maintG.id, categoryId: maint.id })).status, 201);
  assert.equal((await add({ amount: 50, category: 'دهان', groupId: office.id, categoryId: paint.id })).body.error.details.reason, 'category_not_in_group');
  assert.equal((await add({ amount: 40, category: 'نثريات' })).status, 201, 'classification is optional');
  assert.equal(await bal('office'), before - 2040, 'the expenses themselves, nothing more');
  const l2 = (await h.call(c.t.owner, 'GET', '/cash/expense-classes')).body;
  assert.equal(l2.groups.find((g: any) => g.id === office.id).total, 1300);
  assert.equal(l2.categories.find((x: any) => x.id === maint.id).total, 1000, 'a category across all its groups, each expense once');
  const rep = (await h.call(c.t.owner, 'GET', '/cash/expense-classes/report?by=category')).body;
  assert.equal(rep.total, rep.lines.reduce((t: number, x: any) => t + x.total, 0), 'the lines add up to the total — nothing counted twice');
  assert.ok(rep.unclassified.total >= 140, 'the old (before 086) and the unclassified ones are listed apart');
  const gc = (await h.call(c.t.owner, 'GET', '/cash/expense-classes/report?by=group_category&every=month')).body;
  assert.equal(gc.lines.find((x: any) => x.groupId === office.id && x.categoryId === maint.id).total, 300);
  assert.equal(gc.lines[0].period, '2026-03-01');
  const day = (await h.call(c.t.owner, 'GET', '/cash/expense-classes/report?by=group&from=2026-03-11&to=2026-03-31')).body;
  assert.equal(day.total, 0, 'date filter (ledger date)');
  const d = (await h.call(c.t.owner, 'GET', `/cash/expense-classes/groups/${office.id}`)).body;
  assert.equal(d.total, 1300); assert.equal(d.count, 2); assert.equal(d.expenses.length, 2);
  assert.deepEqual(d.breakdown.map((x: any) => x.total).sort((p: number, q: number) => p - q), [300, 1000]);
  const filtered = (await h.call(c.t.owner, 'GET', `/cash/expenses?categoryId=${maint.id}`)).body.expenses;
  assert.equal(filtered.length, 2); assert.equal(filtered[0].expenseCategoryName, 'صيانة');
  // HR sees his own box only — the office's classified expenses are not in his totals
  const hr = (await h.call(c.t.hr, 'GET', '/cash/expense-classes')).body;
  assert.equal(hr.groups.find((g: any) => g.id === office.id).total, 0);
  assert.equal((await h.call(c.t.hr, 'GET', `/cash/expense-classes/report?by=group`)).body.total, 0);
  assert.equal((await h.call(c.t.e1, 'GET', '/cash/expense-classes')).status, 403);
});

test('086: re-classification is metadata only, audited, and allowed in a closed fiscal year', async () => {
  const l = (await h.call(c.t.owner, 'GET', '/cash/expense-classes')).body;
  const office = l.groups.find((g: any) => g.name === 'تشغيل المكتب'), coffee = l.categories.find((x: any) => x.name === 'قهوة ومشروبات');
  // an expense of 2025, then 2025 closed (083) — classifying it touches no figure of the closed year
  const x = (await h.db.query(`INSERT INTO cash_expenses (cashbox, amount_egp, category, reason, beneficiary, occurred_at, recorded_by, status, approved_by, approved_at)
      VALUES ('office', 1000, 'قهوة', 'ضيافة ديسمبر', 'محل', '2025-12-20T10:00:00Z', $1, 'posted', $1, '2025-12-20T10:00:00Z') RETURNING id`, [c.ids.owner])).rows[0];
  await run(file('083_financial_year_closing.sql'));
  await h.db.query(`INSERT INTO fy_closings (fiscal_year, version, status, started_by, approved_by, approved_at, approved_hash, closed_by, closed_at, snapshot, snapshot_hash)
      VALUES (2025, 1, 'closed', $1, $1, now(), 'h', $1, now(), '{}', 'h')`, [c.ids.owner]);
  const before = { office: await bal('office'), row: (await h.db.query(`SELECT amount_egp, status, cashbox, occurred_at, approved_at FROM cash_expenses WHERE id = $1`, [x.id])).rows[0] };
  assert.equal((await h.call(c.t.hr, 'PATCH', `/cash/expenses/${x.id}/classification`, { groupId: office.id, categoryId: coffee.id })).status, 404, 'not his box');
  const r = await h.call(c.t.owner, 'PATCH', `/cash/expenses/${x.id}/classification`, { groupId: office.id, categoryId: coffee.id });
  assert.equal(r.status, 200, JSON.stringify(r.body)); assert.equal(r.body.changed, true);
  const after = (await h.db.query(`SELECT amount_egp, status, cashbox, occurred_at, approved_at, expense_group_id FROM cash_expenses WHERE id = $1`, [x.id])).rows[0];
  assert.deepEqual({ ...after, expense_group_id: undefined }, { ...before.row, expense_group_id: undefined }, 'amount, status, box and dates unchanged');
  assert.equal(after.expense_group_id, office.id);
  assert.equal(await bal('office'), before.office, 'no cash movement');
  const a = (await h.db.query(`SELECT before, after FROM audit_log WHERE action = 'cash.expense.reclassify' AND entity_id = $1`, [x.id])).rows[0];
  assert.deepEqual([a.before.groupId, a.after.groupId], [null, office.id]);
  // back to unclassified (reversible), the money still never moves; the database refuses an amount change anyway
  assert.equal((await h.call(c.t.owner, 'PATCH', `/cash/expenses/${x.id}/classification`, { groupId: null, categoryId: null })).body.changed, true);
  await assert.rejects(h.db.query(`UPDATE cash_expenses SET amount_egp = 1 WHERE id = $1`, [x.id]), /cannot be changed/);
  // someone else's money (an owner's withdrawal) is not an office expense: no classification
  const draw = (await h.db.query(`INSERT INTO cash_expenses (cashbox, amount_egp, category, reason, beneficiary, occurred_at, recorded_by, status, owner_draw_id)
      VALUES ('office', 10, 'مسحوبات الملاك', 'سحب', 'مالك', now(), $1, 'pending_approval', $1) RETURNING id`, [c.ids.owner])).rows[0];
  assert.equal((await h.call(c.t.owner, 'PATCH', `/cash/expenses/${draw.id}/classification`, { groupId: office.id })).status, 409);
});

test('086: an archived (no longer available) group / category never corrupts the expenses that carry it; strangers are refused', async () => {
  const l = (await h.call(c.t.owner, 'GET', '/cash/expense-classes')).body;
  const office = l.groups.find((g: any) => g.name === 'تشغيل المكتب'), coffee = l.categories.find((x: any) => x.name === 'قهوة ومشروبات');
  const before = { bal: await bal('office'), rep: (await h.call(c.t.owner, 'GET', '/cash/expense-classes/report?by=group')).body };
  assert.equal((await h.call(c.t.owner, 'PATCH', `/cash/expense-classes/groups/${office.id}`, { isActive: false })).status, 200);
  // the expenses keep their group: still listed by it, still counted in its total — the money and the report do not move
  const list = (await h.call(c.t.owner, 'GET', `/cash/expenses?groupId=${office.id}`)).body.expenses;
  assert.ok(list.length >= 2 && list.every((x: any) => x.expenseGroupName === 'تشغيل المكتب'));
  const rep = (await h.call(c.t.owner, 'GET', '/cash/expense-classes/report?by=group')).body;
  assert.equal(rep.total, before.rep.total);
  assert.equal(rep.lines.find((x: any) => x.groupId === office.id)?.total, before.rep.lines.find((x: any) => x.groupId === office.id)?.total);
  assert.equal(await bal('office'), before.bal);
  // a NEW assignment to an archived group is refused; a recorded expense keeps it untouched
  const e = await h.call(c.t.owner, 'POST', '/cash/expenses', { cashbox: 'office', amount: 10, category: 'قهوة', reason: 'بند', beneficiary: 'محل', groupId: office.id, categoryId: coffee.id });
  assert.equal(e.status, 400);
  // strangers: an employee without cashbox access sees and changes nothing
  const one = list[0];
  assert.equal((await h.call(c.t.e1, 'PATCH', `/cash/expenses/${one.id}/classification`, { groupId: null })).status, 404);
  assert.equal((await h.call(c.t.e1, 'POST', '/cash/expense-classes/categories', { name: 'دخيل' })).status, 403);
  assert.equal((await h.call(c.t.e1, 'GET', '/cash/expense-classes/report')).status, 403);
  assert.equal((await h.call(c.t.owner, 'PATCH', `/cash/expense-classes/groups/${office.id}`, { isActive: true })).status, 200);
});
