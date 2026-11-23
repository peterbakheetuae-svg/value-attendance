# VALUNIVO — Hybrid API architecture (Cloudflare gateway + Vercel backend)

Approved target: Cloudflare = stateless gateway only; Vercel = the only authoritative API; Neon = primary database.
Cloudflare holds no database credential and has no database binding. Branch `cloudflare/worker-migration`; staging only.
Production, DNS, routing and billing are unchanged.

```
app / web ──► Cloudflare gateway (no DB) ──► Vercel API ──► Neon
          └──────────── app's existing fallback: Vercel directly ─────┘
```

## 1. Gateway → Vercel signed envelope (v2)

Format: `src/lib/gateway-sig.ts` (shared, pure code); verification: `src/auth/gateway-verify.ts`. HMAC-SHA256 with `VA_GATEWAY_SECRET` over
`va-gw-v2 | METHOD | path | normalized query | timestamp | request id (UUID) | client IP | SHA-256(body)`.
Headers: `x-va-gw-ip`, `x-va-gw-ts`, `x-va-gw-id`, `x-va-gw-sig`. The gateway strips any client-supplied copies.

| Property | Behaviour on Vercel (`src/auth/ratelimit.ts`) |
|---|---|
| Binding | signature cannot be moved to another method, path, query, body or IP |
| Freshness | ≤ 60 s old, ≤ 10 s in the future; otherwise refused |
| Replay / duplicates | request id remembered for the window **per instance only** (instances share no memory). A replay can only repeat the identical request within 60 s, and needs the TLS traffic between Cloudflare and Vercel |
| Fail-closed | feature on + any gateway header present + anything wrong → **403 `gateway_signature_invalid`**, attempt not served |
| Direct requests | no gateway headers → platform IP (`x-vercel-forwarded-for`), exactly as today |
| Feature off | no secret ≥ 32 chars on Vercel → gateway headers ignored, behaviour exactly as today |
| Rotation | `VA_GATEWAY_SECRET_PREVIOUS` accepted while set: set new+previous on Vercel → switch gateway → remove previous |

Scope: the signed IP is consumed only by the sign-in / recovery throttle (`withIpLimit`: `/auth/login`, `/auth/forgot`,
`/auth/forgot/verify`, `/auth/forgot/reset`). Other routes never trust gateway headers, so they need no verification.

## 2. Rate limiting (end-to-end, gateway → real API over TLS, simulated Cloudflare egress IP)

- Through the gateway: 30 failures from one visitor → that visitor 429; three other visitors on the same Cloudflare egress sign in.
- Direct to Vercel (fallback): sign-in works; anonymous data routes still 401; an attacker is throttled by its own IP;
  forged gateway headers → 403.
- **Risk demonstrated:** with the gateway but WITHOUT the secret on Vercel, one visitor's 30 failures blocked every other
  visitor (all appear as Cloudflare's IP). This is very likely how today's production mirror Worker behaves. Hence:
  the secret on both sides is a hard prerequisite for any production use of the gateway.
- Office NAT: employees behind one office IP share a budget of 30 failed attempts / 15 min (pre-existing design; correct
  sign-ins never count). Per-account lockout is separate.

## 3. Public health endpoints (`src/app.ts`)

| Route | Anonymous / non-owner | Owner (signed in) |
|---|---|---|
| `/healthz` | `{ok}` — no DB (unchanged) | same |
| `/readyz` | `{ok}` only (was: migrations count, push / mail / backup switches) | full detail |
| `/healthz/latency` | `{ok, dbRoundTripMs:[1 value]}` (was: API region, DB region, pooler flag, 4 queries) | full detail, 4 samples |

Amplification: anonymous calls share one `SELECT 1` per instance per 5 s (single-flight). Test: 100 concurrent anonymous
calls → 1 query. keep-warm (`/healthz/latency`, status only) and app (`/healthz`) keep working.

## 4. Database (review of `db/checks/role_audit.sql`; production NOT inspected — no access)

Intended `valunivo_app` privileges (the SQL given for creation): LOGIN; no superuser / createdb / createrole /
replication / bypassrls; CONNECT; USAGE on `public`; **CREATE on `public` (temporary exception)**; SELECT, INSERT, UPDATE on all
tables; UPDATE revoked on `audit_log`; USAGE, SELECT on sequences; DELETE only on approved tables; default privileges for
future owner-created tables. The audit script (SELECT-only) shows the real state: role flags, memberships, schema rights,
owned objects, per-table grants, any TRUNCATE / REFERENCES / TRIGGER, UPDATE / DELETE on `audit_log`, connections by role.

Findings from the code:
- **CREATE is not needed at runtime.** It exists only because build-time `migrate` runs `CREATE TABLE IF NOT EXISTS
  schema_migrations` with the runtime URL. Remove it once migrations run with a separate, build-only credential (needs approval).
- Runtime DELETE targets (19 tables): web_push_subscriptions, role_permissions, push_tokens, holidays, employee_permissions,
  employee_documents, notifications, employee_devices, deals, tracking_pings, payroll_batch_lines, meta_pages,
  marketing_company_files, lead_targets, lead_routes, lead_attachments, ex_unit_files, evaluations, attendance_selfies.
  Any DELETE grant outside this list is unnecessary.
- The owner-only **data reset** (`/admin/data-reset`) uses `TRUNCATE`, which `valunivo_app` does not have → under least
  privilege it fails (no data changed). Safer as is; granting TRUNCATE is not recommended.
- No runtime DDL anywhere else; all values parameterized (interpolations are code constants / allow-listed column names).

## 5. Traffic and cost

Not yet measured: Vercel Hobby has no request metrics via API (needs paid Observability Plus); the mirror Worker's
analytics need a Cloudflare token. The workflow prints the mirror's per-day requests (14 days), daily average/max and
a monthly projection once `CF_MIRROR_SCRIPT` is set. Estimate until then: 60k–120k requests/day.
Gateway CPU ≈ 1 ms → Workers Free fits on CPU; the binding limit is Free's 100k requests/day (over it, the app falls back
to Vercel). Paid (US$5/month minimum) only if measured traffic is consistently > 100k/day. Nothing paid is enabled.

