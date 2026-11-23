import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

/**
 * «إنجاز» a repeated lead (مكرر): the management decides — it stays with the original's salesman, it moves to the one
 * who added it again WITH its history, or it moves to him as a fresh lead (gone from the original's salesman).
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let pid: string;
before(async () => {
  h = await harness('2026-11-14T08:00:00Z'); c = await cast(h);
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [c.ids.acc]);
  pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'برج المكرر', ownerName: 'أ. سامي', ownerPhone: '0100' })).body.project.id;
});
after(async () => { await h.close(); });

let n = 0;
/** e3 has the customer (with a comment); e1 adds him again (with his own comment) */
async function pair() {
  const phone = `0111000${String(1000 + ++n)}`;
  const orig = await h.call(c.t.e3, 'POST', '/leads', { fullName: `عميل ${n}`, phone, projectId: pid });
  assert.equal(orig.status, 201, JSON.stringify(orig.body));
  const o = orig.body.lead.id as string;
  assert.equal((await h.call(c.t.e3, 'POST', `/leads/${o}/actions`, { stage: 'following', answered: true, comment: 'كلمته أول مرة', nextAt: '2026-11-15T10:00:00Z' })).status, 201);
  const rep = await h.call(c.t.e1, 'POST', '/leads', { fullName: `عميل ${n}`, phone, projectId: pid, confirmDuplicate: true });
  assert.equal(rep.status, 201, JSON.stringify(rep.body));
  const r = rep.body.lead.id as string;
  assert.equal((await h.call(c.t.e1, 'POST', `/leads/${r}/actions`, { stage: 'following', answered: true, comment: 'كلمته تاني', nextAt: '2026-11-15T11:00:00Z' })).status, 201);
  return { o, r };
}
const lead = async (id: string) => (await h.db.query(`SELECT * FROM leads WHERE id = $1`, [id])).rows[0];
const comments = async (id: string) => (await h.db.query(`SELECT comment FROM lead_actions WHERE lead_id = $1`, [id])).rows.map((x) => x.comment as string).sort((a, b) => (a === 'كلمته أول مرة' ? -1 : b === 'كلمته أول مرة' ? 1 : 0));

test('who may decide: the management sees «إنجاز» on a repeated lead; the salesmen may not', async () => {
  const { o, r } = await pair();
  const asOwner = (await h.call(c.t.owner, 'GET', `/leads/${r}`)).body;
  assert.equal(asOwner.can.resolveDuplicate, true);
  assert.equal((await h.call(c.t.owner, 'GET', `/leads/${o}`)).body.can.resolveDuplicate, false, 'the original is not a repeat');
  assert.equal((await h.call(c.t.e1, 'GET', `/leads/${r}`)).body.can.resolveDuplicate, false);
  assert.equal((await h.call(c.t.e1, 'POST', `/leads/${r}/duplicate-resolve`, { decision: 'keep_old' })).status, 403);
  assert.equal((await h.call(c.t.owner, 'POST', `/leads/${r}/duplicate-resolve`, { decision: 'nope' })).status, 400);
  assert.equal((await h.call(c.t.owner, 'POST', `/leads/${o}/duplicate-resolve`, { decision: 'keep_old' })).body.error.details.reason, 'not_duplicate');
});

test('يفضل عند القديم: one lead, with the original salesman, both comments; the repeat is gone from «مكرر»', async () => {
  const { o, r } = await pair();
  const res = await h.call(c.t.acc, 'POST', `/leads/${r}/duplicate-resolve`, { decision: 'keep_old' });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.leadId, o);
  assert.equal(await lead(r), undefined);
  assert.equal((await lead(o)).assigned_to, c.ids.e3);
  assert.deepEqual(await comments(o), ['كلمته أول مرة', 'كلمته تاني']);
  assert.equal((await h.call(c.t.e1, 'GET', `/leads/${o}`)).status, 404, 'the one who added it again no longer has it');
  assert.equal((await h.call(c.t.e3, 'GET', `/leads/${o}`)).status, 200);
  const told = (await h.db.query(`SELECT count(*)::int n FROM notifications WHERE type = 'lead_duplicate_resolved' AND recipient_id = $1`, [c.ids.e1])).rows[0].n;
  assert.ok(told >= 1, 'the salesman who added it again is told');
  assert.equal((await h.call(c.t.acc, 'POST', `/leads/${r}/duplicate-resolve`, { decision: 'keep_old' })).status, 404, 'decided once');
});

test('يترحل بالسجل بتاعه: the original moves to the new salesman with its whole history', async () => {
  const { o, r } = await pair();
  const res = await h.call(c.t.owner, 'POST', `/leads/${r}/duplicate-resolve`, { decision: 'move_with_history' });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.leadId, o);
  assert.equal(await lead(r), undefined);
  const l = await lead(o);
  assert.equal(l.assigned_to, c.ids.e1);
  assert.equal(l.duplicate_of, null);
  assert.deepEqual(await comments(o), ['كلمته أول مرة', 'كلمته تاني']);
  assert.equal((await h.call(c.t.e3, 'GET', `/leads/${o}`)).status, 404, 'gone from the original salesman');
  const seen = await h.call(c.t.e1, 'GET', `/leads/${o}`);
  assert.equal(seen.status, 200);
  assert.equal(seen.body.actions.length, 2, 'he sees the old comments too');
});

test('يختفي من عند القديم ويفضل مع الجديد: the repeat stays as a fresh lead; the original and its history go (audit log keeps them)', async () => {
  const { o, r } = await pair();
  const res = await h.call(c.t.owner, 'POST', `/leads/${r}/duplicate-resolve`, { decision: 'move_fresh' });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.leadId, r);
  assert.equal(await lead(o), undefined);
  const l = await lead(r);
  assert.equal(l.assigned_to, c.ids.e1);
  assert.equal(l.duplicate_of, null, 'a normal lead now');
  assert.deepEqual(await comments(r), ['كلمته تاني'], 'without the old history');
  assert.equal((await h.call(c.t.e3, 'GET', `/leads/${r}`)).status, 404);
  const kept = (await h.db.query(`SELECT before FROM audit_log WHERE action = 'lead.duplicate_original_removed' AND entity_id = $1`, [o])).rows[0];
  assert.equal(kept.before.lead.id, o);
  assert.equal(kept.before.actions[0].comment, 'كلمته أول مرة');
  assert.equal((await h.call(c.t.owner, 'GET', '/leads?tab=duplicated')).body.leads.some((x: any) => x.id === r), false, 'no longer in «مكرر»');
});
