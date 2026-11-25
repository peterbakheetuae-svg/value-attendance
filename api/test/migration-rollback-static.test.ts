// Rollback scripts are NEVER executed by tests or release validation (a rollback on a live database destroys what was
// created after the migration). They are checked here as text only: each one may remove only what its own forward
// migration adds — no TRUNCATE, no DROP SCHEMA, no DELETE without WHERE, no permission key the migration did not add.
// Forward behaviour (install, second run, data untouched) is tested on throw-away databases in the migration's own tests.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';

const dir = new URL('../../db/proposed/', import.meta.url);
const read = (n: string) => readFileSync(new URL(n, dir), 'utf8');
const strip = (sql: string) => sql.replace(/--[^\n]*/g, '');
const PAIRS = readdirSync(dir).filter((f) => /^\d{3}_rollback\.sql$/.test(f)).sort()
  .map((r) => ({ rollback: r, forward: readdirSync(dir).find((f) => f.startsWith(r.slice(0, 4)) && !/_(rollback|preview)\.sql$/.test(f))! }));

test('every proposed rollback has its forward migration', () => {
  assert.ok(PAIRS.length >= 5, JSON.stringify(PAIRS));
  for (const p of PAIRS) assert.ok(p.forward, `${p.rollback} has no forward migration`);
});

for (const { rollback, forward } of PAIRS) {
  test(`${rollback}: removes only what ${forward} adds (static check, not executed)`, () => {
    const rb = strip(read(rollback)); const fw = strip(read(forward));
    assert.doesNotMatch(rb, /\bTRUNCATE\b|\bDROP\s+SCHEMA\b|\bDROP\s+DATABASE\b/i, 'no TRUNCATE / DROP SCHEMA / DROP DATABASE');
    for (const m of rb.matchAll(/\bDELETE\s+FROM\s+(\w+)([^;]*);/gi)) {
      assert.match(m[2], /\bWHERE\b/i, `DELETE FROM ${m[1]} must have a WHERE`);
    }
    const created = (name: string) => new RegExp(
      `(CREATE\\s+(OR\\s+REPLACE\\s+)?(UNIQUE\\s+)?(TABLE|INDEX|TRIGGER|FUNCTION)(\\s+IF\\s+NOT\\s+EXISTS)?\\s+(public\\.)?${name}\\b`
      + `|ADD\\s+(COLUMN|CONSTRAINT)(\\s+IF\\s+NOT\\s+EXISTS)?\\s+${name}\\b)`, 'i').test(fw);
    const dropped: string[] = [];
    for (const m of rb.matchAll(/\bDROP\s+(TABLE|INDEX|TRIGGER|FUNCTION)\s+(IF\s+EXISTS\s+)?([^;]+);/gi)) {
      const list = m[1].toUpperCase() === 'TRIGGER' ? [m[3].split(/\s+ON\s+/i)[0]] : m[3].split(/,(?![^(]*\))/);   // commas outside a signature
      for (const x of list) dropped.push(x.trim().replace(/\(.*$/, '').replace(/^public\./, ''));
    }
    for (const m of rb.matchAll(/\bDROP\s+(COLUMN|CONSTRAINT)\s+(IF\s+EXISTS\s+)?(\w+)/gi)) dropped.push(m[3]);
    for (const name of dropped.filter(Boolean)) {
      // 084 replaces cash_expenses_status_check with a wider one; its rollback puts the original check back
      if (name === 'cash_expenses_status_check' && /cash_expenses_status_check/.test(fw)) continue;
      assert.ok(created(name), `${rollback} drops ${name}, which ${forward} does not create`);
    }
    // permission keys removed by the rollback are exactly keys the forward migration adds
    for (const m of rb.matchAll(/\bDELETE\s+FROM\s+(permissions|role_permissions|employee_permissions)\s+WHERE\s+(key|perm_key)\s+IN\s*\(([^)]*)\)/gi)) {
      for (const k of m[3].match(/'[^']+'/g) ?? []) assert.ok(fw.includes(k), `${rollback} removes permission ${k}, which ${forward} does not add`);
    }
  });
}

test('no test file executes (or even names) a rollback script — only this static check reads them', () => {
  const tests = new URL('./', import.meta.url);
  const offenders = readdirSync(tests).filter((f) => f.endsWith('.ts') && f !== 'migration-rollback-static.test.ts')
    .filter((f) => /_rollback\.sql/.test(readFileSync(new URL(f, tests), 'utf8')));
  assert.deepEqual(offenders, []);
});
