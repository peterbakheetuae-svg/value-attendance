import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';
import { buildRouter } from '../src/app.ts';

/**
 * Every write route, called as the owner (deepest access) with malformed input: no 5xx, no stack traces or SQL text in
 * the answer, security headers on every response. Synthetic throwaway database. Destructive admin routes are skipped.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-03-10T08:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });

const SKIP = /^(POST|PUT|PATCH|DELETE) \/(admin\/data-reset|auth\/logout|backup|year-closing)/;
const ID = '00000000-0000-4000-8000-000000000001';
const bodies: [string, string, string][] = [
  ['broken json', 'application/json', '{"a":'],
  ['array', 'application/json', '[1,2,3]'],
  ['wrong types', 'application/json', JSON.stringify({ amount: 'NaN', id: { $ne: 1 }, month: "2026-13' OR 1=1--", employeeId: '../../x', date: '9999-99-99', limit: -1e308, items: 'x'.repeat(5000), clientRef: 'not-a-uuid' })],
  ['nul / control chars', 'application/json', JSON.stringify({ name: 'a\u0000b', reason: '‮\u0000', code: '\uD800' })],
  ['form encoded', 'application/x-www-form-urlencoded', 'a=1&b=2'],
];

test('no write route answers 5xx or leaks internals to malformed input', async () => {
  const routes = buildRouter({ db: h.db, clock: () => new Date() }).list().filter((r) => /^(POST|PUT|PATCH|DELETE) /.test(r) && !SKIP.test(r));
  const bad: string[] = [];
  for (const rt of routes) {
    const [method, path] = rt.split(' ');
    const p = path.replace(/:month/g, '2026-03').replace(/:kind/g, 'photo').replace(/:[A-Za-z]+/g, ID);
    for (const [name, ct, body] of bodies) {
      const res = await fetch(h.base + p, { method, headers: { authorization: `Bearer ${c.t.owner}`, 'content-type': ct }, body: method === 'DELETE' ? undefined : body });
      const text = await res.text();
      if (res.status >= 500) bad.push(`${rt} [${name}] → ${res.status} ${text.slice(0, 120)}`);
      if (/at \w+ \(|node_modules|syntax error at|pg_|\bSELECT\b.*\bFROM\b/i.test(text)) bad.push(`${rt} [${name}] leaks internals: ${text.slice(0, 120)}`);
      if (res.headers.get('cache-control') !== 'no-store' || res.headers.get('x-content-type-options') !== 'nosniff') bad.push(`${rt} missing security headers`);
    }
  }
  assert.ok(routes.length > 150, `routes checked: ${routes.length}`);
  assert.deepEqual(bad, []);
});

test('no read route answers 5xx or leaks internals to hostile query strings', async () => {
  const routes = buildRouter({ db: h.db, clock: () => new Date() }).list().filter((r) => r.startsWith('GET ') && !/\/backup/.test(r));
  const qs = ['?q=%00&search=%27%20OR%201%3D1--', '?month=2026-13&date=9999-99-99&from=x&to=%27', '?limit=-1&offset=1e308&page=NaN&tab=constructor&kind=__proto__'];
  const bad: string[] = [];
  for (const rt of routes) {
    const p = rt.slice(4).replace(/:month/g, '2026-03').replace(/:kind/g, 'photo').replace(/:[A-Za-z]+/g, ID);
    for (const q of qs) {
      const res = await fetch(h.base + p + q, { headers: { authorization: `Bearer ${c.t.owner}` } });
      const text = await res.text();
      if (res.status >= 500) bad.push(`${rt} ${q} → ${res.status}`);
      if (/at \w+ \(|node_modules|syntax error at|\bSELECT\b.*\bFROM\b/i.test(text)) bad.push(`${rt} ${q} leaks internals`);
    }
  }
  assert.deepEqual(bad, []);
});
