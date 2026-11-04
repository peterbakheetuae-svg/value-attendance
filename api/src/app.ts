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

export function buildRouter(ctx: Ctx): Router {
  const r = new Router();
  r.get('/healthz', async () => ({ json: { ok: true } }));
  r.get('/readyz', async () => {
    try {
      const x = await ctx.db.query(`SELECT count(*)::int AS n FROM schema_migrations`);
      return { json: { ok: true, migrations: x.rows[0].n } };
    } catch {
      return { status: 503, json: { ok: false } };
    }
  });
  for (const m of [authModule, employeesModule, orgModule, attendanceModule, requestsModule, kpiModule,
    evaluationsModule, reportsModule, financeModule, dashboardModule, notificationsModule, trackingModule, legacyModule, outingsModule, companyModule]) m(r, ctx);
  return r;
}
