# VALUNIVO — Credential rotation record (sanitized; no secret values anywhere in this file)

Started 2026-11-22 under the owner's rotation authorization. Branch `cloudflare/worker-migration` @ `fc15c67` (code baseline).

## 0. Result in one line

**0 credentials rotated in this session.** All 19 genuine secrets were inventoried and classified. None could be rotated
safely with the access available here, for the reasons in §2. Nothing is reported as rotated that was only prepared.

## 1. What this session could and could not reach (verified, 2026-11-22)

| System | Access here | Evidence |
|---|---|---|
| Vercel (both projects) | Names, comments and dates of env vars only; values are type `sensitive` (write-only, unreadable) | `filter_project_envs` on `value-attendance` (8 vars) and `value-attendance-api` (4 vars) |
| Vercel redeploy | Not allowed by the brief (no production deployment); Vercel env changes only reach running functions after a redeploy | — |
| Neon | No connection, no console | — |
| GitHub Actions secrets / variables / environments | Refused by the session proxy (HTTP 403) | `gh api …/actions/secrets` → 403 |
| Cloudflare (account, Workers, tokens) | No credential in this session | — |
| Firebase / Google Cloud, Brevo, Meta, Google Apps Script, Hostinger | No access | — |
| Netlify | Site metadata; env values would be returned in clear text, so they were **not** read | `get-projects`: `value-attendance-api`, current deploy `6aebd5b7…` ready |
| Git history (all 446 commits, every branch, tag and PR ref of the public repo) | Full | masked scan, §3 |

## 2. Why nothing was rotated here

- Every API secret is read by the Vercel functions. A new value only takes effect after a **Vercel redeploy**, which is a
  production deployment the brief forbids. Writing a new value into Vercel without the redeploy would sit unused, then go
  live at the next unrelated deploy while its counterparts (Apps Script, Neon, Firebase, Brevo) still hold the old one — an
  outage, not a rotation. So no value was staged.
- Creating the replacement needs the provider's own console in every case (Neon, Google Cloud, Brevo, Meta, Cloudflare,
  Hostinger, Apps Script, GitHub secrets), none of which this session can reach.
- Generating a value here and typing it into a dashboard tool would place the secret in this conversation's record.

## 3. Repository and history exposure (masked scan, all refs)

| Finding | Where | Severity | Status / containment |
|---|---|---|---|
| Android release keystore `app/signing/release.p12` | added `650b153` (2026-11-05), removed `3b5bc21` (2026-11-09); repo is **public** | Medium: the file stays downloadable from history; it signed public APKs v1.0.44/45. Its password was never committed (scan of every `storePassword` line). | Signing moved to a new key 2026-11-09 (GitHub secrets only). **Exposure open** for phones still on v1.0.44/45 (§5.3). History rewrite not authorized. |
| Firebase web API key | `.github/workflows/app.yml` (several commits) | None: a public client identifier (shipped in every web/APK build) | Not a secret; recommended: API-key restrictions (HTTP referrer + Android package) in Google Cloud |
| `BACKUP_TOKEN` / `BACKUP_ENCRYPTION_KEY` / `SECRETS_KEY` assignments | `api/test/*.test.ts` | None: synthetic test values (`'b'.repeat(32)`, fixed test buffers) | — |
| Postgres URLs with password, private-key blocks, service-account JSON, Brevo / GitHub / Netlify / Meta / Cloudflare token shapes, `.env` files | — | — | **0 found** in 446 commits |

Not reachable here (so not cleared): GitHub Actions logs of every past run (GitHub masks registered secrets in them),
Vercel / Netlify build logs, and anything shared outside the repository.

## 4. Inventory — genuine secrets (19)

Exposure: **E** = held by the still-public legacy Netlify API (treated as exposed), **H** = in public git history,
**N** = no sign of exposure found. Rotation status for every row: **not rotated** (§2).

