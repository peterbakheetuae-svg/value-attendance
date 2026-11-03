# Value Attendance — deployment ($0/month target)

Status: **NOT DEPLOYED.** Every step below that needs an account is blocked on the owner (see "What I need from you").

## Architecture
| Part | Service | Free-tier facts (verified 2026-11-04) | Card? |
|---|---|---|---|
| Web (Flutter Web) | GitHub Pages via `.github/workflows/app.yml` | static hosting, HTTPS by default | No |
| Android APK | GitHub Actions artifact (same workflow) | public repos: free minutes; private: 2,000 min/month | No |
| Database | **Neon Free** PostgreSQL | 1 GB/project, 100 CU-h/project/month, scale-to-zero after 5 min (cannot disable). At a limit compute is **suspended, data is not deleted**; no overage billing on Free ([Neon FAQ](https://neon.com/faqs/free-plan-limits-and-quotas)) | Previously verified "no credit card required" on neon.com/pricing |
| API | **Render Free** web service (`render.yaml`) | sleeps after 15 min idle, ~1 min cold start, 750 instance-h/month | ⚠️ Render support: "Sometimes, we may request card details for verification" ($1 hold, reversed) ([Render community](https://community.render.com/t/free-but-credit-card-first/24630)). **If Render asks for a card, stop** → alternative below |
| API alternative | Cloudflare Workers Free | 100k requests/day, no card; needs a ~60-line fetch adapter + `nodejs_compat` for `pg` (not written/tested yet) | No |

Never use Render's free PostgreSQL (deleted 30 days after creation).

## Secrets (never in Git, never in Flutter)
- `DATABASE_URL` — Neon **pooled** connection string with `?sslmode=require`; set only in Render's dashboard (render.yaml has `sync: false`).
- `CORS_ORIGINS` — exact web origin, e.g. `https://<github-user>.github.io`.
- Flutter only receives `API_BASE_URL` (public https URL) via a GitHub **repository variable**.

## Order of operations
1. Neon: create project `value-attendance` (region close to Render Frankfurt, e.g. AWS eu-central-1). Copy the pooled connection string **into your own terminal**, not into chat.
2. From the PC: `cd api; $env:DATABASE_URL="..."; $env:EXPECT_DATABASE="neondb"; npm install; npm run migrate; npm run seed:dev` (prints the owner's one-time password locally).
3. Render: New → Blueprint → this repo → set `DATABASE_URL`, `CORS_ORIGINS`. Check `https://<service>.onrender.com/healthz`.
4. GitHub: repo Settings → Pages → Source "GitHub Actions"; Settings → Variables → `API_BASE_URL=https://<service>.onrender.com`. Push → workflow builds, tests, deploys Pages, uploads the APK.
5. Verify: `https://<user>.github.io/<repo>/` loads over HTTPS, login works, CORS only allows that origin.

## Backups (independent of any provider)
Weekly, from the PC (PostgreSQL client tools installed):
```powershell
pg_dump "<DATABASE_URL>" --format=custom --no-owner --file "D:\Backups\value-attendance-$(Get-Date -f yyyyMMdd).dump"
```
Restore test into a scratch DB: `pg_restore --no-owner --dbname "<scratch-url>" <file>`.
Neon Free also keeps a short point-in-time history (not a substitute for your own dumps).

## APK signing
The workflow builds a release APK signed with Flutter's default debug key — installable by side-loading, **not** suitable for Google Play. A Play-ready build needs your own keystore stored as GitHub secrets.
