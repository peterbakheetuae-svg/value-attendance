// /employees (Phase 6): the whole list without `limit` (no longer cut at 500); `limit` + `cursor` pages cover every employee once.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast } from './helpers.ts';
test('/employees: >500 all returned; limit/cursor pages cover everyone exactly once', async () => {
  const h = await harness('2026-03-10T08:00:00Z'); const c = await cast(h);
  await h.db.query(`INSERT INTO employees (code, full_name, role_key, job_title, joining_date, password_hash, must_change_password)
    SELECT 'P'||g, 'موظف '||(g % 37), 'sales_employee', '', '2026-01-01', 'x', false FROM generate_series(1,620) g`);
  const total = Number((await h.db.query(`SELECT count(*) FROM employees WHERE status = 'active'`)).rows[0].count);
  const all = (await h.call(c.t.owner, 'GET', '/employees')).body;
  assert.equal(all.employees.length, total); assert.equal(all.hasMore, undefined, 'no paging fields without limit (old shape)');
  const seen = new Set<string>(); let cursor: string | null = null; let pages = 0;
  do {
    const r: any = (await h.call(c.t.owner, 'GET', `/employees?limit=250${cursor ? `&cursor=${cursor}` : ''}`)).body;
    for (const e of r.employees) { assert.ok(!seen.has(e.id), 'no repeats across pages (duplicate names too)'); seen.add(e.id); }
    cursor = r.nextCursor; pages++;
  } while (cursor);
  assert.equal(seen.size, total);
  for (const bad of ['0', 'abc', '-3', '2.5']) assert.equal((await h.call(c.t.owner, 'GET', `/employees?limit=${bad}`)).status, 400, bad);
  assert.equal((await h.call(c.t.owner, 'GET', '/employees?limit=5&cursor=bad')).status, 400);
  await h.close();
});

test('/employees: q filter + sort hold across page boundaries (duplicate names split between pages)', async () => {
  const h = await harness('2026-03-10T08:00:00Z'); const c = await cast(h);
  await h.db.query(`INSERT INTO employees (code, full_name, role_key, job_title, joining_date, password_hash, must_change_password)
    SELECT 'Q'||g, 'موظف '||(g % 37), 'sales_employee', '', '2026-01-01', 'x', false FROM generate_series(1,300) g`);
  const whole = (await h.call(c.t.owner, 'GET', `/employees?q=${encodeURIComponent('موظف 3')}`)).body.employees.map((e: any) => e.id);
  assert.ok(whole.length > 40, 'filter matches many rows with repeated names');
  const paged: string[] = []; let cursor: string | null = null;
  do {
    const r: any = (await h.call(c.t.owner, 'GET', `/employees?q=${encodeURIComponent('موظف 3')}&limit=7${cursor ? `&cursor=${cursor}` : ''}`)).body;
    assert.ok(r.employees.every((e: any) => (e.full_name ?? e.fullName).includes('موظف 3')), 'every row on every page matches the filter');
    paged.push(...r.employees.map((e: any) => e.id)); cursor = r.nextCursor;
  } while (cursor);
  assert.deepEqual(paged, whole, 'same rows, same order, none skipped or repeated at the boundaries');
  await h.close();
});
