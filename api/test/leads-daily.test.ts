// «تقرير الليدز اليومي»: at 23:59 Cairo the GM(s) and the administrative officer get the day's new leads, the actions and who
// worked most — only inside the window, once a day, to those recipients only (a knock at any other time sends nothing).
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';
import { dueReportDate, runDailyLeadsReport } from '../src/modules/leads-daily.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let pid = ''; let channel = '';
before(async () => {
  h = await harness('2026-11-14T08:00:00Z'); c = await cast(h);
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer', email = 'ao@example.com' WHERE id = $1`, [c.ids.acc]);
  await h.db.query(`UPDATE employees SET email = 'gm@example.com' WHERE id = $1`, [c.ids.owner]);
  await h.db.query(`UPDATE employees SET email = 'e1@example.com' WHERE id = $1`, [c.ids.e1]);
  pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'برج التقرير', ownerName: 'أ. سامي', ownerPhone: '0100' })).body.project.id;
  channel = (await h.call(c.t.acc, 'GET', '/leads/meta')).body.channels[0].id;
});
after(async () => { await h.close(); });

test('the window: from 23:55 Cairo that day, a late scheduler until 06:00 the next morning; never in the day', () => {
  assert.equal(dueReportDate(new Date('2026-11-14T21:59:00Z')), '2026-11-14', '23:59 Cairo (UTC+2)');
  assert.equal(dueReportDate(new Date('2026-11-14T22:30:00Z')), '2026-11-14', '00:30 the next morning');
  assert.equal(dueReportDate(new Date('2026-11-14T21:00:00Z')), null, '23:00');
  assert.equal(dueReportDate(new Date('2026-11-14T10:00:00Z')), null, 'noon');
  assert.equal(dueReportDate(new Date('2026-07-14T20:59:00Z')), '2026-07-14', 'summer time (UTC+3): 23:59');
});

test('the report: the day\'s new leads, the actions, the top salesman; sent once, to the GM and the admin officer only', async () => {
  const lead = async (name: string, phone: string, who: string) =>
    (await h.call(c.t.acc, 'POST', '/leads', { fullName: name, phone, projectId: pid, channelId: channel, assignees: [who] })).body.lead;
  const a = await lead('عميل التقرير ١', '01077700001', c.ids.e1);
  const b = await lead('عميل التقرير ٢', '01077700002', c.ids.e2);
  for (const t of ['أول مكالمة', 'متابعة']) {
    const x = await h.call(c.t.e1, 'POST', `/leads/${a.id}/actions`, { stage: 'following', comment: t, answered: true, nextAt: '2026-11-15T10:00:00Z' });
    assert.equal(x.status, 201, JSON.stringify(x.body));
  }
  const y = await h.call(c.t.e2, 'POST', `/leads/${b.id}/actions`, { stage: 'no_answer', comment: 'مردش', answered: false, nextAt: '2026-11-15T10:00:00Z' });
  assert.equal(y.status, 201, JSON.stringify(y.body));

  const sent: { to: string; subject: string; html: string }[] = [];
  const send = async (m: { to: string; subject: string; html: string }) => { sent.push(m); return true; };
  // in the day: nothing
  assert.equal((await runDailyLeadsReport(h.db, new Date('2026-11-14T12:00:00Z'), { send })).reason, 'not_due');
  assert.equal(sent.length, 0);
  // 23:59 Cairo
  const r = await runDailyLeadsReport(h.db, new Date('2026-11-14T21:59:00Z'), { send });
  assert.equal(r.sent, true, JSON.stringify(r));
  assert.deepEqual(sent.map((m) => m.to).sort(), ['ao@example.com', 'gm@example.com'], 'not a salesman');
  const m = sent[0];
  assert.match(m.subject, /2 ليد جديد، 3 أكشن، الأول موظف ١/);
  assert.match(m.html, /عميل التقرير ١/); assert.match(m.html, /عميل التقرير ٢/);
  assert.match(m.html, /أكتر سيلز اشتغل النهارده/); assert.match(m.html, /مردش/);
  // a second knock (or a late one after midnight) sends nothing more
  assert.equal((await runDailyLeadsReport(h.db, new Date('2026-11-14T21:59:30Z'), { send })).reason, 'already_sent');
  assert.equal((await runDailyLeadsReport(h.db, new Date('2026-11-14T23:30:00Z'), { send })).reason, 'already_sent');
  assert.equal(sent.length, 2);
  // the knock (2026-11-24): anonymous → 401; the scheduler's X-Backup-Token or a person with «leads.read_all» → answered
  // (nothing is sent outside the window); a salesman → 403. The preview is the managers'
  const TOKEN = 'daily-report-test-token-0123456789';
  process.env.BACKUP_TOKEN = TOKEN;
  try {
    assert.equal((await h.call(null, 'POST', '/leads/daily-report/run')).status, 401, 'anonymous');
    assert.equal((await h.call(null, 'POST', '/leads/daily-report/run', undefined, { 'x-backup-token': 'wrong-token-wrong-token-wrong' })).status, 401, 'wrong token');
    assert.equal((await h.call(null, 'POST', '/leads/daily-report/run', undefined, { 'x-backup-token': TOKEN })).status, 200, 'the scheduler');
    assert.equal((await h.call(c.t.e1, 'POST', '/leads/daily-report/run')).status, 403, 'a salesman');
    assert.equal((await h.call(c.t.owner, 'POST', '/leads/daily-report/run')).status, 200, 'the owner');
  } finally { delete process.env.BACKUP_TOKEN; }
  assert.equal((await h.call(c.t.e1, 'GET', '/leads/daily-report?date=2026-11-14')).status, 403);
  const p = (await h.call(c.t.owner, 'GET', '/leads/daily-report?date=2026-11-14')).body.report;
  assert.deepEqual([p.newLeads, p.actions, p.top.name], [2, 3, 'موظف ١']);
});
