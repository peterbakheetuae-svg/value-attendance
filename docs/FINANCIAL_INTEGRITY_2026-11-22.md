# Financial integrity, expense classification, payroll performance (2026-11-22)

Owner-approved Phase 6 of the coordinated initiative (audit: «VALUNIVO — Phase 1–4 Read-Only Audit & Consolidated Plan»).
Branch `pending-build`, **not committed, not pushed, not deployed, no migration run anywhere but throw-away test databases.**

## What changed (behaviour)

| Finding | Change | Where |
| --- | --- | --- |
| F1 | A payroll sheet line pays the **salary part only** (`net − commissions − work expenses`, the rule صرف الراتب always used). Commissions settle via صرف العمولة (linked entitlement), work expenses via صرف الطلب (linked request). Every payroll result carries `salaryDue`, `salaryShortfall` and `components` (salary / commissions / workExpenses: due, paid, remaining, status). **Legacy coverage (v4) comes only from explicit sheet records**: a stored batch line whose snapshot is not `settles: salary_only` and that included commissions / work expenses, in a batch that was not cancelled, with payouts linked to that line (`batch_line_id`). Covered = what those payouts paid above the line's salary part, capped at the line's commissions + work expenses, allocated commissions first (entitlements included by the sheet's freeze time), then work expenses. Such items show `paid_in_payroll` / `partly_in_payroll`; a direct payment can only pay what is left (exact amount). **A plain salary overpayment never counts as paying a commission.** | `legacy-coverage.ts`, `payroll-calc.ts`, `payroll-batches.ts`, `payouts.ts`, `commissions.ts` |
| F2 | `POST /payouts` refuses `kind: salary` (`salary_path_required`) and a commission without `entitlementId` (`entitlement_required`). The app never used either form. A free-form advance / work-expense payout is unchanged (see remaining risks). | `payouts.ts` |
| F3 | `/cash/summary` counts the HR cashbox's own pending expenses only. | `cash.ts` |
| F4 | Exclusive units: one limit for the deposit / down payment across «تم استلام المبلغ» and the direct receipt; a request is closed (audited) once the money came in directly; no receipt on a marketing (broker) project's unit (`not_exclusive`). **Concurrency (v4):** every collection locks the unit row first (`FOR UPDATE`), then checks the limit; the `clientRef` retry check runs after the lock; the same `clientRef` for another unit / kind → 409 `client_ref_reused`; a unique-violation race returns the first receipt. Tested with truly parallel requests. | `exclusive.ts` |
| F5 | Owner profit (`result.net`): an advance paid through the cashbox against an approved request is a receivable — out of the costs when paid. **Recovery is amount-based (v4):** per employee and month, the amount actually deducted (explicit active deductions, or the default whole-advance rule) limited to what the month's salary could absorb (`absorbed = max(0, min(advances, advances + min(0, salaryDue)))`). It is recognised as the salary payouts are received (pro rata, exact on full receipt); when nothing is left to pay in cash, on the month's last day once the month is over. Unrecovered balance is reported as `advancesOutstanding`. Cash movements are reported as before. `result` adds `cashCosts`, `advancesPaid`, `advancesRecovered`. | `cash.ts` `advanceRecoveries`, `profitParts` |
| F6 | Ownership-share history (`company_owner_shares`, migration 085): each month's net × the share in force that month — initial, added, removed, changed, mid-month and multi-month cases tested; a former owner keeps the months he owned (still listed while a historic share > 0). Until 085 runs: today's share, as before. | `cash.ts` |
| F7 | One salary-part rule everywhere (salaries list, payroll sheet, finance dashboard `remaining` / `salariesDue`, owner dashboard). | `finance-dashboard.ts`, `owner-dashboard.ts` |
| F8 | A commission settled inside a payroll sheet cannot be voided (`settled_in_payroll`). | `commissions.ts` |
| F9 | 085 (v4, full guard): a payout cannot be deleted once received; identity, amount, kind, period, links, note and creator are immutable; a received or cancelled payout is entirely final (incl. `received_at`, confirmation fields); pending / disputed may only move to received (stamps `received_at` once), cancelled, or pending → disputed. One live payout per advance (unique index; 085 refuses to install if duplicates exist). | `db/proposed/085` |
| C | Expense groups and categories (migration 086) — metadata only, see below. | `expense-classes.ts`, `cash.ts`, app `cash/expense_classes.dart` |
| A | Set-based payroll (fixed number of queries for all employees), `/employees` paging, advances list, logo 2048 px → 512 px. | see measurements |

## Performance methodology used (the Speed Engineer skill was NOT read)

The skill file (`OneDrive\Documents\speed-engineer-SKILL.md`) was not accessible to this session; nothing here claims to
follow it. Method used instead: **measure first, change only what a measurement shows, prove identical results.**

1. Real API + throw-away PostgreSQL 16 on one machine, synthetic employees (50 / 300) with salaries, a month of attendance
   and advances; latency, response size and **query count per request** (pg client instrumented). Query count is the
   figure that transfers to production: on Neon each query pays a network round trip (`/healthz/latency` shows it live).
2. Volume test: 500,000 cash rows → cash book queries 20–140 ms → **no index, no cache added**.
3. Equivalence: the original payroll code (git copy) and the new one compared **field by field** for 60 varied employees
   × 3 months × 3 deduction modes = 540 results, single and batch paths: identical.

| Endpoint (300 employees) | Before | After |
| --- | --- | --- |
| GET /payouts/salaries | 4,505 queries · 820 ms | 18 queries · 275 ms |
| POST /payroll-batches | 4,511 q · 819 ms | 39 q · 524 ms |
| GET /dashboard/owner | 4,217 q · 429 ms (held the whole pool) | 30 q · 70 ms |
| GET /finance/dashboard | 8,420 q · 1,529 ms | 46 q · 90 ms |
| GET /advances/open | 2 q per advance | 4 q |
| GET /insights/employees | ~8 q per employee (2,493) | 37 q |
| /employees | cut at 500 | full list; `?limit=&cursor=` pages |

Local numbers (same machine, ~0.2 ms per query). Not production benchmarks.

## Migrations (prepared in `db/proposed/` only — never run on Neon without the owner's approval)

**Dependency order: 066 → 083 → 084 → 085 → 086** (each file in one transaction, as the runner applies it; by hand `psql -1`).
Each is additive, has a rollback file and is exercised by the test suite on throw-away databases. If the 2026-11-18
clean-up is ever approved, it goes **before 085 / 086** (see below).

* Chain check (scratch PostgreSQL 16, 2026-11-22): 066 → 083 → 084 → 085 → 086 each apply cleanly; rollbacks 086 → 066
  return the database to exactly its starting schema / permissions. **066, 085, 086 are safe to re-run; 083 and 084 are
  NOT** (a second run stops at «already exists» — harmless, each runs in one transaction, but apply them only once:
  check `schema_migrations` / the object first).
* **085** refuses to install (and names them) if any request already has two live payouts. Copies today's
  `company_owners` into the history as in force since 2000-01 (no figure moves).
* **086** adds three tables and two nullable columns on `cash_expenses` / `fixed_expenses`. No back-fill.
* ⚠ **If the 2026-11-18 clean-up script (`db/ops/2026-11-18-keep-active-employees.sql`) is still planned, run it before 085 / 086**:
  after them, the new tables reference employees, and deleting a former employee / company owner they point to is refused.

`db/ops/2026-11-22-detect-duplicate-settlements.sql`: READ ONLY (ends with ROLLBACK) — candidates of past double payments /
collections. Approved for Neon on 2026-11-22 but **not run**: this session has no authorized connection to Neon
(Vercel's `DATABASE_URL` is a write-only sensitive variable; the Hostinger server has no database access; the Neon
connector is not connected). Production `/readyz` reports 73 applied migrations = `db/migrations` only, so 066 / 083 / 084
are not applied there yet — 085 / 086 stay unapplied until 083 / 084 are, the inspection has run, and the 2026-11-18
clean-up question is settled.

### ⚠ Rollback = data loss for anything created after the migration

The rollback files are for a failed install on a test copy, **not** an undo button on a live database:

* `086_rollback.sql` drops the group / category tables and the two classification columns → every classification made
  after 086 is lost (the expenses and money stay; only their group / category goes).
* `085_rollback.sql` drops `company_owner_shares` and the payout guard → the ownership-share history (every change made
  after 085) is lost and payouts become editable again.
* `066_rollback.sql` removes the fine-grained permissions → per-key grants made after 066 are lost.

Back up (Neon branch) before any rollback; never run one against production without the owner's explicit decision.

## clientRef retries are answered only to their sender (release review, 2026-11-22)

Before: a form retry (same `clientRef`) returned the existing receipt / expense to **whoever** presented the reference —
`POST /cash/receipts` answered with the full receipt (payer, phone, amount, number) without checking the caller's
cashbox scope; expenses, owner draws, transfers, sale and exclusive-unit collections had the same lookup.
Exploitability was low (the reference is a random UUIDv4 the API never returns), but the authorization check was missing.
Now every `client_ref` lookup (`priorByClientRef` in `cash.ts`, `sales.ts`, `exclusive.ts`) matches the original
`recorded_by`: the sender's retry is unchanged; anybody else gets `409 client_ref_reused` and nothing of the row.
Regression tests: `api/test/client-ref-scope.test.ts` (both fail on the old code, pass on the new).

## Known limitations (reported, not changed — business decisions)

* F5: a month with nothing to pay in cash recognises its recovery on the month's last day; the cashbox share of a recovery
  is pro rata to salary payouts received.
* Payroll is recomputed live from current data (rules, attendance, deductions); only batch lines keep a frozen snapshot.
* An advance / work-expense payout without a linked request is still accepted, and such an unlinked advance is never
  deducted from payroll.

* `/employees?q=` is a sequential scan + top-N sort (2.5 ms for 5,000 employees, leading-wildcard ILIKE cannot use a
  btree); no index added.
* Nothing was verified on Neon: this round explicitly does not authorise access.

## Expense classification (086)

* Groups (level 1) and categories (level 2); a category is one row reused by many groups. Archive / reactivate, never delete.
  One active name each (case-insensitive).
* An expense: optional group + category. The text «البند» stays required and unchanged, so every existing report works.
* Totals: posted expenses, ledger date `COALESCE(approved_at, occurred_at)` (Cairo), each expense once, only the boxes the
  viewer may see; trust money / unit refunds / owner withdrawals are not office expenses and are not classified.
* Re-classification: metadata only, audited (`cash.expense.reclassify`, before → after), allowed in a closed year.
* API: `GET /cash/expense-classes`, `POST|PATCH /cash/expense-classes/{groups|categories}[/:id]`,
  `GET /cash/expense-classes/{groups|categories}/:id`, `GET /cash/expense-classes/report?by=&every=&from=&to=&status=`,
  `PATCH /cash/expenses/:id/classification`; `POST /cash/expenses` and fixed expenses accept `groupId` / `categoryId`;
  `GET /cash/expenses?groupId=&categoryId=&unclassified=1`.
* An archived group / category stays on the expenses that carry it, still counts in reports and leaves balances unchanged;
  only a **new** assignment to it is refused. Employees without cashbox access are refused (tested).
* App: Cash → المصروفات → «المجموعات» tab (groups · categories · report), two optional pickers in «تسجيل مصروف», a chip
  and «تصنيف» on each expense. Hidden until 086 runs.

## Coordination notes for the other agents

* **Permissions:** `expense.classification_manage` and `expense.reclassify` are registered in
  `api/src/lib/permission-registry.ts` (`since: 86`, `splitFrom: 'cash.office'`, module «الخزن»). Migration 086 adds them
  with 066's split mechanics: job titles holding `cash.office` get them, individual `cash.office` exceptions carry over,
  nobody gains or loses access (tested). Before 086 the code falls back to `cash.office`. The accountant may also
  classify his own cashbox's expenses (`hrDesk`). The «الصلاحيات» screen picks the keys up from the registry.
* **Windows-EXE agent:** no Windows file is changed (`flutter pub get` rewrote two generated Windows files locally; both were restored).
* **Security Remediation:** not resumed; none of its files touched.
