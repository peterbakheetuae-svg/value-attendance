import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { harness, cast, RELEASE_2026_11_23, RELEASE_R2, RELEASE_HANDOVER, RELEASE_094 } from './helpers.ts';
import { migrate, MIGRATIONS_DIR } from '../src/migrate-core.ts';

/**
 * The 2026-11-23 release moves 066 / 083–087 into db/migrations, so the production deploy (Vercel build of main) applies
 * them. This runs db/migrations exactly as the deploy does, on a database with the production schema before the
 * release and real-looking records — and checks the copies are the reviewed proposed files, unchanged.
 */
const file = (dir: 'migrations' | 'proposed', n: string) => readFileSync(new URL(`../../db/${dir}/${n}`, import.meta.url), 'utf8');

test('each release migration is the reviewed db/proposed file, unchanged, under a header (085: plus the stated baseline)', () => {
  for (const n of RELEASE_2026_11_23) {
    const m = file('migrations', n), p = file('proposed', n);
    assert.ok(m.endsWith(p), `${n}: the proposed file follows the header byte for byte`);
    const header = m.slice(0, m.length - p.length);
    assert.match(header, /^-- Applied by the release of 2026-11-23/);
    const code = header.split('\n').filter((l) => l.trim() && !l.trim().startsWith('--')).join('\n');
    if (n.startsWith('085')) assert.match(code, /^SELECT set_config\('valunivo\.owner_share_baseline'/, '085: only the baseline is stated');
    else assert.equal(code, '', `${n}: the header is comments only`);
  }
});

test('the deploy path: db/migrations on the pre-release production schema with records — applied once, in order, nothing lost', async () => {
  const h = await harness('2026-03-10T08:00:00Z');
  try {
    const c = await cast(h);
    // records as production has them: money from March, an owner with his share
    assert.equal((await h.call(c.t.owner, 'POST', '/cash/adjustments', { cashbox: 'office', kind: 'opening', amount: 50000, reason: 'رصيد افتتاحي' })).status, 201);
    assert.equal((await h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'reservation', amount: 2000, payerName: 'عميل', purpose: 'حجز', clientRef: randomUUID() })).status, 201);
    await h.db.query(`INSERT INTO company_owners (employee_id, pct) VALUES ($1, 60), ($2, 40)`, [c.ids.owner, c.ids.hr]);
    const before = {
      receipts: (await h.db.query(`SELECT count(*)::int n, sum(amount_egp) s FROM cash_receipts`)).rows[0],
      employees: (await h.db.query(`SELECT count(*)::int n FROM employees`)).rows[0].n,
      perms: (await h.db.query(`SELECT count(*)::int n FROM role_permissions`)).rows[0].n,
    };
    const meBefore = (await h.call(c.t.hr, 'GET', '/me')).body.permissions as string[];

    const applied = await migrate(h.db);
    assert.deepEqual(applied, [...RELEASE_2026_11_23, ...RELEASE_HANDOVER, ...RELEASE_R2, ...RELEASE_094], 'exactly the releases, in order');
    assert.deepEqual(await migrate(h.db), [], 'a second deploy applies nothing');
    const all = (await h.db.query(`SELECT name FROM schema_migrations ORDER BY name`)).rows.map((r) => r.name);
    for (const n of RELEASE_2026_11_23) assert.ok(all.includes(n));

    // 085: today's shares in force from the first month money was recorded (March 2026), kept in the audit log
    const shares = (await h.db.query(`SELECT employee_id, pct::float, to_char(effective_from, 'YYYY-MM-DD') f FROM company_owner_shares ORDER BY pct DESC`)).rows;
    assert.deepEqual(shares.map((s) => [s.employee_id, s.pct, s.f]), [[c.ids.owner, 60, '2026-03-01'], [c.ids.hr, 40, '2026-03-01']]);
    const stated = (await h.db.query(`SELECT after FROM audit_log WHERE action = 'owners.share_baseline'`)).rows[0];
    assert.ok(JSON.stringify(stated?.after ?? '').includes('2026-03-01'), 'the stated month is in the audit log');

    // nothing lost or changed: the money, the people, and nobody gains or loses access (066)
    const after = (await h.db.query(`SELECT count(*)::int n, sum(amount_egp) s FROM cash_receipts`)).rows[0];
    assert.deepEqual(after, before.receipts);
    assert.equal((await h.db.query(`SELECT count(*)::int n FROM employees`)).rows[0].n, before.employees);
    const meAfter = (await h.call(c.t.hr, 'GET', '/me')).body.permissions as string[];
    for (const k of meBefore) assert.ok(meAfter.includes(k), `HR keeps ${k}`);
    assert.ok((await h.db.query(`SELECT count(*)::int n FROM role_permissions`)).rows[0].n >= before.perms);

    // the features that waited for them are on
    assert.equal((await h.call(c.t.owner, 'GET', '/cash/expense-classes')).body.installed, true, '086');
    assert.equal((await h.call(c.t.owner, 'GET', '/brokerage/status')).body.installed, true, '087');
    assert.equal((await h.call(c.t.owner, 'GET', '/cash/summary')).status, 200);
  } finally { await h.close(); }
});

test('the deploy path on a database with no money yet: 085 states this month and copies the shares', async () => {
  const h = await harness('2026-03-10T08:00:00Z');
  try {
    const c = await cast(h);
    await h.db.query(`INSERT INTO company_owners (employee_id, pct) VALUES ($1, 100)`, [c.ids.owner]);
    await migrate(h.db);
    const s = (await h.db.query(`SELECT to_char(effective_from, 'YYYY-MM') f FROM company_owner_shares`)).rows;
    const thisMonth = (await h.db.query(`SELECT to_char(now() AT TIME ZONE 'Africa/Cairo', 'YYYY-MM') m`)).rows[0].m;
    assert.deepEqual(s.map((x) => x.f), [thisMonth]);
  } finally { await h.close(); }
});

test('MIGRATIONS_DIR holds the release (the deploy reads this folder)', () => {
  assert.ok(MIGRATIONS_DIR.endsWith('db/migrations'));
});
