// 2026-11-24: two deployments migrating the same database at the same moment (two Vercel projects build every main push)
// — each pending migration is applied exactly once, neither runner fails, and a later run applies nothing.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { harness, RELEASE_2026_11_23, RELEASE_R2 } from './helpers.ts';
import { migrate } from '../src/migrate-core.ts';

test('two migrate() runs at once: every pending migration applied once, no failure, nothing left', async () => {
  const h = await harness('2026-03-10T08:00:00Z');
  try {
    // the test template leaves the 2026-11-23 release pending: both runners race for it
    const [a, b] = await Promise.all([migrate(h.db), migrate(h.db)]);
    assert.deepEqual([...a, ...b].sort(), [...RELEASE_2026_11_23, ...RELEASE_R2].sort(), 'each applied by exactly one runner');
    assert.equal(a.filter((x) => b.includes(x)).length, 0, 'never by both');
    const rows = (await h.db.query(`SELECT name, count(*)::int AS n FROM schema_migrations GROUP BY name HAVING count(*) > 1`)).rows;
    assert.deepEqual(rows, []);
    assert.deepEqual(await migrate(h.db), [], 'a third run applies nothing');
  } finally { await h.close(); }
});
