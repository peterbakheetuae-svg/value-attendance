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
