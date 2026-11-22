import { Router } from './http/router.ts';
import type { Ctx } from './ctx.ts';
import { authModule } from './modules/auth.ts';
import { employeesModule } from './modules/employees.ts';
import { orgModule } from './modules/org.ts';
import { attendanceModule } from './modules/attendance.ts';
import { requestsModule } from './modules/requests.ts';
import { kpiModule } from './modules/kpi.ts';
import { evaluationsModule } from './modules/evaluations.ts';
import { reportsModule } from './modules/reports.ts';
import { financeModule } from './modules/finance.ts';
import { dashboardModule } from './modules/dashboard.ts';
import { notificationsModule } from './modules/notifications.ts';
import { trackingModule } from './modules/tracking.ts';
import { permissionsModule } from './modules/permissions.ts';
import { legacyModule } from './modules/legacy.ts';
import { outingsModule } from './modules/outings.ts';
import { companyModule } from './modules/company.ts';
import { custodyModule } from './modules/custody.ts';
import { formsModule } from './modules/forms.ts';
import { dataResetModule } from './modules/data-reset.ts';
import { ownerDashboardModule } from './modules/owner-dashboard.ts';
import { exclusiveModule } from './modules/exclusive.ts';
import { leadsModule } from './modules/leads.ts';
import { leadsExtraModule } from './modules/leads2.ts';
import { leadsStagesDealsModule } from './modules/leads3.ts';
import { integrationsModule } from './modules/integrations.ts';
import { partnersModule } from './modules/partners.ts';
import { devicesModule } from './modules/devices.ts';
import { backupModule } from './modules/backup.ts';
import { payoutsModule } from './modules/payouts.ts';
import { commissionsModule } from './modules/commissions.ts';
import { cashModule } from './modules/cash.ts';
import { salesModule } from './modules/sales.ts';
import { payrollBatchesModule } from './modules/payroll-batches.ts';
import { financeDashboardModule } from './modules/finance-dashboard.ts';
import { yearClosingModule } from './modules/year-closing.ts';
import { companyPayoutsModule } from './modules/company-payouts.ts';
import { pushEnabled } from './lib/fcm.ts';
import { mailEnabled } from './lib/mail.ts';
import { authenticate, isOwner } from './auth/context.ts';
import type { Req } from './http/router.ts';

export function buildRouter(ctx: Ctx): Router {
  const r = new Router();
  r.get('/healthz', async () => ({ json: { ok: true } }));
  /**
   * Public monitoring (keep-warm, uptime checks): only "is it up" and one round-trip time. At most ONE database query per
   * instance every 5 s, however many anonymous callers there are (concurrent callers share it), so these routes cannot
   * be used to load the database. Configuration details (regions, pooler, migrations, push / mail / backup switches)
   * are shown only to the signed-in owner, whose requests are not shared or cached.
   */
  let probe: { at: number; p: Promise<{ ok: boolean; ms: number }> } | null = null;
  const sharedProbe = () => {
    const now = Date.now();
    if (!probe || now - probe.at > 5_000) {
      probe = { at: now, p: (async () => {
        const t0 = performance.now();
        try { await ctx.db.query('SELECT 1'); return { ok: true, ms: Math.round(performance.now() - t0) }; } catch { return { ok: false, ms: -1 }; }
      })() };
    }
    return probe.p;
  };
  const ownerCaller = async (req: Req) => {
    if (!req.headers.authorization) return false;
    try { return isOwner(await authenticate(ctx.db, req)); } catch { return false; }
  };
  /** Speed check: where the API runs, which region the database is in (host name only), round-trip times — owner only. */
  r.get('/healthz/latency', async (req) => {
    if (!(await ownerCaller(req))) {
      const x = await sharedProbe();
      return x.ok ? { json: { ok: true, dbRoundTripMs: [x.ms] } } : { status: 503, json: { ok: false } };
    }
    let dbRegion = 'unknown';
    try { dbRegion = new URL(process.env.DATABASE_URL ?? '').hostname.split('.').slice(1, -2).join('.') || 'unknown'; } catch { /* keep */ }
    const ms: number[] = [];
    try {
      for (let i = 0; i < 4; i++) {
        const t0 = performance.now();
        await ctx.db.query('SELECT 1');
        ms.push(Math.round(performance.now() - t0));
      }
    } catch {
      return { status: 503, json: { ok: false } };
    }
    return { json: { ok: true, apiRegion: process.env.VERCEL_REGION ?? 'local', dbRegion,
      pooled: process.env.VA_DB_DIRECT !== '1', dbRoundTripMs: ms } };
  });
  r.get('/readyz', async (req) => {
    if (!(await ownerCaller(req))) {
      const x = await sharedProbe();
      return x.ok ? { json: { ok: true } } : { status: 503, json: { ok: false } };
    }
    try {
      const x = await ctx.db.query(`SELECT count(*)::int AS n FROM schema_migrations`);
      return { json: { ok: true, migrations: x.rows[0].n, push: pushEnabled(), mail: mailEnabled(), backup: (process.env.BACKUP_TOKEN ?? '').length >= 24 } };
    } catch {
      return { status: 503, json: { ok: false } };
    }
  });
  for (const m of [authModule, devicesModule, employeesModule, orgModule, attendanceModule, requestsModule, kpiModule,
    evaluationsModule, reportsModule, financeModule, dashboardModule, notificationsModule, trackingModule, legacyModule, outingsModule, companyModule, custodyModule, backupModule, payoutsModule, commissionsModule, cashModule, salesModule, payrollBatchesModule, financeDashboardModule, yearClosingModule, companyPayoutsModule, formsModule, dataResetModule, ownerDashboardModule, exclusiveModule, integrationsModule, partnersModule, leadsStagesDealsModule, leadsExtraModule, leadsModule, permissionsModule]) m(r, ctx);
  return r;
}
