/**
 * The scheduled Meta sync's time limits (modules/meta_sync.ts → runScheduledMetaSync). The overlap guarantee rests on:
 *   budget + one Meta request in flight  <  the function's hard limit (Vercel maxDuration)  <  the claim on meta_sync_at
 * so a run is always killed by the platform long before another run could take the claim. test/meta-sync-limits.test.ts
 * checks these against scripts/vercel-build.mjs.
 */
export const SCHEDULED_BUDGET_MS = 18_000;
export const META_REQUEST_TIMEOUT_MS = 8_000;   // lib/meta-oauth.ts metaFetch
export const FUNCTION_MAX_SECONDS = 30;         // scripts/vercel-build.mjs maxDuration
export const CLAIM_MINUTES = 5;
