import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { harness, cast, insertEmployee, PW, type Harness } from './helpers.ts';

/**
 * db/ops/2026-11-18-keep-active-employees.sql on a database with every kind of record: the activity goes, the employees
 * on the job (with their files, salaries, devices, custody), the marketing companies, the forms and the settings stay;
 * former employees are deleted, or left as an anonymous «موظف سابق» when a kept record must keep pointing at them.
 * Afterwards the system still works (sign-in, check-in, lists).
 */
const SQL = readFileSync(new URL('../../db/ops/2026-11-18-keep-active-employees.sql', import.meta.url), 'utf8');
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let formerQuiet = ''; let formerBusy = ''; let mc = '';
const JPG = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(64, 3)]).toString('base64');
const count = async (t: string, where = 'TRUE', p: unknown[] = []) => (await h.db.query(`SELECT count(*)::int AS n FROM ${t} WHERE ${where}`, p)).rows[0].n as number;

before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  // activity of the employees on the job
  await h.call(c.t.e1, 'POST', '/attendance/check-in', {});
  await h.call(c.t.e1, 'POST', '/requests', { type: 'full_day_absence', startDate: '2026-03-20', endDate: '2026-03-20', absenceType: 'annual', reason: 'ظرف' });
  await h.call(c.t.e2, 'POST', '/advances', { kind: 'advance', amount: 1500, period: '2026-03-01', note: 'سلفة', attachment: JPG });
  const fund = await h.call(c.t.owner, 'POST', '/payouts', { employeeId: c.ids.hr, kind: 'fund', amount: 9000 });
  await h.call(c.t.hr, 'POST', `/payouts/${fund.body.payout.id}/receive`, {});
  await h.call(c.t.e1, 'POST', '/leads', { name: 'عميل', phone: '01000000001', projectLater: true });
  await h.db.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1, 9000, $2)`, [c.ids.e1, c.ids.owner]);
  // a document and custody of an employee on the job
  await h.db.query(`INSERT INTO employee_documents (employee_id, kind, title, file_name, mime, size_bytes, content, uploaded_by)
                    VALUES ($1, 'national_id', 'بطاقة', 'id.jpg', 'image/jpeg', 4, '\\xffd8ffd9', $2)`, [c.ids.e1, c.ids.hr]);
  await h.db.query(`INSERT INTO custody_items (employee_id, asset_name, asset_type, assigned_on, assigned_by, condition_out)
                    VALUES ($1, 'لابتوب ديل', 'laptop', '2026-03-01', $2, 'good')`, [c.ids.e1, c.ids.hr]);
  // a former employee with nothing kept pointing at him; one «تم التصفيه» who uploaded a kept document and created a company
  formerQuiet = await insertEmployee(h.db, { code: 'OLD1', name: 'موظف قديم', role: 'sales_employee' });
  await h.db.query(`UPDATE employees SET status = 'inactive', phone = '01999999999' WHERE id = $1`, [formerQuiet]);
  formerBusy = await insertEmployee(h.db, { code: 'OLD2', name: 'محاسب قديم', role: 'accountant' });
  await h.db.query(`UPDATE employees SET legacy_fields = '{"status":"تم التصفيه"}', phone = '01888888888', email = 'old@x.test' WHERE id = $1`, [formerBusy]);
  await h.db.query(`INSERT INTO employee_documents (employee_id, kind, title, file_name, mime, size_bytes, content, uploaded_by)
                    VALUES ($1, 'national_id', 'بطاقته', 'id2.jpg', 'image/jpeg', 4, '\\xffd8ffd9', $1), ($2, 'national_id', 'بطاقة', 'id3.jpg', 'image/jpeg', 4, '\\xffd8ffd9', $1)`,
    [formerBusy, c.ids.e2]);
  mc = (await h.db.query(`INSERT INTO marketing_companies (name, kind, created_by) VALUES ('شركة تسويق', 'commission', $1) RETURNING id`, [formerBusy])).rows[0].id;
});
after(async () => { await h.close(); });

test('dry run changes nothing; the real run keeps exactly what was asked and deletes the rest', async () => {
  const before = { att: await count('attendance'), leads: await count('leads'), emp: await count('employees') };
  // dry run: the report, then everything undone
  const report = await h.db.tx(async (q) => {
    await q.query(SQL);
    const r = (await q.query(`SELECT what, rows::int AS n FROM c_report`)).rows;
    throw Object.assign(new Error('rollback'), { report: r });
  }).catch((e) => e.report);
  assert.ok(report.find((x: any) => x.what === 'attendance').n >= 1);
  assert.equal(await count('attendance'), before.att, 'dry run left the data');
  assert.equal(await count('employees'), before.emp);

  // for real
  await h.db.tx(async (q) => { await q.query(SQL); });
  for (const t of ['attendance', 'requests', 'advance_requests', 'payouts', 'leads', 'notifications', 'tracking_state'])
    assert.equal(await count(t), 0, `${t} wiped`);
  // the employees on the job and their things
  for (const id of [c.ids.owner, c.ids.hr, c.ids.e1, c.ids.e2, c.ids.sm1]) assert.equal(await count('employees', 'id = $1', [id]), 1);
  assert.equal(await count('employee_documents', 'employee_id = $1', [c.ids.e1]), 1, 'his document');
  assert.equal(await count('employee_documents', 'employee_id = $1', [c.ids.e2]), 1, 'a document uploaded by a former employee stays');
  assert.equal(await count('employee_salaries', 'employee_id = $1', [c.ids.e1]), 1);
  assert.equal(await count('custody_items', 'employee_id = $1', [c.ids.e1]), 1, 'custody');
  assert.equal(await count('marketing_companies', 'id = $1', [mc]), 1, 'marketing company');
  assert.ok(await count('teams') >= 2, 'settings');
  // former employees: gone, or an anonymous stub with nothing personal
  assert.equal(await count('employees', 'id = $1', [formerQuiet]), 0, 'deleted');
  const stub = (await h.db.query(`SELECT full_name, phone, email, status, code FROM employees WHERE id = $1`, [formerBusy])).rows[0];
  assert.deepEqual([stub.full_name, stub.phone, stub.email, stub.status], ['موظف سابق', null, null, 'inactive']);
  assert.equal(await count('employee_documents', 'employee_id = $1', [formerBusy]), 0, 'his own documents gone');
  assert.equal((await h.call(null, 'POST', '/auth/login', { identifier: stub.code, password: PW })).status, 401, 'can not sign in');
  // the system still works
  assert.equal((await h.call(c.t.e1, 'POST', '/attendance/check-in', {})).status, 201, 'check-in works');
  const list = await h.call(c.t.owner, 'GET', '/employees');
  assert.equal(list.status, 200);
  assert.equal((await h.call(c.t.owner, 'GET', '/leads')).status, 200);
  assert.equal((await h.call(c.t.hr, 'GET', '/payouts')).body.balance, 0, 'cashboxes start from zero');
});
