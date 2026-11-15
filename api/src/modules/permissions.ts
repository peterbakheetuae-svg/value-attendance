import { ok, type Module } from '../ctx.ts';
import { one } from '../db.ts';
import { forbidden, invalid, notFound } from '../http/errors.ts';
import { bool, isUuid, obj, oneOf, str } from '../http/validate.ts';
import { authenticate, has, SETTLED } from '../auth/context.ts';
import { MODULES, OWNER_ROLE, PERMISSIONS, PERM_BY_KEY } from '../lib/permission-registry.ts';
import {
  activeSql, assertCanAdminister, assertConfirmed, assertDelegable, assertKnown, assertNoLockout, assertNotOwnProfile,
  auditPermission, effectiveSql,
} from '../auth/permission-admin.ts';

/**
 * «إعدادات الشركة ← الصلاحيات»: the one place permissions are managed. Built on the existing engine — job-title profiles
 * (role_permissions) and individual exceptions (employee_permissions) — resolved on every request (context.ts), so a
 * change applies from the next request with nothing cached. Every endpoint needs roles.manage.
 */
export const permissionsModule: Module = (r, { db }) => {
  const listKeys = (v: unknown, field: string): string[] => {
    if (v === undefined) return [];
    if (!Array.isArray(v) || v.some((x) => typeof x !== 'string') || v.length > 200) throw invalid(`${field} must be a list`, { field });
    return [...new Set(v as string[])];
  };

  r.get('/permissions/registry', async (req) => {
    const a = await authenticate(db, req); await assertCanAdminister(a);
    return ok({
      modules: MODULES,
      permissions: PERMISSIONS.map((p) => ({ ...p, available: !!a.known?.has(p.key), delegable: has(a, p.key) })),
    });
  });

  r.get('/permissions/roles', async (req) => {
    const a = await authenticate(db, req); await assertCanAdminister(a);
    const me = await one(db, `SELECT COALESCE(position_key, role_key) AS k FROM employees WHERE id = $1`, [a.id]);
    const rows = await db.query(`
      SELECT r.key, r.name_ar, r.name_en, r.base_key, r.builtin, r.active, b.name_ar AS base_name_ar,
             COALESCE((SELECT array_agg(rp.perm_key ORDER BY rp.perm_key) FROM role_permissions rp WHERE rp.role_key = r.key), '{}') AS perms,
             (SELECT count(*)::int FROM employees e WHERE ${activeSql('e')} AND COALESCE(e.position_key, e.role_key) = r.key) AS employees
        FROM roles r LEFT JOIN roles b ON b.key = r.base_key
       ORDER BY r.active DESC, COALESCE(b.rank, r.rank) DESC, r.builtin DESC, r.name_ar`);
    return ok({
      roles: rows.rows.map((x) => ({
        key: x.key, nameAr: x.name_ar, nameEn: x.name_en, baseKey: x.base_key, baseNameAr: x.base_name_ar, builtin: x.builtin,
        active: x.active, employees: x.employees, perms: (x.perms as string[]).filter((k) => PERM_BY_KEY.has(k)),
        editable: x.key !== OWNER_ROLE && x.key !== me?.k,
        lockedReason: x.key === OWNER_ROLE ? 'owner' : x.key === me?.k ? 'own_profile' : null,
      })),
    });
  });

  r.get('/permissions/employees', async (req) => {
    const a = await authenticate(db, req); await assertCanAdminister(a);
    const q = (req.query.get('q') ?? '').trim().slice(0, 80);
    const rows = await db.query(`
      SELECT e.id, e.code, e.full_name, COALESCE(e.position_key, e.role_key) AS role_key, COALESCE(p.name_ar, r.name_ar) AS role_name,
             (SELECT count(*)::int FROM employee_permissions x WHERE x.employee_id = e.id AND x.allow) AS granted,
             (SELECT count(*)::int FROM employee_permissions x WHERE x.employee_id = e.id AND NOT x.allow) AS denied
        FROM employees e JOIN roles r ON r.key = e.role_key LEFT JOIN roles p ON p.key = e.position_key
       WHERE ${activeSql('e')} AND ($1 = '' OR e.full_name ILIKE '%' || $1 || '%' OR e.code ILIKE '%' || $1 || '%')
       ORDER BY e.full_name LIMIT 200`, [q]);
    return ok({ employees: rows.rows.map((x) => ({
      id: x.id, code: x.code, name: x.full_name, roleKey: x.role_key, roleName: x.role_name, granted: x.granted, denied: x.denied,
      editable: x.id !== a.id && x.role_key !== OWNER_ROLE,
    })) });
  });

  r.get('/permissions/employees/:id', async (req) => {
    const a = await authenticate(db, req); await assertCanAdminister(a);
    if (!isUuid(req.params.id)) throw notFound();
    const e = await one(db, `
      SELECT e.id, e.code, e.full_name, e.role_key AS base_role, COALESCE(e.position_key, e.role_key) AS role_key,
             COALESCE(p.name_ar, r.name_ar) AS role_name, (COALESCE(e.legacy_fields->>'status', '') = '${SETTLED}') AS settled
        FROM employees e JOIN roles r ON r.key = e.role_key LEFT JOIN roles p ON p.key = e.position_key WHERE e.id = $1`, [req.params.id]);
    if (!e) throw notFound();
    const inherited = (await db.query(`SELECT perm_key FROM role_permissions WHERE role_key = $1`, [e.role_key])).rows
      .map((x) => x.perm_key as string).filter((k) => PERM_BY_KEY.has(k));
    const ov = (await db.query(`SELECT perm_key, allow, updated_at, by_id FROM employee_permissions WHERE employee_id = $1`, [e.id])).rows;
    const overrides: Record<string, 'allow' | 'deny'> = {};
    for (const o of ov) if (PERM_BY_KEY.has(o.perm_key)) overrides[o.perm_key] = o.allow ? 'allow' : 'deny';
    const effective = e.settled ? [] : PERMISSIONS.map((p) => p.key).filter((k) =>
      overrides[k] === 'allow' || (overrides[k] !== 'deny' && inherited.includes(k)));
    return ok({
      employee: { id: e.id, code: e.code, name: e.full_name, roleKey: e.role_key, roleName: e.role_name, settled: e.settled },
      inherited, overrides, effective,
      editable: e.id !== a.id && e.base_role !== OWNER_ROLE,
      lockedReason: e.id === a.id ? 'self' : e.base_role === OWNER_ROLE ? 'owner' : null,
    });
  });

  /** change a job-title profile: { grant: [...], revoke: [...], confirm } */
  r.put('/permissions/roles/:key', async (req) => {
    const a = await authenticate(db, req); await assertCanAdminister(a);
    const b = obj(req.body);
    const grant = listKeys(b.grant, 'grant'), revoke = listKeys(b.revoke, 'revoke');
    if (grant.some((k) => revoke.includes(k))) throw invalid('Same permission in grant and revoke');
    if (!grant.length && !revoke.length) throw invalid('Nothing to change');
    const all = [...grant, ...revoke];
    assertKnown(a, all); assertDelegable(a, all);
    const role = await one(db, `SELECT key FROM roles WHERE key = $1`, [String(req.params.key).slice(0, 80)]);
    if (!role) throw notFound('المسمى مش موجود');
    await assertNotOwnProfile(db, a, role.key);
    assertConfirmed(all, bool(b, 'confirm') === true);
    const changed = await db.tx(async (q) => {
      const before = new Set((await q.query(`SELECT perm_key FROM role_permissions WHERE role_key = $1`, [role.key])).rows.map((x) => x.perm_key));
      const done: string[] = [];
      for (const k of grant) if (!before.has(k)) {
        await q.query(`INSERT INTO role_permissions (role_key, perm_key) VALUES ($1,$2)`, [role.key, k]);
        await auditPermission(q, a, { kind: 'role', id: role.key }, k, 'off', 'on', 'permissions_page'); done.push(k);
      }
      for (const k of revoke) if (before.has(k)) {
        await q.query(`DELETE FROM role_permissions WHERE role_key = $1 AND perm_key = $2`, [role.key, k]);
        await auditPermission(q, a, { kind: 'role', id: role.key }, k, 'on', 'off', 'permissions_page'); done.push(k);
      }
      await assertNoLockout(q);
      return done;
    });
    return ok({ changed });
  });

  /** an individual exception: { perm, value: allow | deny | inherit, confirm } */
  r.put('/permissions/employees/:id', async (req) => {
    const a = await authenticate(db, req); await assertCanAdminister(a);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const perm = str(b, 'perm', { min: 3, max: 80 })!;
    const value = oneOf(b, 'value', ['allow', 'deny', 'inherit'] as const)!;
    if (req.params.id === a.id) throw forbidden('مش ممكن تعدّل صلاحياتك بنفسك');
    const e = await one(db, `SELECT id, role_key FROM employees WHERE id = $1`, [req.params.id]);
    if (!e) throw notFound('الموظف مش موجود');
    if (e.role_key === OWNER_ROLE) throw forbidden('حساب المالك عنده كل الصلاحيات دايمًا (مسار الاسترداد)');
    assertKnown(a, [perm]); assertDelegable(a, [perm]);
    assertConfirmed([perm], bool(b, 'confirm') === true);
    await db.tx(async (q) => {
      const prev = await one(q, `SELECT allow FROM employee_permissions WHERE employee_id = $1 AND perm_key = $2`, [e.id, perm]);
      const before = !prev ? 'inherit' : prev.allow ? 'allow' : 'deny';
      if (before === value) return;
      if (value === 'inherit') await q.query(`DELETE FROM employee_permissions WHERE employee_id = $1 AND perm_key = $2`, [e.id, perm]);
      else await q.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow, by_id, updated_at) VALUES ($1,$2,$3,$4, now())
                            ON CONFLICT (employee_id, perm_key) DO UPDATE SET allow = EXCLUDED.allow, by_id = EXCLUDED.by_id, updated_at = now()`,
        [e.id, perm, value === 'allow', a.id]);
      await auditPermission(q, a, { kind: 'employee', id: e.id }, perm, before, value, 'permissions_page');
      await assertNoLockout(q);
    });
    return ok({ ok: true });
  });

  /** back to the job-title profile: removes every individual exception */
  r.post('/permissions/employees/:id/reset', async (req) => {
    const a = await authenticate(db, req); await assertCanAdminister(a);
    if (!isUuid(req.params.id)) throw notFound();
    if (req.params.id === a.id) throw forbidden('مش ممكن تعدّل صلاحياتك بنفسك');
    const e = await one(db, `SELECT id, role_key FROM employees WHERE id = $1`, [req.params.id]);
    if (!e) throw notFound('الموظف مش موجود');
    if (e.role_key === OWNER_ROLE) throw forbidden('حساب المالك عنده كل الصلاحيات دايمًا (مسار الاسترداد)');
    const ov = (await db.query(`SELECT perm_key, allow FROM employee_permissions WHERE employee_id = $1`, [e.id])).rows;
    const keys = ov.map((x) => x.perm_key as string);
    assertDelegable(a, keys.filter((k) => PERM_BY_KEY.has(k)));
    assertConfirmed(keys, bool(obj(req.body), 'confirm') === true);
    await db.tx(async (q) => {
      for (const o of ov) {
        await q.query(`DELETE FROM employee_permissions WHERE employee_id = $1 AND perm_key = $2`, [e.id, o.perm_key]);
        await auditPermission(q, a, { kind: 'employee', id: e.id }, o.perm_key, o.allow ? 'allow' : 'deny', 'inherit', 'permissions_page_reset');
      }
      await assertNoLockout(q);
    });
    return ok({ removed: keys.length });
  });

  /** who holds a permission (effective), e.g. before taking it away */
  r.get('/permissions/holders/:perm', async (req) => {
    const a = await authenticate(db, req); await assertCanAdminister(a);
    const perm = String(req.params.perm);
    if (!PERM_BY_KEY.has(perm)) throw notFound();
    const rows = await db.query(`SELECT e.id, e.full_name, e.code FROM employees e WHERE ${activeSql('e')} AND ${effectiveSql('e', '$1')} ORDER BY e.full_name`, [perm]);
    return ok({ holders: rows.rows.map((x) => ({ id: x.id, name: x.full_name, code: x.code })) });
  });

  /** the permission change history (read-only: audit_log rows are immutable at the database level) */
  r.get('/permissions/audit', async (req) => {
    const a = await authenticate(db, req); await assertCanAdminister(a);
    const limit = Math.min(Math.max(Number(req.query.get('limit') ?? 200) || 200, 1), 500);
    const rows = await db.query(`
      SELECT l.id, l.at, l.action, l.entity, l.entity_id, l.before, l.after, x.full_name AS actor_name,
             CASE WHEN l.entity = 'employee' THEN (SELECT full_name FROM employees WHERE id::text = l.entity_id)
                  ELSE (SELECT name_ar FROM roles WHERE key = l.entity_id) END AS target_name
        FROM audit_log l LEFT JOIN employees x ON x.id = l.actor_id
       WHERE l.action IN ('permission.role', 'permission.employee', 'role.permissions', 'leads.role_permission', 'leads.employee_permission')
       ORDER BY l.id DESC LIMIT $1`, [limit]);
    return ok({ entries: rows.rows.map((x) => ({
      id: Number(x.id), at: x.at, action: x.action, entity: x.entity, entityId: x.entity_id, targetName: x.target_name,
      actorName: x.actor_name, before: x.before, after: x.after,
    })) });
  });
};
