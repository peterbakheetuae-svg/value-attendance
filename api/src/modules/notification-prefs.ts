import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, invalid } from '../http/errors.ts';
import { obj } from '../http/validate.ts';
import { audit, authenticate, has, type Actor } from '../auth/context.ts';
import { CATEGORIES, CATEGORY_AR, MANDATORY_FOR_HR_OWNER, type Category } from '../lib/notification-categories.ts';
import { forgetPrefsTable } from './notify.ts';

/**
 * «إعدادات الإشعارات» (2026-11-26, proposed 094): each person decides which categories of notifications HE receives.
 * A preference only silences; it never makes anyone a recipient of anything (that stays with the sending code and its
 * permission / team checks). No row = on: nobody is silenced by default.
 *  - categories offered: only those this person can receive by his role (the exit alarm only to people who follow others)
 *  - mandatory (shown locked, cannot be turned off): owners — everything; HR approvers — approvals and the exit alarm;
 *    security alerts, «إنت برة المكتب», the payment code and the follow-up calls are not categories at all (always sent)
 */
async function prefsInstalled(q: Q) {
  return !!(await one(q, `SELECT to_regclass('public.notification_preferences') IS NOT NULL AS ok`))?.ok;
}

/** the categories this person can receive at all (by his role and the team records) */
async function relevantCategories(q: Q, a: Actor): Promise<Category[]> {
  const followsOthers = has(a, 'attendance.read_all') || has(a, 'attendance.read_team') || a.role === 'owner'
    || !!(await one(q, `SELECT 1 FROM employees e LEFT JOIN teams t ON t.id = e.team_id
                         WHERE e.status = 'active' AND (t.manager_id = $1 OR e.sales_manager_id = $1 OR e.general_manager_id = $1) LIMIT 1`, [a.id]))
    || !!(await one(q, `SELECT 1 FROM employees e JOIN roles r ON r.key = COALESCE(e.position_key, e.role_key)
                         WHERE e.id = $1 AND (r.key IN ('admin_officer', 'manager') OR r.base_key = 'manager' OR r.name_ar = 'مسؤول إداري')`, [a.id]));
  return CATEGORIES.filter((c) => c !== 'unauthorized_exit' || followsOthers);
}

const mandatoryFor = (a: Actor, c: Category) => a.role === 'owner' || (MANDATORY_FOR_HR_OWNER.has(c) && has(a, 'request.approve_hr'));

export const notificationPrefsModule: Module = (r, { db }) => {
  r.get('/me/notification-preferences', async (req) => {
    const a = await authenticate(db, req);
    const installed = await prefsInstalled(db);
    const saved = installed ? new Map((await db.query(`SELECT category, enabled FROM notification_preferences WHERE employee_id = $1`, [a.id]))
      .rows.map((x) => [x.category as string, x.enabled as boolean])) : new Map<string, boolean>();
    const categories = (await relevantCategories(db, a)).map((c) => {
      const locked = mandatoryFor(a, c);
      return { key: c, nameAr: CATEGORY_AR[c], enabled: locked ? true : saved.get(c) ?? true, locked };
    });
    return ok({ installed, categories });
  });

  r.put('/me/notification-preferences', async (req) => {
    const a = await authenticate(db, req);
    if (!(await prefsInstalled(db))) throw new AppError('unprocessable', 'Notification preferences need migration 094', { reason: 'not_installed' });
    const b = obj(req.body);
    const list = Array.isArray(b.categories) ? b.categories : null;
    if (!list || list.length > CATEGORIES.length) throw invalid('categories must be a list', { field: 'categories' });
    const relevant = new Set(await relevantCategories(db, a));
    const changes: { key: Category; enabled: boolean }[] = [];
    for (const x of list) {
      const key = (x as any)?.key, enabled = (x as any)?.enabled;
      if (typeof enabled !== 'boolean' || !CATEGORIES.includes(key)) throw invalid('Unknown category', { field: 'categories' });
      if (!relevant.has(key)) throw new AppError('forbidden', 'This category is not available for your role', { reason: 'not_available', category: key });
      if (!enabled && mandatoryFor(a, key)) throw new AppError('forbidden', 'This category cannot be turned off for your role', { reason: 'mandatory', category: key });
      changes.push({ key, enabled });
    }
    await db.tx(async (q) => {
      for (const c of changes) {
        await q.query(`INSERT INTO notification_preferences (employee_id, category, enabled) VALUES ($1,$2,$3)
                       ON CONFLICT (employee_id, category) DO UPDATE SET enabled = EXCLUDED.enabled, updated_at = now()`, [a.id, c.key, c.enabled]);
      }
      await audit(q, a.id, 'notification_preferences.update', 'employee', a.id, undefined, { changes });
    });
    forgetPrefsTable();
    return ok({ saved: changes.length });
  });
};