## 6. Staging — fully isolated from production

Staging never reaches Vercel, Neon or any production host:

```
GitHub runner ──► valunivo-gateway-staging (workers.dev) ──Service Binding──► valunivo-gw-verifier-staging (synthetic)
```

- The staging gateway's only upstream is a **synthetic verifier Worker** (`api/cloudflare/verifier.ts`): no database,
  no bindings, no business routes. It runs Vercel's exact verification code (`src/auth/gateway-verify.ts`) and answers
  `{synthetic, verdict, ip, method, path, query, bodySha256, headerNames}` — header names only, never values.
- `UPSTREAM` is `https://verifier.staging.invalid` (a reserved name that cannot resolve), so even a missing binding
  cannot send anything to production.
- CI gate refuses to deploy if either config mentions vercel.app, jaurea, valunivo., neon.tech, postgres,
  DATABASE_URL, Hyperdrive / D1 / KV, or routes, or if Workers Logs are on.
- Gateway secrets are generated inside each CI run (masked, never printed), and **both Workers are deleted at the end**.
- Permitted staging endpoints: `/__gateway/health`, any path answered by the verifier (synthetic), `/__verify/replay`,
  `/__verify/status-500`. No sign-in, CRM, HR, attendance, finance, payroll, backup or admin call reaches a real backend.
- Checks on real Cloudflare (`api/cloudflare/staging-checks.mts`): visitor IP = runner IP with spoofed
  CF-Connecting-IP / X-Forwarded-For / X-Real-IP ignored; forwarding headers stripped; normalized query; POST body hash
  equal end to end; replay refused; direct (gateway-bypassing) requests — no headers → direct, valid → trusted, wrong
  secret / 61 s old / 11 s future / changed body / changed method / incomplete headers → refused; upstream 500 passed
  through with no-store; 405 / 413 at the edge; secret rotation overlap and cut-off.
  Locally in workerd all pass except the visitor-IP check, which only real Cloudflare can prove (locally the client's
  CF-Connecting-IP is not overwritten).

### Replay and idempotency assessment

- Replay detection is **instance-local** (memory of one Vercel instance). Distributed detection would need a shared store
  (a small DB table — a migration — or a Durable Object), i.e. new infrastructure: not added, needs approval.
- Exposure is limited: the signature is only used to attribute an IP for the sign-in throttle; it grants no access.
  A replay requires reading TLS traffic between Cloudflare and Vercel, and repeats the identical request within 60 s.
- Sensitive writes: the gateway never retries. Duplicate protection for money already exists where a client resend is
  likely — cash receipts, cash expenses and sales collections take a client UUID (`clientRef`) and are de-duplicated
  in the database; decisions / transfers / payouts are state transitions (a second call finds the new state).
  Independent idempotency keys for every write would be an API contract change — not proposed now.

## 7. Production plan — FOR APPROVAL (nothing done)

1. Merge-approved deploy of the Vercel changes (signed IP, health endpoints) with `VA_GATEWAY_SECRET` set.
2. Replace the mirror Worker's code with `gateway.ts` + the same secret (same hostname → no app rebuild).
3. Watch 48 h (403 `gateway_signature_invalid`, 429 spread, 502/504, sign-in success). Rollback: redeploy the old mirror
   code, or rely on the app's fallback to Vercel.
