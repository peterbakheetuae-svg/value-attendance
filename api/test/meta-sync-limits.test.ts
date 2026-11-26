import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { CLAIM_MINUTES, FUNCTION_MAX_SECONDS, META_REQUEST_TIMEOUT_MS, SCHEDULED_BUDGET_MS } from '../src/lib/meta-sync-limits.ts';

/** two scheduled Meta syncs cannot overlap: a run dies (platform limit) long before its 5-minute claim lapses */
test('budget + one request < the function limit (read from vercel-build.mjs) < the claim', () => {
  const m = readFileSync(new URL('../scripts/vercel-build.mjs', import.meta.url), 'utf8').match(/maxDuration:\s*(\d+)/);
  assert.ok(m, 'maxDuration is set in vercel-build.mjs');
  assert.equal(Number(m![1]), FUNCTION_MAX_SECONDS, 'the constant matches the deployed limit');
  assert.ok(SCHEDULED_BUDGET_MS + META_REQUEST_TIMEOUT_MS < FUNCTION_MAX_SECONDS * 1000);
  assert.ok(FUNCTION_MAX_SECONDS * 1000 < CLAIM_MINUTES * 60_000);
});

import { Budget, eachWithin } from '../src/lib/meta-sync-limits.ts';

test('a large page of leads cannot carry the work past the budget: it is checked before every lead', async () => {
  let t = 0;
  const clock = () => t;
  const budget = new Budget(100, clock);               // 100 ms
  const seen: number[] = [];
  const leads = Array.from({ length: 1000 }, (_, i) => i);
  const done = await eachWithin(leads, budget, async (i) => { seen.push(i); t += 10; });   // each lead takes 10 ms
  assert.equal(done, false, 'an incomplete pass');
  assert.equal(seen.length, 10, 'leads started only while budget was left (t = 0..90)');
  assert.ok(t <= 100, `work ended at the budget (t=${t})`);
  // once spent, nothing more starts
  const after: number[] = [];
  assert.equal(await eachWithin([1, 2, 3], budget, async (i) => { after.push(i); }), false);
  assert.deepEqual(after, []);
});

test('enough budget: every lead is processed and the pass is complete; an empty page is complete', async () => {
  let t = 0;
  const budget = new Budget(1_000, () => t);
  const seen: number[] = [];
  assert.equal(await eachWithin([1, 2, 3], budget, async (i) => { seen.push(i); t += 5; }), true);
  assert.deepEqual(seen, [1, 2, 3]);
  assert.equal(await eachWithin([], budget, async () => { throw new Error('never'); }), true);
});

test('the worst case of a scheduled run stays inside the function limit', () => {
  // budget + one Meta request in flight when it runs out (a lead's transaction is milliseconds; the checkpoint is one UPDATE)
  assert.ok(SCHEDULED_BUDGET_MS + META_REQUEST_TIMEOUT_MS <= (FUNCTION_MAX_SECONDS - 4) * 1000, 'at least 4 s headroom');
});

import { passComplete } from '../src/lib/meta-sync-limits.ts';

test('regression: the final lead starts inside the budget but finishes past it → the pass is NOT complete', async () => {
  let t = 0;
  const budget = new Budget(100, () => t);
  const done: string[] = [];
  const cost: Record<string, number> = { a: 10, b: 10, final: 200 };   // the final lead starts at t=20 and ends at t=220
  const startedAt: Record<string, number> = {};
  const ok = await eachWithin(['a', 'b', 'final'], budget, async (x) => { startedAt[x] = t; t += cost[x]; done.push(x); });
  assert.equal(startedAt.final, 20, 'the final lead started while the budget was valid');
  assert.deepEqual(done, ['a', 'b', 'final'], 'its callback completed');
  assert.equal(t, 220, 'the clock is past the deadline');
  assert.equal(ok, false, 'eachWithin reports an incomplete pass');
  assert.equal(passComplete(true, budget), false, 'the checkpoint guard refuses to advance');
});

test('normal completion inside the budget: complete, and the checkpoint guard allows advancing', async () => {
  let t = 0;
  const budget = new Budget(100, () => t);
  assert.equal(await eachWithin(['a', 'b', 'c'], budget, async () => { t += 10; }), true);
  assert.equal(passComplete(true, budget), true);
  assert.equal(passComplete(false, budget), false, 'a pass cut short earlier stays incomplete');
  // a spent budget with nothing left to process is still not a complete pass
  t = 500;
  assert.equal(await eachWithin([], budget, async () => undefined), false);
  assert.equal(passComplete(true, budget), false);
});
