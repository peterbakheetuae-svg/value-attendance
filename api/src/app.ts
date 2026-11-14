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
import { backupModule } from './modules/backup.ts';
import { payoutsModule } from './modules/payouts.ts';
import { commissionsModule } from './modules/commissions.ts';
import { cashModule } from './modules/cash.ts';
import { salesModule } from './modules/sales.ts';
import { payrollBatchesModule } from './modules/payroll-batches.ts';
import { financeDashboardModule } from './modules/finance-dashboard.ts';
import { pushEnabled } from './lib/fcm.ts';
import { mailEnabled } from './lib/mail.ts';

export function buildRouter(ctx: Ctx): Router {
  const r = new Router();
  r.get('/healthz', async () => ({ json: { ok: true } }));
  /**
   * Speed check (no secrets): where the API runs, which region the database is in (from its host name only), and
   * how long a database round trip takes from here. A far database makes every screen slow.
   */
  r.get('/healthz/latency', async () => {
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
  r.get('/readyz', async () => {
    try {
      const x = await ctx.db.query(`SELECT count(*)::int AS n FROM schema_migrations`);
      return { json: { ok: true, migrations: x.rows[0].n, push: pushEnabled(), mail: mailEnabled(), backup: (process.env.BACKUP_TOKEN ?? '').length >= 24 } };
    } catch {
      return { status: 503, json: { ok: false } };
    }
  });
  for (const m of [authModule, employeesModule, orgModule, attendanceModule, requestsModule, kpiModule,
    evaluationsModule, reportsModule, financeModule, dashboardModule, notificationsModule, trackingModule, legacyModule, outingsModule, companyModule, custodyModule, backupModule, payoutsModule, commissionsModule, cashModule, salesModule, payrollBatchesModule, financeDashboardModule, formsModule, dataResetModule, ownerDashboardModule, exclusiveModule, leadsExtraModule, leadsModule]) m(r, ctx);
  return r;
}
