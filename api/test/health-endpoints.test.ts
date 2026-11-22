import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';
import { buildRouter } from '../src/app.ts';
import { createFetchHandler } from '../src/http/router.ts';

/** Public health routes: no configuration disclosure, at most one DB query per 5 s for anonymous callers; owner sees details. */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness(); c = await cast(h); });
after(async () => { await h.close(); });

test('anonymous /readyz and /healthz/latency disclose no configuration', async () => {
  const r = await h.call(null, 'GET', '/readyz');
  assert.equal(r.status, 200);
  assert.deepEqual(Object.keys(r.body), ['ok']);
  const l = await h.call(null, 'GET', '/healthz/latency');
  assert.equal(l.status, 200);
  assert.deepEqual(Object.keys(l.body).sort(), ['dbRoundTripMs', 'ok']);
  assert.equal(l.body.dbRoundTripMs.length, 1);
  // a non-owner token gets the public answer too
  assert.deepEqual(Object.keys((await h.call(c.t.e1, 'GET', '/readyz')).body), ['ok']);
  assert.deepEqual(Object.keys((await h.call('not-a-token', 'GET', '/healthz/latency')).body).sort(), ['dbRoundTripMs', 'ok']);
});

test('owner keeps the full monitoring detail', async () => {
  const r = await h.call(c.t.owner, 'GET', '/readyz');
  assert.ok(Number.isInteger(r.body.migrations) && 'push' in r.body && 'mail' in r.body && 'backup' in r.body);
  const l = await h.call(c.t.owner, 'GET', '/healthz/latency');
  assert.equal(l.body.dbRoundTripMs.length, 4);
  assert.ok('dbRegion' in l.body && 'apiRegion' in l.body);
});

test('a flood of anonymous health checks costs one database query', async () => {
  let n = 0;
  const counting = { ...h.db, query: (t: string, v?: unknown[]) => { if (t === 'SELECT 1') n++; return h.db.query(t, v); } } as any;
  const fetchH = createFetchHandler(buildRouter({ db: counting, clock: () => new Date() }), { corsOrigins: [] });
  const rs = await Promise.all(Array.from({ length: 100 }, (_, i) =>
    fetchH(new Request('http://x' + (i % 2 ? '/readyz' : '/healthz/latency')))));
  assert.ok(rs.every((x) => x.status === 200));
  assert.equal(n, 1);
});
