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

**Dependency order: 066 → 083 → 084 → 085 → 086 → 087** (each file in one transaction, as the runner applies it; by hand `psql -1`).
Each is additive and is exercised **forward-only** by the test suite on throw-away databases (install, second run, existing
records untouched). Rollback scripts exist but are **never executed** — not by tests, not in release validation; their
scope is checked as text only (`api/test/migration-rollback-static.test.ts`: each may remove only what its own migration
adds; no TRUNCATE, no DELETE without WHERE; and no test file may name a rollback script). If the 2026-11-18
clean-up is ever approved, it goes **before 085 / 086** (see below).

* Chain check (throw-away scratch PostgreSQL 16, forward-only): the 73 official migrations on an empty database, then
  066 → 083 → 084 → 085 → 086 each apply cleanly. **066, 085, 086 are safe to re-run; 083 and 084 are
  NOT** (a second run stops at «already exists» — harmless, each runs in one transaction, but apply them only once:
  check `schema_migrations` / the object first).
* **085** refuses to install (and names them) if any request already has two live payouts. The month from which
  today's `company_owners` shares are in force is a **business fact the owner states** — no record proves it (the first
  receipt or payout says when money was first recorded, not when a share began), so 085 neither invents one (the old
  fixed 2000-01) nor infers one. It is stated when 085 is applied, in the same session:
  `psql -1 -v ON_ERROR_STOP=1 -c "SET valunivo.owner_share_baseline = 'YYYY-MM-01'" -f db/proposed/085_financial_integrity.sql`.
  Without it 085 refuses and changes nothing whenever there are shares to copy; a date that is not a month start, is in
  the future or is not a date is refused. The stated month goes into the audit log (`owners.share_baseline`); a WARNING
  says if money is recorded before it (those months carry no owner share). With no owners yet (after the pre-launch
  clean-up) or on a re-run, nothing is copied and nothing is asked. Tested in `api/test/085-baseline.test.ts`.
* **086** adds three tables and two nullable columns on `cash_expenses` / `fixed_expenses`. No back-fill.
* ⚠ **If the 2026-11-18 clean-up script (`db/ops/2026-11-18-keep-active-employees.sql`) is still planned, run it before 085 / 086**:
  after them, the new tables reference employees, and deleting a former employee / company owner they point to is refused.

`db/ops/2026-11-22-detect-duplicate-settlements.sql`: READ ONLY (ends with ROLLBACK) — candidates of past double payments /
collections. Approved for Neon on 2026-11-22 but **not run**: this session has no authorized connection to Neon
(Vercel's `DATABASE_URL` is a write-only sensitive variable; the Hostinger server has no database access; the Neon
connector is not connected). Production `/readyz` reports 73 applied migrations = `db/migrations` only, so 066 / 083 / 084
are not applied there yet — 085 / 086 stay unapplied until 083 / 084 are, the inspection has run, and the 2026-11-18
clean-up question is settled.

## Resale and rental (087 — proposed)

`db/proposed/087_brokerage_deals.sql`, API `api/src/modules/brokerage.ts`, app «التسويق» → إعادة بيع / إيجار
(`app/lib/jph/pages/projects/brokerage_page.dart`). Until 087 runs the API answers `installed:false` and the pages say so;
nothing else changes.

* The sales employee registers the deal: property, owner (seller / landlord), client (buyer / tenant), price or monthly rent,
  the property contributor and the closing salesperson (two different roles, may be two people), the sales manager.
