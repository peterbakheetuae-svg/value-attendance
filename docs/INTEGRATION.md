# Integration — permissions + Windows (local branch `integration/final`)

Built locally only. Nothing pushed, merged into `main`, deployed, or run against Neon.

## Source commits (pinned by hash)
| Source | Commit | Status |
|---|---|---|
| Production web (live at jaurea.com/valunivo) | `0f0709cc90…` (run #119, `feature/tracking-controls`) | verified: live `flutter_bootstrap.js` = that run's build |
| Production Android 1.0.118 | `0c8851eae3…` (run #118) | ancestor of `0f0709c` |
| `main` | `ae83622989…` | 6 commits **behind** production (tracking controls, Vercel migrate guard, web deploy) |
| Permissions | `86cc97bc7f10370c743d73379d54e86b9ad058d6` | **provisional** — the Permissions Agent has not confirmed a final hash |
| Windows-only | `529d34da893626e5e01cd9ab71170c790e4cf04e` | final (Windows agent) |
| Security baseline `f7a280b` + recovery bundle | — | **not found** on GitHub, in this workspace or in the shared folders of the user's PC |

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
**Numbering is unresolved**: no migration ≥ 066 exists in any branch's history; "071" can only come from the database.
Read-only check for the database owner (Neon SQL editor, read-only):
```sql
SELECT name FROM schema_migrations ORDER BY name DESC LIMIT 10;
SELECT key FROM permissions WHERE key IN ('data.reset','attendance.view_location','employee.create','cash.approve') ORDER BY key;
```
If the newest applied name is `065_unit_files.sql` and none of those keys exists, `066_…` can go into `db/migrations/` as is.
If anything ≥ 066 is applied, its content must be known before 066 is renumbered (e.g. to 071).

## Not verifiable here
- Windows build / installer / update on this exact commit: Windows needs GitHub's Windows runners (push not authorized).
  The Windows code is byte-identical to `8185fdb`, whose Windows CI run (43838718730) passed build, installer and all six
  update scenarios.
- Live login / device approval with a real account (no credentials, no test accounts).
