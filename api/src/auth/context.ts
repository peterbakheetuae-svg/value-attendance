import type { Q } from '../db.ts';
import { one } from '../db.ts';
import { AppError, forbidden, notFound } from '../http/errors.ts';
import type { Req } from '../http/router.ts';
import { sha256 } from './password.ts';

export interface Actor {
  id: string;
  code: string;
  fullName: string;
  role: string;
  perms: Set<string>;
  sessionId: string;
  mustChangePassword: boolean;
  /** «تم التصفيه»: the account is closed except reading his own attendance report */
  settled?: boolean;
}

/** an employee whose work status is «تم التصفيه» (settled / finished) */
export const SETTLED = 'تم التصفيه';

// stays signed in until the person signs out: 180 days, renewed on every use (sign-out / password change revoke it)
export const SESSION_TTL_HOURS = 24 * 180;

export async function authenticate(q: Q, req: Req, opts: { allowPasswordChange?: boolean } = {}): Promise<Actor> {
  const h = req.headers.authorization;
  if (!h || !h.startsWith('Bearer ')) throw new AppError('unauthenticated', 'Sign in required');
  const token = h.slice(7).trim();
  if (!token || token.length > 200) throw new AppError('unauthenticated', 'Sign in required');
  const row = await one(q, `
    SELECT s.id AS session_id, (s.last_seen_at IS NULL OR s.last_seen_at < now() - interval '5 minutes') AS stale,
           e.id, e.code, e.full_name, e.role_key, e.status, e.must_change_password, e.legacy_fields->>'status' AS work_status,
           COALESCE(array_agg(rp.perm_key) FILTER (WHERE rp.perm_key IS NOT NULL), '{}') AS perms,
           (SELECT COALESCE(array_agg(x.perm_key) FILTER (WHERE x.allow), '{}') FROM employee_permissions x WHERE x.employee_id = e.id) AS plus,
           (SELECT COALESCE(array_agg(x.perm_key) FILTER (WHERE NOT x.allow), '{}') FROM employee_permissions x WHERE x.employee_id = e.id) AS minus
      FROM sessions s
      JOIN employees e ON e.id = s.employee_id
      LEFT JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
     WHERE s.token_hash = $1 AND s.revoked_at IS NULL AND s.expires_at > now()
     GROUP BY s.id, e.id`, [sha256(token)]);
  if (!row || row.status !== 'active') throw new AppError('unauthenticated', 'Session expired, sign in again');
  // sliding expiry, bounded by the TTL from last activity — written at most every 5 minutes (one less database
  // round trip on almost every request)
  if (row.stale) {
    await q.query(`UPDATE sessions SET last_seen_at = now(),
                     expires_at = now() + make_interval(hours => $2) WHERE id = $1`, [row.session_id, SESSION_TTL_HOURS]);
  }
  const actor: Actor = {
    id: row.id, code: row.code, fullName: row.full_name, role: row.role_key,
    // his role's permissions, then his own exceptions (allowed / denied one by one)
    perms: new Set([...row.perms, ...(row.plus ?? [])].filter((p: string) => !(row.minus ?? []).includes(p))), sessionId: row.session_id, mustChangePassword: row.must_change_password,
  };
  // «تم التصفيه»: no permissions at all (every page closes) and nothing can be written — only reading his own
  // records (the attendance report) and signing out / changing the password
  if (row.work_status === SETTLED) {
    actor.settled = true;
    actor.perms = new Set();
    if (req.method !== 'GET' && !req.path.startsWith('/auth/')) throw forbidden('This account is settled');
  }
  if (actor.mustChangePassword && !opts.allowPasswordChange) {
    throw new AppError('forbidden', 'You must change your password first', { reason: 'must_change_password' });
  }
  return actor;
}

export const has = (a: Actor, p: string) => a.perms.has(p);

export function requirePerm(a: Actor, ...anyOf: string[]) {
  if (!anyOf.some((p) => a.perms.has(p))) throw forbidden();
}

/**
 * Employees a sales manager is responsible for: members of teams they manage,
 * plus anyone who names them directly as their sales manager.
 */
export async function teamMemberIds(q: Q, managerId: string): Promise<string[]> {
  const r = await q.query<{ id: string }>(`
    SELECT e.id FROM employees e
      LEFT JOIN teams t ON t.id = e.team_id
     WHERE (t.manager_id = $1 OR e.sales_manager_id = $1) AND e.id <> $1`, [managerId]);
  return r.rows.map((x) => x.id);
}

export async function isInTeam(q: Q, managerId: string, employeeId: string): Promise<boolean> {
  if (managerId === employeeId) return false;
  const r = await one(q, `
    SELECT 1 FROM employees e LEFT JOIN teams t ON t.id = e.team_id
     WHERE e.id = $2 AND (t.manager_id = $1 OR e.sales_manager_id = $1)`, [managerId, employeeId]);
  return !!r;
}

export type Scope = 'self' | 'team' | 'all';

/**
 * Resolve how far an actor may read a domain for a target employee.
 * Throws 404 (not 403) for out-of-scope targets so ids cannot be probed.
 */
export async function assertCanRead(q: Q, a: Actor, employeeId: string, domain: 'employee' | 'attendance' | 'request' | 'kpi' | 'evaluation'): Promise<Scope> {
  if (employeeId === a.id) return 'self';
  if (a.perms.has(`${domain}.read_all`)) return 'all';
  if (a.perms.has(`${domain}.read_team`) && await isInTeam(q, a.id, employeeId)) return 'team';
  throw notFound('Employee not found');
}

/** Returns the employee-id filter for list queries: null = everyone. */
export async function readableIds(q: Q, a: Actor, domain: string): Promise<string[] | null> {
  if (a.perms.has(`${domain}.read_all`)) return null;
  if (a.perms.has(`${domain}.read_team`)) return [a.id, ...(await teamMemberIds(q, a.id))];
  return [a.id];
}

export async function audit(q: Q, actorId: string | null, action: string, entity: string, entityId: string | null, before?: unknown, after?: unknown) {
  await q.query(`INSERT INTO audit_log (actor_id, action, entity, entity_id, before, after)
                 VALUES ($1,$2,$3,$4,$5,$6)`,
    [actorId, action, entity, entityId, before === undefined ? null : JSON.stringify(before), after === undefined ? null : JSON.stringify(after)]);
}
