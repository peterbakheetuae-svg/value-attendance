import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

// /media/links + /media/:kind/:id: links only within the requester's scope, bound to him, re-checked when opened.
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  for (const id of [c.ids.e1, c.ids.e2, c.ids.e3, c.ids.hr, c.ids.sm1]) {
    await h.db.query(`UPDATE employees SET photo = '\\xffd8ffd9', photo_mime = 'image/jpeg' WHERE id = $1`, [id]);
  }
});
after(async () => { await h.close(); });
const links = async (t: string, photos: string[] = [], selfies: string[] = []) =>
  (await h.call(t, 'POST', '/media/links', { photos, selfies })).body.links as Record<string, string>;

test('photo links: own always; colleagues outside scope never; team / company readers within scope', async () => {
  const all = [c.ids.e1, c.ids.e2, c.ids.e3, c.ids.hr, c.ids.sm1];
  assert.deepEqual(Object.keys(await links(c.t.e1, all)).sort(), [`photo:${c.ids.e1}`], 'an employee: only his own');
  const sm = Object.keys(await links(c.t.sm1, all));
  assert.ok(sm.includes(`photo:${c.ids.e1}`) && sm.includes(`photo:${c.ids.e2}`) && sm.includes(`photo:${c.ids.sm1}`));
  assert.ok(!sm.includes(`photo:${c.ids.e3}`) && !sm.includes(`photo:${c.ids.hr}`), 'not another team / HR');
  assert.equal(Object.keys(await links(c.t.hr, all)).length, all.length, 'HR reads every employee');
  // invented / other ids are simply left out
  assert.deepEqual(await links(c.t.e1, ['00000000-0000-4000-8000-000000000000', 'not-an-id']), {});
  assert.equal((await h.call(null, 'POST', '/media/links', { photos: [c.ids.e1] })).status, 401);
});

test('a link is bound to its viewer: it cannot be re-signed for someone else or reused after access is taken away', async () => {
  const url = (await links(c.t.sm1, [c.ids.e1]))[`photo:${c.ids.e1}`];
  assert.equal((await h.call(null, 'GET', url)).status, 200);
  // changing the photo id or the viewer breaks the signature
  assert.equal((await h.call(null, 'GET', url.replace(c.ids.e1, c.ids.e3))).status, 404);
  assert.equal((await h.call(null, 'GET', url.replace(/v=[^&]+/, `v=${c.ids.hr}`))).status, 404);
  assert.equal((await h.call(null, 'GET', url.replace(/&v=[^&]+/, ''))).status, 404, 'unbound links are refused');
  // his team reading is taken away: the same (unexpired) link stops working at once
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'employee.read_team', false), ($1, 'attendance.read_team', false)`, [c.ids.sm1]);
  assert.equal((await h.call(null, 'GET', url)).status, 404);
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [c.ids.sm1]);
  assert.equal((await h.call(null, 'GET', url)).status, 200);
  // the viewer's account is deactivated: dead too
  await h.db.query(`UPDATE employees SET status = 'inactive' WHERE id = $1`, [c.ids.sm1]);
  assert.equal((await h.call(null, 'GET', url)).status, 404);
  await h.db.query(`UPDATE employees SET status = 'active' WHERE id = $1`, [c.ids.sm1]);
});

test('leads distributors see the salesmen they assign to; selfies stay within attendance scope', async () => {
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'leads.distribute', true)`, [c.ids.acc]);
  const acc = Object.keys(await links(c.t.acc, [c.ids.e1, c.ids.e3, c.ids.hr]));
  assert.ok(acc.includes(`photo:${c.ids.e1}`) && acc.includes(`photo:${c.ids.e3}`), 'salesmen');
  assert.ok(!acc.includes(`photo:${c.ids.hr}`), 'not HR');
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [c.ids.acc]);
  // a selfie of E3 (team B): he checks in, the selfie row is attached to that day
  assert.equal((await h.call(c.t.e3, 'POST', '/attendance/check-in', {})).status, 201);
  const att = (await h.db.query(`SELECT id FROM attendance WHERE employee_id = $1`, [c.ids.e3])).rows[0];
  await h.db.query(`INSERT INTO attendance_selfies (attendance_id, employee_id, image, mime) VALUES ($1,$2,'\\xffd8ffd9','image/jpeg')`, [att.id, c.ids.e3]);
  assert.equal((await links(c.t.sm1, [], [att.id]))[`selfie:${att.id}`], undefined, 'other team');
  const u = (await links(c.t.sm2, [], [att.id]))[`selfie:${att.id}`];
  assert.ok(u, 'his team');
  assert.equal((await h.call(null, 'GET', u)).status, 200);
  assert.equal((await links(c.t.e2, [], [att.id]))[`selfie:${att.id}`], undefined, 'a colleague');
});
