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

### 5.1 Netlify `value-attendance-api` — investigated 2026-11-22, **NOT contained**

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
- **Containment prepared, NOT applied.** Extending Netlify's team-login protection from previews to all deploys (Project
  configuration → Access & security → Visitor access → team login for **all** deploys) was attempted from this session
  and refused by the session's permission guard. It is reversible in one click: set it back to "non-production only".
- **Recommended order:** that setting first (instant, reversible) → "Stop builds" (no rebuild from pushes or PRs) → later
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

## 7. Log

| Date | Item | Action | Evidence |
|---|---|---|---|
| 2026-11-22 | all | Inventory + masked history scan; no rotation possible here (§2) | §1, §3 |
| 2026-11-22 | Netlify | Investigated (§5.1); containment setting attempted, refused by the session permission guard — **not contained** | Netlify deploy + 24 h request records |
| 2026-11-22 | #17 | Signer certificates of v1.0.44/45/54/150 compared (§5.3) — **exposure open** | public certificate fingerprints |
| 2026-11-09 | #17 | Old Android keystore replaced (by an earlier session, commit `3b5bc21`) | commit message + key now only in GitHub secrets |
