import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, insertEmployee, type Harness } from './helpers.ts';

/**
 * The disbursement code: every payment to an employee is confirmed by a 4-digit code that only the recipient's app gets,
 * and only the person who paid can enter. «تم الاستلام» is gone. Nothing marks a payment received but the right, live,
 * unused code of that very payment.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let tGm = ''; let tHr2 = '';
const pay = async (body: Record<string, unknown>, tok = c.t.hr) => h.call(tok, 'POST', '/payouts', body);
const code = async (tok: string, id: string) => h.call(tok, 'POST', `/payouts/${id}/code`, {});
const verify = async (tok: string, id: string, x: string) => h.call(tok, 'POST', `/payouts/${id}/verify`, { code: x });
const status = async (id: string) => (await h.db.query(`SELECT status FROM payouts WHERE id = $1`, [id])).rows[0].status;
const wrongOf = (x: string) => (x === '0000' ? '1111' : '0000');

before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  const gm = await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE id = $1`, [gm.body.id]);
  tGm = await h.login('GM1', PW);
  await insertEmployee(h.db, { code: 'HR2', name: 'موارد بشرية ٢', role: 'hr_manager' });
  tHr2 = await h.login('HR2', PW);
});
after(async () => { await h.close(); });

test('a payment waits for the code; the recipient alone gets it; the notification never carries it; «تم الاستلام» is refused', async () => {
  const p = await pay({ employeeId: c.ids.e1, kind: 'work_expense', amount: 400, month: '2026-03', note: 'مواصلات' });
  assert.equal(p.status, 201, JSON.stringify(p.body));
  const id = p.body.payout.id;
  assert.equal(p.body.payout.canVerify, true, 'the payer enters the code');
  const n = (await h.call(c.t.e1, 'GET', '/notifications')).body.notifications.find((x: any) => x.type === 'payout_otp');
  assert.ok(n, 'the recipient is told');
  const r = await h.call(c.t.e1, 'POST', `/payouts/${id}/receive`, {});
  assert.equal(r.status, 409); assert.equal(r.body.error.details.reason, 'otp_required');
  assert.equal((await code(c.t.hr, id)).status, 404, 'the payer can not get the code');
  assert.equal((await code(c.t.e2, id)).status, 404, 'nor anyone else');
  const k = await code(c.t.e1, id);
  assert.equal(k.status, 200);
  assert.match(k.body.code, /^\d{4}$/);
  assert.equal(k.body.amount, 400);
  // the code is nowhere to be read back: not in the notifications, the list, the audit log, nor stored in clear
  const all = JSON.stringify([(await h.call(c.t.e1, 'GET', '/notifications')).body, (await h.call(c.t.hr, 'GET', '/payouts')).body]);
  const stored = JSON.stringify((await h.db.query(`SELECT * FROM action_otps`)).rows) + JSON.stringify((await h.db.query(`SELECT after FROM audit_log WHERE entity = 'payout'`)).rows);
  assert.ok(!all.includes(`"code":"${k.body.code}"`), 'not in what the payer or the lists see');
  assert.ok(!n.title.includes(k.body.code) && !n.body.includes(k.body.code));
  assert.ok(!stored.includes(`"${k.body.code}"`), 'only a hash is stored');
  // another HR person can not enter it — only the one who paid
  assert.equal((await verify(tHr2, id, k.body.code)).status, 404);
  assert.equal(await status(id), 'pending');
  const ok = await verify(c.t.hr, id, k.body.code);
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.equal(ok.body.payout.status, 'received');
  assert.equal(await status(id), 'received');
  assert.equal((await verify(c.t.hr, id, k.body.code)).status, 409, 'used once — no replay');
  assert.equal((await code(c.t.e1, id)).status, 409, 'no new code for a confirmed payment');
});

test('wrong / expired / replaced codes never confirm; 5 wrong tries end a code; 15 in an hour stop the payment', async () => {
  const p = await pay({ employeeId: c.ids.e2, kind: 'work_expense', amount: 250, month: '2026-03' });
  const id = p.body.payout.id;
  // a newer code ends the older one
  const first = (await code(c.t.e2, id)).body.code;
  const second = (await code(c.t.e2, id)).body.code;
  void first; void second;
  const liveRows = (await h.db.query(`SELECT count(*)::int AS n FROM action_otps WHERE action = $1 AND used_at IS NULL AND expires_at > now()`, [`payout:${id}`])).rows[0].n;
  assert.equal(liveRows, 1, 'the replaced code is dead (one live code per payment)');
  assert.equal((await verify(c.t.hr, id, wrongOf(second))).status, 400); // 1 wrong try
  // expired
  await h.db.query(`UPDATE action_otps SET expires_at = now() - interval '1 second' WHERE action = $1`, [`payout:${id}`]);
  const ex = await verify(c.t.hr, id, second);
  assert.equal(ex.status, 400); assert.equal(ex.body.error.details.reason, 'otp_invalid');
  // 5 wrong tries end the code, even the right one afterwards
  const live = (await code(c.t.e2, id)).body.code;
  for (let i = 0; i < 5; i++) assert.equal((await verify(c.t.hr, id, wrongOf(live))).status, 400);
  assert.equal((await verify(c.t.hr, id, live)).status, 400, 'dead after 5 wrong tries');
  assert.equal(await status(id), 'pending', 'never paid by a wrong code');
  // malformed
  for (const bad of ['12', '12345', 'abcd', '']) assert.equal((await verify(c.t.hr, id, bad)).status, 400);
  // more wrong tries on fresh codes: at 15 in an hour the payment is stopped (even the right code)
  const c2 = (await code(c.t.e2, id)).body.code;
  for (let i = 0; i < 5; i++) await verify(c.t.hr, id, wrongOf(c2));
  const c3 = (await code(c.t.e2, id)).body.code; // the 5th code in 15 minutes
  for (let i = 0; i < 4; i++) await verify(c.t.hr, id, wrongOf(c3));
  // 1 + 5 + 5 + 4 = 15 wrong tries on this payment within the hour
  const locked = await verify(c.t.hr, id, c3);
  assert.equal(locked.status, 400); assert.equal(locked.body.error.details.reason, 'otp_locked');
  // and a sixth code in 15 minutes is refused
  const many = await code(c.t.e2, id);
  assert.equal(many.status, 429); assert.equal(many.body.error.details.reason, 'otp_rate_limited');
  assert.equal(await status(id), 'pending');
  // cancelling the payment ends any live code
  assert.equal((await h.call(c.t.hr, 'POST', `/payouts/${id}/cancel`, {})).status, 200);
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM action_otps WHERE action = $1 AND used_at IS NULL AND expires_at > now()`, [`payout:${id}`])).rows[0].n, 0);
});

test('every kind goes through the code: cash to HR, salary, advance, commission; the parallel entries confirm once', async () => {
  // cash handed to HR: the manager pays, HR shows the code
  const fund = await pay({ employeeId: c.ids.hr, kind: 'fund', amount: 10000 }, tGm);
  assert.equal(fund.status, 201);
  assert.equal((await code(c.t.owner, fund.body.payout.id)).status, 404);
  const fc = (await code(c.t.hr, fund.body.payout.id)).body.code;
  const twice = await Promise.all([1, 2, 3].map(() => verify(tGm, fund.body.payout.id, fc)));
  assert.deepEqual(twice.map((x) => x.status).sort(), [200, 409, 409], 'confirmed once');
  assert.equal((await h.call(c.t.hr, 'GET', '/payouts')).body.balance, 10000 - 400, 'in the HR cashbox once (minus the work expense above)');
  // salary
  await h.db.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1, 9000, $2)`, [c.ids.e3, c.ids.owner]);
  await h.db.query(`UPDATE employees SET attendance_exempt = true WHERE id = $1`, [c.ids.e3]);
  const s = await h.call(c.t.hr, 'POST', '/payouts/salary', { employeeId: c.ids.e3, month: '2026-03' });
  assert.equal(s.status, 201, JSON.stringify(s.body));
  const row = (await h.call(c.t.hr, 'GET', '/payouts/salaries?month=2026-03')).body.salaries.find((x: any) => x.employeeId === c.ids.e3);
  assert.equal(row.verifyPayoutId, s.body.payout.id, 'the salaries page offers the code entry');
  assert.equal(row.status, 'awaiting_receipt');
  const sc = (await code(c.t.e3, s.body.payout.id)).body.code;
  assert.equal((await verify(c.t.hr, s.body.payout.id, sc)).status, 200);
  assert.equal((await h.call(c.t.hr, 'GET', '/payouts/salaries?month=2026-03')).body.salaries.find((x: any) => x.employeeId === c.ids.e3).status, 'received');
  // an approved advance
  const adv = (await h.db.query(`INSERT INTO advance_requests (employee_id, kind, period, amount_egp, status, created_by, decided_by, decided_at)
                                  VALUES ($1,'advance','2026-03-01',700,'confirmed',$1,$2,now()) RETURNING id`, [c.ids.solo, c.ids.owner])).rows[0].id;
  const ap = await pay({ employeeId: c.ids.solo, kind: 'advance', amount: 700, month: '2026-03', advanceId: adv });
  assert.equal(ap.status, 201, JSON.stringify(ap.body));
  const mine = (await h.call(c.t.solo, 'GET', '/advances?scope=mine')).body.advances.find((x: any) => x.id === adv);
  assert.deepEqual([mine.awaitingMyCode, mine.canReceive], [true, false]);
  const hrView = (await h.call(c.t.hr, 'GET', '/advances')).body.advances.find((x: any) => x.id === adv);
  assert.equal(hrView.canVerify, true);
  assert.equal((await verify(c.t.hr, ap.body.payout.id, (await code(c.t.solo, ap.body.payout.id)).body.code)).status, 200);
  assert.equal((await h.call(c.t.solo, 'GET', '/advances?scope=mine')).body.advances.find((x: any) => x.id === adv).payment, 'received');
  // what the employee was paid is out of the cashbox exactly once per payment
  const out = (await h.db.query(`SELECT count(*)::int AS n FROM cash_ledger WHERE source = 'payouts' AND source_id = ANY($1::uuid[])`,
    [[s.body.payout.id, ap.body.payout.id]])).rows[0].n;
  assert.equal(out, 2);
});

test('a disputed payment can still be confirmed with the code; the audit log keeps who and when, never the code', async () => {
  const p = await pay({ employeeId: c.ids.e1, kind: 'work_expense', amount: 90, month: '2026-03' });
  const id = p.body.payout.id;
  assert.equal((await h.call(c.t.e1, 'POST', `/payouts/${id}/dispute`, { reason: 'استلمت 80 بس' })).status, 200);
  const k = (await code(c.t.e1, id)).body.code;
  assert.equal((await verify(c.t.hr, id, k)).status, 200);
  const log = (await h.db.query(`SELECT action, after FROM audit_log WHERE entity = 'payout' AND entity_id = $1 ORDER BY at`, [id])).rows;
  const acts = log.map((x) => x.action);
  for (const x of ['payout.create', 'payout.dispute', 'payout.code_issued', 'payout.verified']) assert.ok(acts.includes(x), x);
  assert.ok(!JSON.stringify(log).includes(`"${k}"`), 'no code in the log');
});
