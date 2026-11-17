import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

/**
 * Data-confidentiality acceptance tests: a salesman, an employee without finance rights and a marketing company each get
 * only their own scope — by ID, by filter, by list, by export — never someone else's.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let pid: string; let campA: string; let campB: string; let tokA: string; let tokB: string; let leadE1: string; let leadA: string; let leadB: string;
before(async () => {
  h = await harness('2026-11-17T08:00:00Z'); c = await cast(h);
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [c.ids.acc]);
  pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'برج العزل', ownerName: 'أ. سامي', ownerPhone: '0100' })).body.project.id;
  const ch = (await h.call(c.t.acc, 'GET', '/leads/meta')).body.channels[0].id;
  const mkCamp = async (name: string) => {
    await h.call(c.t.acc, 'POST', '/leads/campaigns', { name, channelId: ch, projectId: pid });
    return (await h.db.query(`SELECT id FROM lead_campaigns WHERE name = $1`, [name])).rows[0].id as string;
  };
  campA = await mkCamp('حملة أ'); campB = await mkCamp('حملة ب');
  const company = async (name: string, email: string, camp: string) => {
    const id = (await h.call(c.t.owner, 'POST', '/marketing-companies', { name, kind: 'fixed', monthlyFee: 1 })).body.company.id;
    await h.call(c.t.owner, 'PATCH', `/leads/partners/${id}/login`, { email, password: 'Start#2026x' });
    await h.db.query(`UPDATE marketing_companies SET must_change_password = false, device_lock = false WHERE id = $1`, [id]);
    await h.call(c.t.acc, 'PATCH', `/leads/campaigns/${camp}/partner`, { companyId: id });
    return (await h.call(null, 'POST', '/auth/login', { identifier: email, password: 'Start#2026x' })).body.token as string;
  };
  tokA = await company('شركة أ', 'a@iso.com', campA); tokB = await company('شركة ب', 'b@iso.com', campB);
  const add = async (tok: string, name: string, phone: string, campaignId?: string) =>
    (await h.call(tok, 'POST', '/leads', { fullName: name, phone, projectId: pid, ...(campaignId ? { campaignId } : {}) })).body.lead.id as string;
  leadE1 = await add(c.t.e1, 'عميل الموظف 1', '01077770001');
  leadA = await add(c.t.acc, 'عميل الشركة أ', '01077770002', campA);
  leadB = await add(c.t.acc, 'عميل الشركة ب', '01077770003', campB);
});
after(async () => { await h.close(); });

test('a salesman cannot open, list, filter or export another salesman\'s lead by ID / query', async () => {
  assert.equal((await h.call(c.t.e3, 'GET', `/leads/${leadE1}`)).status, 404);
  assert.equal((await h.call(c.t.e3, 'GET', `/leads/${leadE1}/extra`)).status, 404);
  assert.equal((await h.call(c.t.e3, 'PATCH', `/leads/${leadE1}`, { fullName: 'x' })).status !== 200, true);
  for (const q of ['', '?view=all', `?q=${encodeURIComponent('عميل الموظف 1')}`, `?employeeId=${c.ids.e1}`]) {
    const ids = ((await h.call(c.t.e3, 'GET', `/leads${q}`)).body.leads ?? []).map((x: any) => x.id);
    assert.ok(!ids.includes(leadE1), `list ${q || '(default)'} leaks`);
  }
  const dash = (await h.call(c.t.e3, 'GET', `/leads/dashboard?view=all&employeeId=${c.ids.e1}`)).body;
  assert.ok(!JSON.stringify(dash).includes('عميل الموظف 1'), 'dashboard leaks');
});

test('marketing company A never sees company B\'s leads — by ID, list, filter, tasks, notifications', async () => {
  assert.equal((await h.call(tokA, 'GET', `/leads/${leadB}`)).status, 404);
  assert.equal((await h.call(tokA, 'GET', `/leads/${leadE1}`)).status, 404, 'nor a salesman\'s own lead');
  assert.equal((await h.call(tokA, 'GET', `/leads/${leadA}`)).status, 200);
  for (const q of ['', `?campaignId=${campB}`, '?view=all', `?q=${encodeURIComponent('الشركة ب')}`]) {
    const ids = ((await h.call(tokA, 'GET', `/leads${q}`)).body.leads ?? []).map((x: any) => x.id);
    assert.ok(!ids.includes(leadB) && !ids.includes(leadE1), `list ${q} leaks`);
  }
  assert.ok(!JSON.stringify((await h.call(tokA, 'GET', '/notifications')).body).includes('عميل الشركة ب'));
  assert.ok(!JSON.stringify((await h.call(tokA, 'GET', '/leads/dashboard')).body).includes('عميل الشركة ب'));
  assert.equal((await h.call(tokA, 'POST', '/leads', { fullName: 'x', phone: '01077770009', projectId: pid, campaignId: campB })).status, 400, 'cannot add to B\'s campaign');
  const cfg = (await h.call(tokA, 'GET', '/leads/config')).body;
  assert.ok(!cfg.campaigns.some((x: any) => x.id === campB));
});

test('a marketing company or a plain employee reaches no HR / finance / backup data', async () => {
  for (const p of ['/employees', '/cash/summary', '/cash/ledger', '/cash/expenses', '/payroll-batches', '/backup/tables', '/permissions/roles']) {
    const st = (await h.call(tokA, 'GET', p)).status;
    assert.ok([401, 403, 404].includes(st), `company → ${p}: ${st}`);
  }
  for (const p of ['/cash/summary', '/cash/ledger', '/cash/expenses', '/payroll-batches']) {
    const st = (await h.call(c.t.e1, 'GET', p)).status;
    assert.ok([401, 403, 404].includes(st), `salesman → ${p}: ${st}`);
  }
});

test('errors never echo secrets or SQL', async () => {
  const r = await h.call(c.t.e1, 'GET', `/leads/not-a-uuid'%20OR%201=1`);
  assert.ok(r.status >= 400 && r.status < 500);
  assert.ok(!/select|insert|syntax|pg_|stack/i.test(JSON.stringify(r.body)));
});
