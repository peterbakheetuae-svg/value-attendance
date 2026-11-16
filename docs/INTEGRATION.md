# Integration — permissions + Windows (`integration/final` → `main`)

Merged into `main` with the owner's authorization (16 Nov 2026). No migration is applied by this merge (see below).

## Source commits (pinned by hash)
| Source | Commit | Status |
|---|---|---|
| Production web (live at jaurea.com/valunivo) | `0f0709cc90…` (run #119, `feature/tracking-controls`) | verified: live `flutter_bootstrap.js` = that run's build |
| Production Android 1.0.118 | `0c8851eae3…` (run #118) | ancestor of `0f0709c` |
| `main` | `ae83622989…` | 6 commits **behind** production (tracking controls, Vercel migrate guard, web deploy) |
| Permissions | `86cc97bc7f10370c743d73379d54e86b9ad058d6` | **provisional** — the Permissions Agent has not confirmed a final hash |
| Windows-only | `529d34da893626e5e01cd9ab71170c790e4cf04e` | final (Windows agent) |
| Security baseline `f7a280b` + recovery bundle | — | **inaccessible**: never pushed to GitHub (full push history since 14 Nov checked), not in this workspace, no git repo visible on the owner's PC. Everything that reached GitHub or production is contained here |
| `feature/dashboard-links` (`7111deb`, 3 commits) | — | **not included**: only ever on the waiting branch (analysis, never built / deployed / approved); tracking-controls was started from `main` without it. Merges cleanly later (checked); branch kept |

Lineage: `main` → +6 → **production `0f0709c`** → +2 (`app.yml` APK republish) → `feature/tracking-controls` → +13 → permissions `86cc97b`.
The permissions branch contains all of production. Windows-only branches from `main`.

## Integration commits (on top of `86cc97b`)
1. `ed29bda` merge Windows-only `529d34d` — no conflicts; `app.yml` = the permissions version (no unified Windows pipeline);
   `session.dart` keeps both the permissions refresh and the Windows DPAPI token store.
2. `bb04bdd` **data.reset strictly owner-only, non-delegable; owner accounts changed only by owners**.
3. `2efb3ec` tests: location privacy after 066, offline punches.
4. `c272e30` **migrations / seed only on an explicit production build of `main`**.
5. `4557d92` tests: proposed migration 066 (effective access, idempotency, exact rollback).
6. `0764591` **web deploy guard for `/valunivo/windows/`** + isolation tests.
7. `373f274` permissions page shows owner-only keys locked.

## Security fixes
- **data.reset**: the import / reset endpoints require an owner account (role `owner`, not settled) regardless of database rows;
  a non-owner never holds the key (filtered when permissions are resolved); granting / revoking it is refused for everyone,
  owners included (a stray row can still be removed). Confirmation phrase, dry-run default and audit log unchanged.
- **Owner-account takeover closed** (found in review): any holder of `employee.edit` could change the owner's email and use
  «نسيت كلمة السر»; any `roles.manage` holder could reset the owner's password, deactivate the owner, or create / promote an
  owner account. Now only an owner can make an owner or change / deactivate / reset / unlink an owner account.
  Other employees are managed exactly as before.
- Location privacy (permissions branch): coordinates leave the API only through `/attendance/range`, `/tracking/live`,
  `/tracking/employee/:id`, each gated by `attendance.view_location`; offline punches use the same columns and gates.

## Migration safety
`api/scripts/migrate-if-production.mjs` is the only automatic path to `migrate` + `seed`:
Vercel `VERCEL_ENV=production` + branch `main` (unchanged rule of `api/vercel.json`); Netlify production + `main`;
anything else only with `VA_ALLOW_MIGRATE=production`. Before: the root `vercel.json` (Vercel project
`value-attendance-api`) and `api/netlify.toml` ran `migrate` on **every** build, previews included. The production API project
(`value-attendance`, root `api/`) already logged "no migrate, no seed" for branch previews.

## Migration 066 (kept in `db/proposed/`, not moved, not renumbered)
Reviewed: 26 keys; SQL / registry / rollback lists identical; every table + column exists; the runner applies a file in one
transaction (the `ON COMMIT DROP` temp tables are safe). Tested on a throw-away database: effective permissions of every
account identical before / after, second run changes nothing, rollback restores the exact rows (audit rows stay).
**Neon state (from Vercel's production build log, `main` @ `ae83622`, deployment `dpl_62AARyJ9qo95FsiTB31uu6pkw5uV`)**:
`database: neondb` · `applied: 065_unit_files.sql` · `seed skipped: "neondb" already has 9 employees`. Since then production
was only built from `feature/tracking-controls` (migrations never run there) and no branch has a migration ≥ 066 — so
`066` is free. `db/migrations/` in this integration is identical to `main`: merging applies **no** migration (the runner on
the production build finds nothing pending). 066 stays in `db/proposed/` until the owner approves running it; the API
behaves exactly as before 066 until then (fine keys fall back to the broad ones / the owner).
Optional read-only cross-check (Neon SQL editor):
```sql
SELECT name FROM schema_migrations ORDER BY name DESC LIMIT 10;
SELECT key FROM permissions WHERE key IN ('data.reset','attendance.view_location','employee.create','cash.approve') ORDER BY key;
```
If the newest applied name is `065_unit_files.sql` and none of those keys exists, `066_…` can go into `db/migrations/` as is.
If anything ≥ 066 is applied, its content must be known before 066 is renumbered (e.g. to 071).

## Not verifiable here
- Production-signed APK of this exact commit: only `main` builds an APK in CI, and a manual run there publishes it to phones.
  Instead: signing code identical to the release that built the live 1.0.118 (`CN=Value Attendance`), and the release path
  rehearsed on this code with a throw-away key (release-signed, v2).
- Live login / device approval with a real account (no credentials, no test accounts).
