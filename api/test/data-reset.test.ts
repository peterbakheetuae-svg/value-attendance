import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

/** One-time start-over: activity, money and earlier forms go; employees and custody stay; old attendance comes in. */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-11-10T13:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });

test('owner only; dry run changes nothing; the reset keeps employees + custody and imports the old attendance', async () => {
  await h.db.query(`UPDATE employees SET phone = '01097790378' WHERE id = $1`, [c.ids.e1]);
  // some activity to wipe
  assert.equal((await h.call(c.t.hr, 'POST', '/attendance/corrections', { employeeId: c.ids.e2, workDate: '2026-11-03', checkIn: '10:00', checkOut: '18:00', reason: 'test' })).status, 201);
  const asset = await h.call(c.t.hr, 'POST', '/custody/assets', { assetType: 'mobile', name: 'Samsung A15', serialNo: 'IMEI-1' });
  assert.equal((await h.call(c.t.hr, 'POST', `/employees/${c.ids.e2}/custody`, { assetId: asset.body.asset.id })).status, 201);
  const intro = { date: '2026-11-10', clientName: 'عميل', phone: '01012345678', propertyTypes: ['residential'] };
  assert.equal((await h.call(c.t.e1, 'POST', '/forms/client-intros', { data: intro })).status, 201);
  const empsBefore = (await h.db.query(`SELECT * FROM employees ORDER BY id`)).rows;

  const body = {
    employees: [{ key: 'old1', name: 'بلال عبدالله', phone: '01097790378' }, { key: 'old2', name: 'موظف ٢' }, { key: 'old3', name: 'مش موجود' }],
    attendance: [
      { key: 'old1', day: '2026-11-01', in: '12:50', out: '20:36' },
      { key: 'old1', day: '2026-11-10', in: '12:23', out: null },
      { key: 'old2', day: '2026-11-02', in: '11:00', out: '19:00' },
      { key: 'old3', day: '2026-11-02', in: '11:00', out: '19:00' },
    ],
  };
  assert.equal((await h.call(c.t.hr, 'POST', '/admin/data-reset', body)).status, 403);
  const dry = await h.call(c.t.owner, 'POST', '/admin/data-reset', body);
  assert.equal(dry.status, 200, JSON.stringify(dry.body));
  assert.equal(dry.body.dryRun, true);
  assert.equal(dry.body.summary[0].matched.id, c.ids.e1, 'matched by phone');
  assert.equal(dry.body.summary[1].matched.id, c.ids.e2, 'matched by name');
  assert.equal(dry.body.summary[2].matched, null);
  assert.equal(dry.body.rows, 3);
  assert.equal(Number((await h.db.query(`SELECT count(*) FROM attendance`)).rows[0].count), 1, 'dry run changed nothing');

  assert.equal((await h.call(c.t.owner, 'POST', '/admin/data-reset', { ...body, dryRun: false })).status, 400, 'needs the confirmation words');
  const res = await h.call(c.t.owner, 'POST', '/admin/data-reset', { ...body, dryRun: false, confirm: 'امسح البيانات' });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.attendanceImported, 3);
  assert.equal(res.body.formsDeleted, 1);
  const att = (await h.db.query(`SELECT employee_id, work_date::text AS d, check_out_at FROM attendance ORDER BY work_date`)).rows;
  assert.deepEqual(att.map((x) => x.d), ['2026-11-01', '2026-11-02', '2026-11-10']);
  assert.equal(att[2].check_out_at, null, 'today still open: the employee checks out from the new app');
  assert.equal(Number((await h.db.query(`SELECT count(*) FROM attendance_corrections`)).rows[0].count), 0);
  assert.deepEqual((await h.db.query(`SELECT * FROM employees ORDER BY id`)).rows, empsBefore, 'employees untouched');
  assert.equal(Number((await h.db.query(`SELECT count(*) FROM custody_items`)).rows[0].count), 1, 'custody kept');
  assert.equal(Number((await h.db.query(`SELECT count(*) FROM custody_assets`)).rows[0].count), 1);
  assert.equal((await h.call(c.t.e1, 'POST', '/forms/client-intros', { data: intro })).body.form.number, 1, 'form numbering starts again');
  const month = await h.call(c.t.hr, 'GET', `/attendance?employeeId=${c.ids.e1}&month=2026-11`);
  assert.equal(month.status, 200, JSON.stringify(month.body));
});

