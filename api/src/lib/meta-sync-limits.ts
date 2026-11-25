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

/** a wall-clock budget: once spent it stays spent (no new database work or Meta request starts after it) */
export class Budget {
  private readonly stopAt: number;
  constructor(ms: number, private readonly clock: () => number = Date.now) { this.stopAt = clock() + ms; }
  left(): boolean { return this.clock() < this.stopAt; }
}

/**
 * Runs fn on each item in order while the budget lasts. The budget is checked before EVERY item (no new work starts once
 * it is spent) and again after every item returns — so a pass whose last item ran past the deadline is NOT complete.
 * Returns true only if every item was processed and the budget was still left at the end.
 */
export async function eachWithin<T>(items: readonly T[], budget: Budget, fn: (item: T) => Promise<void>): Promise<boolean> {
  for (const item of items) {
    if (!budget.left()) return false;
    await fn(item);
    if (!budget.left()) return false;
  }
  return budget.left();
}

/** a pass counts as complete (its checkpoint may move) only if nothing cut it short AND the budget is still left now */
export const passComplete = (complete: boolean, budget: Budget): boolean => complete && budget.left();