| # | Credential | Type | Used by | Exp. | Overlap supported | Rotation dependency / note |
|---|---|---|---|---|---|---|
| 1 | Neon `neondb_owner` password (`DATABASE_URL`, future `MIGRATION_DATABASE_URL`) | DB password | Vercel `value-attendance` + `value-attendance-api`, Netlify | E | Yes, via a second role | Create `valunivo_app` (least privilege) → its URL on both Vercel → redeploy → `/readyz` + one sign-in → reset `neondb_owner` (also cuts Netlify off) |
| 2 | `FCM_SERVICE_ACCOUNT` | Google service-account private key | both Vercel, Netlify | E | Yes (several keys per account) | New key → both Vercel → redeploy → one test push → delete old key in Google Cloud |
| 3 | Web-push VAPID private key | derived from #2 (no own variable) | both Vercel | E (derivable from #2) | No | Set `VAPID_PRIVATE_KEY` (new) **in the same deploy as #2**; browsers re-subscribe by themselves |
| 4 | `BREVO_API_KEY` | API key | both Vercel, Netlify | E | Yes (several keys) | New key → both Vercel → redeploy → "forgot password" mail arrives → delete old key |
| 5 | `BACKUP_TOKEN` | shared bearer token | Vercel `value-attendance`, Apps Script property, Netlify (inactive there: < 24 chars) | E | No (single value) | Vercel + Apps Script property changed together → redeploy → run `backupNow` once |
| 6 | `BACKUP_ENCRYPTION_KEY` | AES-256 key | Vercel `value-attendance`; decrypts every Drive backup | N | No | Not exposed → **keep**. If ever rotated, keep the old key offline: old backups need it |
| 7 | `SECRETS_KEY` | AES-256 key (Meta tokens at rest, media-link signing) | Vercel `value-attendance` | N | No (code has one key) | Not exposed → **keep**. Rotating needs dual-key code + re-encrypting DB rows (a release + data migration) |
| 8 | `META_APP_SECRETS` | webhook HMAC secret(s) | Vercel `value-attendance` | N | Yes (comma list) | Optional: add new → redeploy → reset in Meta → remove old |
| 9 | Meta page access tokens | OAuth tokens in DB (`integrations`, sealed by #7) | API | N | Yes | Optional: reconnect the integration in the app |
| 10 | `company_settings.media_secret` | DB value (signs media links with #7) | API | N (redacted from backups) | — | Keep; changing it is a data change |
| 11 | `VA_GATEWAY_SECRET` (`_PREVIOUS`) | HMAC (Cloudflare gateway → Vercel) | staging Worker only; production not set yet | N | Yes (`_PREVIOUS`) | Production value is created fresh at the gateway cutover (FINAL_USER_ACTIONS #8) |
| 12 | `CLOUDFLARE_API_TOKEN` | API token | GitHub secret (staging workflow) | N | Yes | Optional: roll in Cloudflare → update GitHub secret |
| 13 | `CLOUDFLARE_ANALYTICS_TOKEN` | API token (read) | GitHub secret | N | Yes | Optional, same way |
| 14 | `HOSTINGER_SSH_KEY` | SSH private key | GitHub secret (web deploy) | N | Yes (several keys) | Optional: add new key in Hostinger → GitHub secret → next deploy → remove old |
| 15 | `HOSTINGER_SSH_PASSWORD` | password | GitHub secret | N | No | Optional; prefer key-only login |
| 16 | `ANDROID_KEYSTORE_B64` + `ANDROID_KEY_PASS` | APK signing key | GitHub secrets | N (current key) | **No** — a new key breaks updates of installed apps | **Do not rotate** unless compromised |
| 17 | Old Android keystore (2026-11-05) | app-signing key (side-loaded, no Play) | signed public v1.0.44/45 | H | — | Replaced 2026-11-09, but still trusted by any phone on v1.0.44/45 (§5.3) |
| 18 | `WINDOWS_CERT_PFX_B64` + `WINDOWS_CERT_PASS` | code-signing cert | GitHub secrets | N | — | Do not rotate unless compromised |
| 19 | `WINDOWS_UPDATE_SIGNING_KEY` | update-manifest signing key | GitHub secret; public half in the app (`UPDATE_PUBLIC_KEY`) | N | No — new key needs a new app release first | Do not rotate unless compromised |

Account-level credentials (Vercel / Netlify / Cloudflare / GitHub tokens of the owner's accounts, the Google account
authorizing Apps Script) are outside the repository and were not visible here.

**Public identifiers — not rotated by design:** Firebase web config (API key, app id, project id, sender id),
`CLOUDFLARE_ACCOUNT_ID`, `UPDATE_PUBLIC_KEY`, the VAPID public key, `MAIL_FROM`, `CORS_ORIGINS`, API / mirror URLs.

## 5. Legacy services

### 5.1 Netlify `value-attendance-api` — public access **contained 2026-11-22 20:4xZ** (credentials still valid)

- **Public endpoints:** `https://value-attendance-api.netlify.app/*` and `https://main--value-attendance-api.netlify.app/*`,
  served by production deploy `6aebd5b7…` (commit `bb0f322`, 2026-11-05), one function `api` on `/*` (Node 22, us-east-2).
- **Still building from GitHub:** deploy previews for PR #9 were built today (`6b02d74f…` 11:51Z, `6b02d95f…` 12:00Z, branch
  `release-prep/final-business-model`), each with an `api` function. Previews sit behind Netlify team login
  (non-production protection); production does not.
- **Credential categories it holds** (names only; values not read): Neon `DATABASE_URL` (owner role), `FCM_SERVICE_ACCOUNT`
  (and the VAPID key derived from it), `BREVO_API_KEY`, `BACKUP_TOKEN` (too short to be accepted). Whether the preview
  builds receive them depends on each variable's deploy-context scope, which is not visible here.
- **Dependencies found: none.**
  - No branch tip references the Netlify host in code. The app pointed at it only between 2026-11-04 (`65c770a`) and
    2026-11-05 (`4dfe295`).
  - Every published APK (v1.0.44 … v1.0.150) embeds only the `workers.dev` mirror and `vercel.app` hosts.
  - The Apps Script's minute heartbeat would show about 1,440 calls a day on Netlify if it still pointed there; there were 0.
- **Logs (24 h, the plan's whole retention):** 9 requests, all checks. 7 were from this assistant's own checks
  (`/healthz`, `/readyz`, `/robots.txt`), 2 were headless-browser hits on preview permalinks, refused by team login. No
  `/auth`, `/backup` or data routes, so no sign of misuse **in that window**. Older activity cannot be seen.
- **Containment applied (owner's instruction).** Visitor access now requires Netlify team login for **all** deploys
  (`whichProjectsRequireSSOTeamLogin: all`; it was `non_production`).
  - Verified from outside: `/healthz` and `/readyz` on both public hosts now fail with a client error (they answered 200
    before).
  - Netlify's request records show these requests with **0 function invocations**, so the API code is no longer reached.
  - Revert in one click: set the team login back to "non-production only".
  - **Builds stopped 2026-11-22 ~20:55Z** (Project configuration → Build & deploy → Build status: *Stopped builds*, saved
    via the owner's signed-in dashboard; after reload the page shows `Build status: Stopped`). Team login is still `all`.
    Independent proof comes with the next commit on PR #9 / `main`: no `netlify/value-attendance-api/…` status should appear
    on it (the last one is on `31c1800`, 12:00Z). No test commit was pushed.
  - Still open: the four credentials stay valid until they are rotated; the variables and the project are kept.
- **Next:** "Stop builds" (no rebuild from pushes or PRs) → later
  rotations #1/#2/#4 cut the credentials themselves → delete variables and site last.

### 5.2 Vercel `value-attendance-api`

Holds #1, #2, #4 (4 variables). Update it together with `value-attendance` in every rotation step.

### 5.3 Old Android signing key (row 17) — assessed 2026-11-22, **exposure open**

- **What it is:** the app-signing key itself, not an upload key.
  - The APK is side-loaded: GitHub releases plus `android/latest.json` on Hostinger, read by the in-app updater.
  - No Play pipeline exists in any branch (no AAB, no Play upload step). Play App Signing therefore does not apply;
    confirm in Play Console only if a Play listing exists.
- **Created and committed by CI:** 2026-11-05 17:36:55Z (`650b153`), RSA 4096, valid until 2126, subject
  `C=EG, O=Value Aqar, CN=Value Attendance`. It was in the tree until `3b5bc21` (2026-11-09) and is still downloadable
  from the public history.
- **Public APKs it signed** (signer certificate read from the APKs, public part only; notBefore = the commit time):
  v1.0.44 (1 download) and v1.0.45 (4 downloads), both 2026-11-09.
- **From v1.0.54 (2026-11-09 20:17Z) on,** a different key signs (RSA 2048, `CN=Value Attendance`).
  - The v2 block carries no proof-of-rotation lineage.
  - Phones still on v1.0.44/45 cannot take the new builds as an update; they need uninstall and reinstall.
- **Protection left:** only the strength of the password the file was created with (held only in the GitHub secret, never
  committed). Changing a password later does not affect copies already downloaded.
- **Real risk:** anyone who cracks that password can sign an APK that Android accepts as an update over v1.0.44/45 installs.
  - It cannot update installs signed with the current key.
  - The current key (`ANDROID_KEYSTORE_B64`) has not been checked here to be unrelated to the old password.
- **No key reset exists for side-loaded apps.** Recovery means:
  - finding and reinstalling any phone still on v1.0.44/45;
  - never trusting the old certificate's SHA-256 (prefix `9a476d92e0de75ee`) again;
  - making sure no copy of v1.0.44/45 stays offered on Hostinger;
  - checking that the current keystore's password differs from the old one.
  - If the app is ever published on Play: enrol with Play App Signing and a fresh upload key.

## 6. Rotation order (each step: new → consumers → redeploy → verify → only then revoke)

1. Netlify containment (no rotation, no app deploy).
2. Database (#1).
3. Brevo (#4).
4. VAPID + Firebase together (#3, #2).
5. Backup token (#5), Vercel and Apps Script at the same moment.
6. Optional, not exposed: #8, #12–#15.
7. Netlify variables / site deleted.

Each redeploy is a production deployment and needs the owner's go-ahead; I verify each step read-only afterwards
(`/readyz`, env update dates, one sign-in / mail / push / backup run, Vercel runtime errors for auth failures).

## 6A. Database step (#1) — prerequisites established 2026-11-22 (nothing changed yet)

**Blocker: production runs `main` (`cbd00b3`), whose Vercel build runs migrations with `DATABASE_URL`.**
- Both projects' `buildCommand` starts with `migrate-if-production.mjs`, which runs `npm run migrate` on every production
  build of `main`.
- On `main`, `migrate-core` always issues `CREATE TABLE IF NOT EXISTS schema_migrations`, and `migrate.ts` reads only
  `DATABASE_URL`.
- Tested on scratch Postgres 16: a role without CREATE on `public` gets `permission denied for schema public` even though
  the table exists.
- So with `DATABASE_URL` = `valunivo_app` and `main` code, the redeploy **fails at build**. The live deployment keeps the old
  credential, so there is no outage, but the switch cannot be activated.

**On this branch / the release code this is solved, and the switch works.**
- `migrate-core` only creates the table when it is missing.
- `migrate.ts` prefers `MIGRATION_DATABASE_URL`.
- The full API suite passes as the least-privilege role (398/398).
- Pending migrations (086/087) must then run through `db-migrate.yml` with the owner URL (FINAL_USER_ACTIONS #4), never
  from a Vercel build.

**Order that never stops the app or the backup:**
1. Release first (FINAL_USER_ACTIONS #8), so production runs code that works without CREATE. Apply 086/087 with the owner
   credential through `db-migrate.yml`.
2. Neon console → Roles → create `valunivo_app` (Neon generates the password; copy it straight into step 4).
3. Neon SQL editor, as `neondb_owner`: run `db/roles/valunivo_app_least_privilege.sql`. It gives:
   - no CREATE, no TRUNCATE, no REFERENCES / TRIGGER;
   - SELECT / INSERT / UPDATE everywhere;
   - DELETE only on the 19 tables the code deletes from, plus `expense_group_categories` once 086 exists;
   - `audit_log` append-only;
   - default privileges for future tables.
   Then run `db/checks/role_audit.sql`.
4. Vercel → both projects → `DATABASE_URL` = the pooled `valunivo_app` URL (typed in Vercel only).
5. Redeploy both (owner's go-ahead), then verify:
   - `/readyz` ok;
   - sign-in, check-in / out, a receipt and an expense on test data or a reversible real entry;
   - payroll / insights read, one push, "forgot password" mail;
   - `backupNow` run (the backup reads only through the API);
   - the Meta webhook;
   - Vercel runtime errors: no `permission denied`.
6. Prove nothing else uses the owner: in the Neon SQL editor, group `pg_stat_activity` by `usename, application_name,
   client_addr` over a day. Expect no `neondb_owner` sessions except your own console.
7. Only then reset the `neondb_owner` password in Neon. Put the new owner URL only in GitHub environment `production-db`
   (`MIGRATION_DATABASE_URL`). This also ends Netlify's database access.

**Known consumers of the owner credential:**
- Vercel `value-attendance` and `value-attendance-api` (`DATABASE_URL`; which role each holds cannot be read: the values
  are write-only);
- Netlify (`DATABASE_URL`, now behind team login);
- the planned GitHub `MIGRATION_DATABASE_URL`;
- the owner's own Neon console.
- The Apps Script backup never touches the database directly.

## 6B. Brevo (#4) — in progress (checkpoint 2026-11-23 07:03Z)

| Field | Status |
|---|---|
| Replacement created | **Yes**, 2026-11-22: key `valunivo-2026-11` in the owner's Brevo account; **Restricted, 1 scope (Transactional email)**; expires 2027-11-22 or after 90 days unused |
| Environments updated | **Yes**, both Vercel projects, Production `BREVO_API_KEY`: `value-attendance` updated 2026-11-22 21:03:06Z, `value-attendance-api` 2026-11-23 07:01:55Z (update dates only; values never read) |
| Deployment | **Yes**, both redeployed from the live `main` @ `cbd00b3` deployments, no other change: `dpl_8wSdcUdzywS6naqf1xTre62ByPSS` (value-attendance, READY, aliases `valunivo.vercel.app`, `value-attendance.vercel.app`); `dpl_C4HdmomNggEKXVx7ZqeA9sTK5396` (value-attendance-api, READY, `value-attendance-api-eight.vercel.app`) |
| `/readyz` | value-attendance `{"ok":true,"migrations":73,"push":true,"mail":true,"backup":true}`; value-attendance-api `…"mail":true,"backup":false}` (that project never had `BACKUP_TOKEN`; it is not used by the apps) |
| Email test | **FAILED** (2026-11-23). See the diagnosis below. Production email is **not delivered** since the redeploy of 06:57Z. |
| Old key revoked | **No.** It is **not** in the signed-in Brevo account: that account held no API keys and sent no transactional email in the previous 7 days. Either another Brevo account issued it, or it was already deleted. To be settled before this row can close. |
| Remaining consumers of the old key | Netlify (`BREVO_API_KEY`, site locked and builds stopped) |

**Diagnosis of the failed email (2026-11-23, from actual records; no further send was made).**
- **What reached Brevo.** Three "forgot password" requests, triggered by the owner, reached the live deployment
  `dpl_8wSdcUdzywS6naqf1xTre62ByPSS` and were accepted by the new key. The new key's Brevo account logs each one as
  **Sent**, then **Error**: 09:05, 09:06 and 09:07 Cairo, recipient = the owner's own address, From =
  `info@valueaqar.com`.
  - So the new key is active at runtime.
  - Brevo's API answered 2xx, which is why the API logged no `mail_failed` (Vercel runtime logs, last 55 min, none) and the
    app treated each code as sent.
- **Cause: account mismatch on the sender.** The account holding the new key has one verified sender (a personal
  address) and **no authenticated domain**. `info@valueaqar.com` (MAIL_FROM) is neither, so Brevo drops each message
  after accepting it.
  - The old key evidently belongs to a **different Brevo account**, where `info@valueaqar.com` / `valueaqar.com` is set up.
  - That matches this account having had no keys and no sends before.
- **Limits of the evidence.**
  - Vercel per-request records (path / status) are not available on this plan through the tools (observability query →
    402).
  - Brevo shows no error text in the log list. The message preview was not opened, because it contains the code.
- **Fix (owner's choice; nothing changed yet):**
  1. **Recommended:** generate the replacement key in the Brevo account that owns `valueaqar.com`. Put it in both Vercel
     projects and redeploy. Test once. Then delete the old key **and** `valunivo-2026-11` in the personal account.
  2. Or verify `info@valueaqar.com` / authenticate `valueaqar.com` in the personal account. This needs the mailbox or
     DNS records.
  3. Not recommended: change MAIL_FROM to the personal address (Brevo warns: free-mail sender, DMARC).
  - **To restore email right now without a new key:** use Vercel Instant Rollback of `value-attendance` to
    `dpl_4trXqNhosA7wWEz9E7wFbUYy1KnU` (same `cbd00b3`, old key still valid). This is a production action; owner's
    decision.

## 6C. Temporary Gmail SMTP transport (replaces Brevo for delivery) — implemented, **not activated**

**Why.** Brevo test failed (§6B). The Brevo account the owner controls has no authenticated sending domain. Until the
company buys and authenticates its own domain, email goes through a dedicated Gmail account. Gmail is a low-volume
provider (a few hundred messages a day at most, throttling), **not** a permanent transactional-email service.

**Code.**
- Commit `d457faf` on local branch `hotfix/gmail-smtp`, cut from the production baseline `main` @ `cbd00b3` (not pushed).
- The same change is cherry-picked as `992e5ed` on `cloudflare/worker-migration`.
- PR #9 does not have it yet; `mail.ts` is identical on `main`, this branch and PR #9.
- Contents:
  - `api/src/lib/mail.ts`:
    - SMTP is used when `SMTP_HOST`, `SMTP_USER` and `SMTP_PASS` are all set; otherwise the Brevo path is unchanged.
    - Default port 465 with implicit TLS; on any other port STARTTLS is required.
    - Timeouts 8 / 8 / 10 s, no pool, one attempt, no retries.
    - Sender is `SMTP_FROM`, else the Gmail account.
  - Errors are stored without the password, the account or any address. Success logs only the SMTP reply code (provider
    acceptance, not inbox delivery).
  - Dependency `nodemailer ^10.6.1`, bundled by the existing esbuild build; `npm audit`: 0 vulnerabilities.
- Unchanged: email texts, OTP logic and expiry, limits, password-reset rules, API, UI, permissions.
- All four flows call the same `sendMail`: forgot-password code, payout / action code, HR password reset, email-change /
  marketing-company code.

**Tests (no real email; a local SMTP server).** `api/test/mail-smtp.test.ts`, 9 tests:
- config / precedence;
- App Password auth;
- sender;
- Arabic content;
- refused authentication (1 connection, no secret in error or log);
- refused recipient;
- unreachable server;
- Brevo unchanged;
- forgot-password end to end (the emailed code verifies; a refused send is audited without secrets);
- HR reset.

Full suites:
- `hotfix/gmail-smtp`: 371 / 371.
- `cloudflare/worker-migration`: 408 tests, 406 pass, 2 skipped, 0 fail; least-privilege run 407 / 407.

**Configuration for activation** (Production, both `value-attendance` and `value-attendance-api`; nothing removed):

| Variable | Value | Who enters it |
|---|---|---|
| `SMTP_HOST` | `smtp.gmail.com` | Claude or owner |
| `SMTP_PORT` | `465` | Claude or owner |
| `SMTP_SECURE` | `true` | Claude or owner |
| `SMTP_USER` | the dedicated Gmail address | owner |
| `SMTP_PASS` | Google **App Password** (2-Step Verification on; never the account password) | **owner only, Sensitive** |
| `MAIL_FROM`, `MAIL_FROM_NAME`, `BREVO_API_KEY` | unchanged (Brevo stays configured, unused while SMTP is set) | — |

**Activation plan (needs the owner's explicit approval).**
1. Push `hotfix/gmail-smtp`. Vercel may build a preview of it: a preview has no production variables and never
   migrates.
2. Production deployment of that branch, sequentially, `value-attendance` then `value-attendance-api`.
   - The build skips migrations for a non-`main` ref, so nothing changes in the database.
3. `/readyz` (`mail:true`).
4. One controlled forgot-password test.
   - Vercel log `mail_accepted transport=smtp reply=250 …`.
   - Owner confirms inbox arrival.
5. Merge `hotfix/gmail-smtp` into `main` (separate approval). Otherwise the next `main` deploy drops SMTP again.

**Rollback.**
- Vercel Instant Rollback of `value-attendance` to `dpl_4trXqNhosA7wWEz9E7wFbUYy1KnU` (and `value-attendance-api` to
  `dpl_BtQAq2pxMzH6WdjdDzXQXLqs7dae`): the `cbd00b3` builds with the **old** Brevo key, which still delivers.
- Removing `SMTP_PASS` alone falls back to the current Brevo key, which does not deliver (§6B).

**Checkpoint 2026-11-23 07:40Z.** `SMTP_USER` and `SMTP_PASS` added by the owner as Secret, Production only, in both
projects: `value-attendance` 07:39:37Z, `value-attendance-api` 07:40:07Z. Values were never read. They are inert until
`SMTP_HOST` is set **and** the SMTP code is deployed.

**Status.** Not deployed. Brevo old key not revoked. Production email still not delivered on the current deployment
(§6B); the immediate fix without new code is the Instant Rollback above.

## 7. Log

| Date | Item | Action | Evidence |
|---|---|---|---|
| 2026-11-22 | all | Inventory + masked history scan; no rotation possible here (§2) | §1, §3 |
| 2026-11-22 | Netlify | Investigated (§5.1); team login required on all deploys (owner's instruction) — public API blocked, credentials not yet rotated | site setting `all`; /healthz, /readyz client error; 0 function invocations |
| 2026-11-22 | Netlify | Stage A: builds stopped (dashboard, reload shows "Stopped"); team login still `all` | dashboard + `get-project` |
| 2026-11-22 | #17 | Signer certificates of v1.0.44/45/54/150 compared (§5.3) — **exposure open** | public certificate fingerprints |
| 2026-11-09 | #17 | Old Android keystore replaced (by an earlier session, commit `3b5bc21`) | commit message + key now only in GitHub secrets |