test('old hourly permissions come in as approved requests and excuse the late arrival they covered', async () => {
  // e2 starts at the default schedule; a late check-in on 2026-11-04
  const s = (await h.db.query(`SELECT to_char(start_time,'HH24:MI') AS st FROM work_schedules WHERE is_default`)).rows[0].st;
  const [H, M] = s.split(':').map(Number);
  const late = `${String(H + 3).padStart(2, '0')}:${String(M).padStart(2, '0')}`;
  assert.equal((await h.call(c.t.hr, 'POST', '/attendance/corrections', { employeeId: c.ids.e2, workDate: '2026-11-04', checkIn: late, reason: 'test' })).status, 201);
  const before = (await h.call(c.t.hr, 'GET', `/attendance?employeeId=${c.ids.e2}&month=2026-11`)).body.summary.lateMinutes;
  assert.ok(before >= 180);
  const body = { employees: [{ key: 'x', name: 'موظف ٢' }],
    permissions: [{ key: 'x', day: '2026-11-04', from: '00:00', to: late, reason: 'سيكشن' }, { key: 'nobody', day: '2026-11-04', from: '10:00', to: '11:00' }] };
  assert.equal((await h.call(c.t.hr, 'POST', '/admin/import-permissions', body)).status, 403);
  const dry = await h.call(c.t.owner, 'POST', '/admin/import-permissions', body);
  assert.equal(dry.status, 200, JSON.stringify(dry.body));
  assert.equal(dry.body.plan.length, 1);
  assert.equal(dry.body.plan[0].from, s, 'kept inside the working hours');
  assert.equal(dry.body.skipped.length, 1);
  const res = await h.call(c.t.owner, 'POST', '/admin/import-permissions', { ...body, dryRun: false });
  assert.equal(res.body.imported, 1);
  assert.equal((await h.call(c.t.owner, 'POST', '/admin/import-permissions', { ...body, dryRun: false })).body.imported, 0, 'no duplicates');
  const after = (await h.call(c.t.hr, 'GET', `/attendance?employeeId=${c.ids.e2}&month=2026-11`)).body.summary;
  assert.equal(after.lateMinutes, before - 180);
  assert.equal(after.hourlyPermissions, 1);
});

test('an advance handed over outside the cashbox: in his advances, deducted from the month, never in a cashbox', async () => {
  const body = { employeeId: c.ids.e1, amount: 1000, month: '2026-11', note: 'سلفة قديمة' };
  assert.equal((await h.call(c.t.hr, 'POST', '/admin/opening-advance', body)).status, 403);
  const r = await h.call(c.t.owner, 'POST', '/admin/opening-advance', body);
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const adv = (await h.call(c.t.e1, 'GET', '/advances')).body.advances?.find((x: any) => x.id === r.body.advance.id)
    ?? (await h.call(c.t.e1, 'GET', '/advances')).body.items?.find((x: any) => x.id === r.body.advance.id);
  assert.ok(adv, 'shows in his advances');
  assert.equal(adv.payment, 'received');
  assert.equal(adv.canPay, false);
  const pay = await h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.e1, kind: 'advance', amount: 1000, month: '2026-11', advanceId: r.body.advance.id });
  assert.equal(pay.status, 409, 'cannot be paid from the cashbox again');
  const p = await h.call(c.t.hr, 'GET', `/payroll/employee/${c.ids.e1}?month=2026-11`);
  assert.equal(p.body.payroll.advances, 1000, 'deducted from November');
  const ledger = Number((await h.db.query(`SELECT count(*) FROM cash_ledger`)).rows[0].count);
  assert.equal(ledger, 0, 'no cashbox movement');
});
