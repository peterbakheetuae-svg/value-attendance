# Migration 094 and the restricted runtime role — deployment record

**2026-11-26 (owner-authorised):**
* Backup / recovery point: Neon point-in-time restore of the production branch (history retention 6 h), recorded
  before any change at 2026-11-26T13:53:02Z, LSN 0/2A9E5F0 (117 tables, 869 rows, fingerprint e6c908e3…). No snapshot
  or branch was created (none needed: owner's instruction). The app-level encrypted Drive export is not visible here.
* Role `valunivo_app` created in Neon and given exactly `db/roles/valunivo_app_least_privilege.sql`; verified: not
  superuser / createrole / createdb / bypassrls, no group membership, no CREATE on `public`, no TRUNCATE / TRIGGER /
  REFERENCES on any of the 117 tables, DELETE only on the script's 27 tables, no UPDATE on `audit_log`, default
  privileges for new tables = SELECT / INSERT / UPDATE (so 094's tables get no DELETE).
* Vercel production: `MIGRATION_DATABASE_URL` = owner (build-time migrations only); `DATABASE_URL` = `valunivo_app`.
* 094 is applied by the production deploy of `main` that adds `db/migrations/094_shift_attendance_policies.sql`.

## A. Migration 094 (schema only; every new setting stays OFF / empty)
1. **Recovery point.** Create a Neon branch from production named `pre-094-<date>` and note its id. Confirm the daily
   backup workflow ran green today.
2. **Rehearsal.** Create a throwaway branch from production; run `db/proposed/094_shift_attendance_policies.sql` twice
   (the second run must change nothing). Check: 4 new `company_settings` columns with `NULL / NULL / '[]' / false`;
   tables `unauthorized_exit_incidents`, `notification_preferences`; trigger `unauthorized_exit_incidents_guard`;
   indexes `unauthorized_exit_one_open`, `unauthorized_exit_period`. Run the rollback there once (no amounts yet → it
   must succeed) and re-apply.
3. **Promotion (code change, reviewed).** Move the file to `db/migrations/094_shift_attendance_policies.sql` in a commit
   on `main` (the rollback stays in `db/proposed`). Note: 093 is still proposed; the runner applies files in name order
   and skips recorded ones, so 094 before 093 is allowed — confirm 093's own decision separately.
4. **Apply.** Either the production deploy of that commit (`migrate-if-production.mjs`: Vercel production build of
   `main` only) or, once the runtime role is restricted, the manual `db-migrate.yml` workflow (environment
   `production-db`, required reviewer). It is recorded in `schema_migrations` as `094_shift_attendance_policies.sql`.
5. **Verify.** `SELECT name FROM schema_migrations WHERE name LIKE '094%'` = 1 row; the step-2 checks on production;
   `GET /settings` shows the four fields with their defaults; `GET /me/notification-preferences` → `installed: true`;
   `GET /attendance/exit-incidents` → `installed: true`, no rows. No setting is changed by the migration.
6. **Rollback conditions.** `db/proposed/094_rollback.sql` (as the owner) — allowed only while no incident has an
   amount; it refuses (raises, changes nothing) once one does (verified 2026-11-26 on the throwaway branch). After a
   rollback, remove the `schema_migrations` row only if the file is also taken out of `db/migrations`, or it re-applies.
   If financial incidents exist, do not roll back: switch `unauthorized_exit_deduction` off instead.

## B. Restricted runtime role (`valunivo_app`)
1. In Neon, create role `valunivo_app` (owner generates the password in the Neon console; never in chat or the repo).
2. As the owner, run `db/roles/valunivo_app_least_privilege.sql` (after 094, so the new tables get SELECT/INSERT/UPDATE
   and **no** DELETE). The script mentions `db/checks/role_audit.sql`, which is not in the repository — verify instead:
   `SELECT has_table_privilege('valunivo_app','unauthorized_exit_incidents','DELETE')` = false,
   `…'TRUNCATE'` = false, `…'TRIGGER'` = false, `has_schema_privilege('valunivo_app','public','CREATE')` = false.
3. Point a **preview** deployment at a branch database with the restricted URL and smoke-test: login, check-in,
   tracking config, a request, a payroll view. (CI already runs the full suite with these grants: `TEST_APP_ROLE=1`.)
4. Owner switches the Vercel production `DATABASE_URL` to the restricted role and keeps the owner URL only as
   `MIGRATION_DATABASE_URL` in the `production-db` environment (migrations then run only through `db-migrate.yml`).
   Note: with the restricted role the owner-only data reset (TRUNCATE) is refused — by design.
5. **Rollback:** restore the previous `DATABASE_URL` in Vercel and redeploy (no data change).
