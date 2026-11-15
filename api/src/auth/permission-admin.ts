import type { Q } from '../db.ts';
import { one } from '../db.ts';
import { AppError, forbidden, invalid } from '../http/errors.ts';
import { has, SETTLED, type Actor } from './context.ts';
import { OWNER_ROLE, PERM_BY_KEY, isRegistered } from '../lib/permission-registry.ts';

/**
 * The rules every permission change goes through (the «الصلاحيات» page and the older role / leads screens alike):
 *  - only `roles.manage` holders change permissions;
 *  - nobody changes their own permissions (not their own job-title profile, not their own exceptions);
 *  - you can only grant / take away a permission you hold yourself (delegation);
 *  - only registered keys that exist in this database;
 *  - the owner profile and owner accounts are never restricted (the documented recovery path);
 *  - sensitive permissions need an explicit confirmation;
 *  - at least one active account must keep `roles.manage` (no lockout).
 */

/** SQL: employee [e] effectively holds [perm] — his profile's grant unless individually denied, or an individual grant. */
export const effectiveSql = (e: string, permParam: string) => `(
  (EXISTS (SELECT 1 FROM role_permissions rpx WHERE rpx.role_key = COALESCE(${e}.position_key, ${e}.role_key) AND rpx.perm_key = ${permParam})
   AND NOT EXISTS (SELECT 1 FROM employee_permissions epx WHERE epx.employee_id = ${e}.id AND epx.perm_key = ${permParam} AND NOT epx.allow))
  OR EXISTS (SELECT 1 FROM employee_permissions epx WHERE epx.employee_id = ${e}.id AND epx.perm_key = ${permParam} AND epx.allow))`;

const ACTIVE = (e: string) => `${e}.status = 'active' AND COALESCE(${e}.legacy_fields->>'status', '') <> '${SETTLED}'`;

export async function assertCanAdminister(a: Actor) {
  if (!has(a, 'roles.manage')) throw forbidden('إدارة الصلاحيات محتاجة صلاحية «إدارة الصلاحيات»');
}

/** the keys must be registered by the application and exist in this database */
export function assertKnown(a: Actor, keys: string[]) {
  for (const k of keys) {
    if (!isRegistered(k) || !a.known?.has(k)) throw invalid(`صلاحية غير معروفة: ${k}`, { field: 'perm', perm: k });
  }
}

/** delegation: only what you hold yourself */
export function assertDelegable(a: Actor, keys: string[]) {
  const missing = keys.filter((k) => !has(a, k));
  if (missing.length) throw forbidden(`مش ممكن تدّي أو تشيل صلاحية مش معاك: ${missing.join('، ')}`);
}

/** sensitive changes need { confirm: true } */
export function assertConfirmed(keys: string[], confirm: boolean) {
  const sensitive = keys.filter((k) => PERM_BY_KEY.get(k)?.sensitive);
  if (sensitive.length && !confirm) {
    throw new AppError('conflict', 'التغيير ده حساس ومحتاج تأكيد', { reason: 'needs_confirmation', perms: sensitive });
  }
}

/** your own job-title profile: changing it would change your own permissions */
export async function assertNotOwnProfile(q: Q, a: Actor, roleKey: string) {
  if (roleKey === OWNER_ROLE) throw forbidden('صلاحيات المالك ثابتة (مسار الاسترداد) ومش بتتعدل');
  const me = await one(q, `SELECT COALESCE(position_key, role_key) AS k FROM employees WHERE id = $1`, [a.id]);
  if (me?.k === roleKey) throw forbidden('مش ممكن تعدّل صلاحيات المسمى الوظيفي بتاعك');
}

/** at least one active account keeps roles.manage — checked inside the transaction after the change */
export async function assertNoLockout(q: Q) {
  const r = await one(q, `SELECT count(*)::int AS n FROM employees e WHERE ${ACTIVE('e')} AND ${effectiveSql('e', `'roles.manage'`)}`);
  if (r.n < 1) throw invalid('لازم يفضل حساب واحد على الأقل عنده «إدارة الصلاحيات»', { reason: 'lockout' });
}

export async function auditPermission(q: Q, a: Actor, target: { kind: 'role' | 'employee'; id: string }, perm: string,
  before: string, after: string, source: string) {
  await q.query(`INSERT INTO audit_log (actor_id, action, entity, entity_id, before, after) VALUES ($1,$2,$3,$4,$5,$6)`,
    [a.id, `permission.${target.kind}`, target.kind, target.id, JSON.stringify({ perm, value: before }),
      JSON.stringify({ perm, value: after, source })]);
}

export const activeSql = ACTIVE;
