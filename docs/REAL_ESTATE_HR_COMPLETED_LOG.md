# Completion log

## 2026-11-03/04 — Session 1

**Environment.** Cloud workspace: Node 22.23, TypeScript 7 (tsgo), PostgreSQL 16.15 (real server, not PGlite).
No npm registry, no Flutter/Dart SDK (storage.googleapis.com, pub.dev, Docker registries blocked).
`pg` client files were copied read-only from the original project's `node_modules`; `package.json` declares `pg` so `npm install` works normally on the PC.

**Phase 0.** Original project read only (theme, widgets, login, dashboard, assets). Reference B is login-gated; its
workflows were mapped from the UI strings in its JS bundle.

**Backend.** 80 routes across 11 modules. Decisions worth remembering:
- Single company → no tenant columns; `company_settings` is a one-row table (`CHECK (id)`).
- Salary lives in `employee_salaries`, never joined into a profile query; history/audit redact salary values for readers without `employee.salary_read`.
- Team scope = members of teams the manager runs **plus** anyone naming them as `sales_manager_id`.
- Out-of-scope reads return **404**, not 403, so ids cannot be probed.
- Requests snapshot `manager_id` at submission; only that manager can act at the manager stage. DB trigger forbids any transition except pending_manager→pending_hr→approved, →rejected, →cancelled; terminal states are frozen.
- Attendance stores a **schedule snapshot** per day, so later schedule edits never rewrite history. `original_check_in_at/out` are write-once (trigger); rows cannot be deleted.
- KPI sets are **versioned**; a set with results is frozen (trigger). Results snapshot weight/target. `CHECK ((state='not_evaluated') = (actual IS NULL))` keeps missing ≠ zero. Weighted score caps each KPI at 100 % achievement.
- Evaluations: published rows are immutable (trigger), all 8 dimensions required to publish.
- Finance adjustments: creator ≠ approver ≠ subject (CHECK constraints + API).
- `.xlsx` written by a 120-line dependency-free writer (zip + deflate + crc32), RTL sheets.

**Bugs found by tests and fixed**
1. Failed-login counter: `inconsistent types deduced for parameter $2` (int vs comparison) → explicit casts.
2. Attendance board: `SELECT e.id AS employee_id, …, at.*` — `at.*` overwrote `employee_id` with NULL for people who had not checked in → column order swapped.

**Verification:** `npm run typecheck` 0 errors · `npm test` **49/49** (≈7 s) · migrate on empty DB · seed refuses non-empty DB.

**Flutter app** written (19 files, design system copied, AR/EN 479 keys with parity test). **Not compiled yet** — see task board T14.2.
