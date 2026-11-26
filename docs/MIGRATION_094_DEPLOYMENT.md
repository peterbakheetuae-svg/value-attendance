# Migration 094 and the restricted runtime role — deployment procedure (PREPARED, NOT EXECUTED)

Status at writing (2026-11-26): production has 84 migrations, no 094 objects; it connects as the table owner
(`neondb_owner`), which can disable triggers — so the incident protections are database-enforced only once the API runs
as the restricted role. Each part below needs the owner's explicit approval; nothing here runs on its own.

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