* Proposed commission — resale: 1 %–2.5 % of the price, paid by the seller, the buyer or both (each side's amount);
  rental: one month from the owner / from the tenant / half from each / a fixed amount per side. Corrections while it
  waits are audited.
* The general manager (`brokerage.approve`, else `commission.approve`) approves the distribution — contributor, closer,
  sales manager, other beneficiaries, each a percentage or a fixed amount, never above the commission (the office keeps
  the rest). Nobody approves a deal he proposed or takes a share of. The approved agreement and distribution are frozen
  by a database trigger and kept as a snapshot; later edits of employees, roles or rules do not move them.
* Office revenue only when collected: each side's commission is received into a cashbox as a `commission` receipt
  (numbered, idempotent by `clientRef`, never above that side's amount); the rest is a receivable (`/cash/overview` →
  `brokerage.agreed / collected / receivable`). Once all of it is in, every employee share becomes a commission entitlement
  of that month (listed with the other commissions, paid once through «صرف العمولة»). An external beneficiary's share is
  recorded but is not payroll.
* **Reversal of a collected commission receipt** (`POST /cash/receipts/:id/reverse`, same transaction): refused
  (`409 brokerage_shares_paid`, nothing changes) once any share of the deal was paid — an employee commission payout or
  an outside beneficiary's settlement; otherwise a collected deal goes back to `approved` and its employee entitlements
  are cancelled (no payout accepts a cancelled entitlement, payroll counts active ones only). Collecting again
  re-activates the SAME entitlements (never a second one). Audited as `brokerage.reopen`.
* **Outside beneficiaries** (approved shares without an employee): `POST /brokerage/deals/:id/shares/:shareId/settle`
  — office cashbox holders only, only once the commission is all collected, one live settlement per share (unique index;
  idempotent by `clientRef`), recorded as a posted office expense «عمولة وسيط» linked to the share, audited as
  `brokerage.settle_external`. Reversing that expense re-opens the share for settlement. Never treated as paid otherwise.
* Compatibility of 087 with the existing flows: commission receipts keep `kind = 'commission'` (the cash book, profit and
  year-closing guards see them as before); `commission_entitlements.request_id` becomes nullable only with the CHECK that
  exactly one of request / brokerage share is set, and every listing that joined commission requests now LEFT JOINs them
  (`/commissions/entitlements`); payouts keep their rules (one live payout per entitlement, active only, amount from the
  entitlement); reversal of receipts / expenses keeps its rules — 087 only adds the brokerage hook above.
* A deal with nothing collected can be cancelled; collected money is never deleted. Every step is in the audit log.
* Tests: `api/test/brokerage.test.ts`; the treasury figures (cash + bank vs office commission vs owners' trust vs available
  funds; an internal cash ↔ bank move creates no revenue / expense): `api/test/treasury-figures.test.ts`.

### Deployment prerequisites (production database — each needs the owner's separate approval)

The application is safe on a database without any of these (each feature checks and stays off). To turn them on, in order,
each in one transaction, after a Neon backup branch:
1. (if approved) the pre-launch clean-up `db/ops/2026-11-18-keep-active-employees.sql`
2. `066` → `083` → `084`
3. `085` with the stated month: `psql -1 -c "SET valunivo.owner_share_baseline = 'YYYY-MM-01'" -f 085_financial_integrity.sql`
4. `086` (expense groups / categories) → `087` (resale / rental)
None is in `db/migrations`, so no deploy runs them automatically. Rollback scripts are not part of any deployment.

### ⚠ Rollback = data loss for anything created after the migration

The rollback files are for a failed install on a test copy, **not** an undo button on a live database:

* `086_rollback.sql` drops the group / category tables and the two classification columns → every classification made
  after 086 is lost (the expenses and money stay; only their group / category goes).
* `085_rollback.sql` drops `company_owner_shares` and the payout guard → the ownership-share history (every change made
  after 085) is lost and payouts become editable again.
* `066_rollback.sql` removes the fine-grained permissions → per-key grants made after 066 are lost.

They are not executed anywhere as part of this release (tests included). Back up (Neon branch) before any rollback;
never run one against production without the owner's explicit decision.

## clientRef retries are answered only to their sender (release review, 2026-11-22)

Before: a form retry (same `clientRef`) returned the existing receipt / expense to **whoever** presented the reference —
`POST /cash/receipts` answered with the full receipt (payer, phone, amount, number) without checking the caller's
cashbox scope; expenses, owner draws, capital injections, sale and exclusive-unit collections had the same lookup.
Only `cash_receipts` and `cash_expenses` store a `client_ref`; every route that accepts one is in the table below.
Exploitability was low (the reference is a random UUIDv4 the API never returns), but the authorization check was missing.
Now every `client_ref` lookup (`priorByClientRef` in `cash.ts`, used by `sales.ts`; `sameRetry` in `exclusive.ts`)
returns the earlier record only when **the same person** retries **the same operation on the same target**:

| Operation | A retry must match |
| --- | --- |
| `POST /cash/receipts` (and every `recordReceipt` caller) | kind, cashbox, recipient, amount, sale / installment / project (none for a plain receipt), not an exclusive unit |
| `POST /sales/:id/collect` | this sale, this installment line, kind, cashbox, amount |
| `POST /sales/:id/collect-auto` | this sale, cashbox, kind (installment vs reservation / down payment), and the **total** of the whole split (every receipt written by the first send — same sale, recorder, cashbox, transaction time) equal to the amount sent |
| `POST /exclusive/units/:id/receipts` | this unit, kind, and — when the form names them — installment and amount (a form without an amount means «the rest» and has none to compare) |
| `POST /cash/expenses` | cashbox, amount, category, payment method, marketing company, not an owner draw |
| `POST /cash/owner-draws` | the sender's own draw, office box, method, amount |
| `POST /cash/injections` | an injection, the same target box, method, amount |

Anything else — another user, sale, line, unit, kind, cashbox, operation or amount — gets `409 client_ref_reused` and
nothing of the row. Concurrent identical sends are serialised on the reference with a transaction-scoped advisory lock
(no schema change): one record, the others get it back as the duplicate (before: the UNIQUE violation surfaced as 409
to a legitimate retry); exclusive units are serialised by the unit's row lock, and two units racing on one reference end
as one receipt + one 409 (UNIQUE backstop). Response shapes are unchanged; `collect-auto`'s retry now lists **every**
receipt of the first send, in order — the same `receiptIds` the first answer gave (before: the first one only).
Regression tests: `api/test/client-ref-scope.test.ts` and the exclusive cases (other unit / kind / amount / person,
cross-unit race) in `phase6-corrections.test.ts` — run against the previous code they fail (5 at `eb03e12`, the
`collect-auto` total / full-set case at `6752a7d`) and pass on the new.

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
