import type { Q } from '../db.ts';
import { one } from '../db.ts';
import { AppError, forbidden, notFound } from '../http/errors.ts';
import type { Req } from '../http/router.ts';
import { sha256 } from './password.ts';
import { OWNER_ROLE, PERMISSIONS, PERM_BY_KEY, isOwnerOnly, isRegistered } from '../lib/permission-registry.ts';

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
  /** permission keys that exist in this database (a fine-grained key added by a migration not run yet is absent) */
  known?: ReadonlySet<string>;
  /** a marketing company (079) looking at the sales pages read-only: its company id (also in `id`) — never an employee */
  partner?: string;
  /** when this session last talked to the server BEFORE this request (written every ≤ 5 minutes) — an offline record
   *  claiming an earlier time while the phone was online after it is not trusted */
  prevSeenAt?: Date | null;
}

/**
 * The sales pages a marketing company opens exactly as the salesmen see them (read-only): every other route refuses its
 * token. The handlers scope it to its own campaigns' leads (scopeSql) and give it no permission at all.
 */
export function partnerRoute(method: string, path: string): boolean {
  if (method === 'GET') {
    return /^\/leads(\/(meta|dashboard|config|calendar|targets\/me|[0-9a-f-]{36}(\/(extra|whatsapp))?))?$/.test(path)
      || /^\/(tasks|integrations|integrations\/meta\/campaigns|notifications)$/.test(path);
  }
  if (method === 'POST') return path === '/leads' || /^\/notifications\/([0-9a-f-]{36}\/read|read-all)$/.test(path);
  if (method === 'DELETE') return /^\/notifications(\/[0-9a-f-]{36})?$/.test(path);
  if (method === 'PATCH') return /^\/leads\/campaigns\/[0-9a-f-]{36}\/partner$/.test(path);
  return false;
}

// the permission keys of this database: read once a minute per instance (they only change with a migration)
let knownKeys: { at: number; keys: ReadonlySet<string> } | null = null;
async function dbPermissionKeys(q: Q): Promise<ReadonlySet<string>> {
  if (knownKeys && Date.now() - knownKeys.at < 60_000) return knownKeys.keys;
  const r = await q.query<{ key: string }>(`SELECT key FROM permissions`);
  knownKeys = { at: Date.now(), keys: new Set(r.rows.map((x) => x.key)) };
  return knownKeys.keys;
}

/** drops the cached key list (the next request reads it again) — for the throwaway test databases */
export function forgetPermissionKeys() { knownKeys = null; }

/**
 * SQL: the employee (alias) holds the «مسؤول إداري» (administrative officer) position — whatever its key is in this
 * database: migration 057 created it as «admin_officer» or renamed an existing «HR ومحاسب» position, keeping that key.
 * The position is resolved the way permissions are (COALESCE(position_key, role_key)).
 */
export const adminOfficerSql = (e = 'e') => `EXISTS (SELECT 1 FROM roles ao_r WHERE ao_r.key = COALESCE(${e}.position_key, ${e}.role_key)
  AND (ao_r.key = 'admin_officer' OR ao_r.name_ar = 'مسؤول إداري'))`;

/** an employee whose work status is «تم التصفيه» (settled / finished) */
export const SETTLED = 'تم التصفيه';
/** SQL: the employee (alias) is not «تم التصفيه» — he is out of the attendance boards, the presence list and the counts */
export const notSettled = (e = 'e') => `COALESCE(${e}.legacy_fields->>'status', '') <> '${SETTLED}'`;
/**
 * SQL: the day (Cairo date) from which a «تم التصفيه» employee is settled — NULL for anyone else. The date is kept in
 * legacy_fields.settledAt when the status is set; for one settled before that it is read from the audit log, else the day
 * after his last attendance (else his joining date).
 */
export const settledFromSql = (e = 'e') => `(CASE WHEN COALESCE(${e}.legacy_fields->>'status', '') = '${SETTLED}' THEN COALESCE(
    CASE WHEN ${e}.legacy_fields->>'settledAt' ~ '^\\d{4}-\\d{2}-\\d{2}$' THEN (${e}.legacy_fields->>'settledAt')::date END,
    (SELECT (max(l.at) AT TIME ZONE 'Africa/Cairo')::date FROM audit_log l
      WHERE l.entity = 'employee' AND l.entity_id = ${e}.id::text AND l.action = 'employee.update'
        AND l.before->'legacy_fields'->'to'->>'status' = '${SETTLED}'
        AND (l.before->'legacy_fields'->'from'->>'status') IS DISTINCT FROM '${SETTLED}'),
    (SELECT max(x.work_date) + 1 FROM attendance x WHERE x.employee_id = ${e}.id),
    ${e}.joining_date) END)`;

// stays signed in until the person signs out: 180 days, renewed on every use (sign-out / password change revoke it)
export const SESSION_TTL_HOURS = 24 * 180;

export async function authenticate(q: Q, req: Req, opts: { allowPasswordChange?: boolean } = {}): Promise<Actor> {
  const h = req.headers.authorization;
  if (!h || !h.startsWith('Bearer ')) throw new AppError('unauthenticated', 'Sign in required');
  const token = h.slice(7).trim();
  if (!token || token.length > 200) throw new AppError('unauthenticated', 'Sign in required');
  const row = await one(q, `
    SELECT s.id AS session_id, (s.last_seen_at IS NULL OR s.last_seen_at < now() - interval '5 minutes') AS stale,
           s.last_seen_at AS prev_seen, e.id, e.code, e.full_name, e.role_key, e.status, e.must_change_password, e.legacy_fields->>'status' AS work_status,
           COALESCE(array_agg(rp.perm_key) FILTER (WHERE rp.perm_key IS NOT NULL), '{}') AS perms,
           (SELECT COALESCE(array_agg(x.perm_key) FILTER (WHERE x.allow), '{}') FROM employee_permissions x WHERE x.employee_id = e.id) AS plus,
           (SELECT COALESCE(array_agg(x.perm_key) FILTER (WHERE NOT x.allow), '{}') FROM employee_permissions x WHERE x.employee_id = e.id) AS minus
      FROM sessions s
      JOIN employees e ON e.id = s.employee_id
      LEFT JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
     WHERE s.token_hash = $1 AND s.revoked_at IS NULL AND s.expires_at > now()
     GROUP BY s.id, s.last_seen_at, e.id`, [sha256(token)]);
  if (!row) {
    // a marketing company's token (075): it is signed in, just not as an employee — refused, never signed out
    const { isPartnerToken, partnerOf } = await import('./partner.ts');
    if (partnerRoute(req.method, req.path)) {
      const p = await partnerOf(q, req);
      if (p) {
        if (p.mustChangePassword) throw new AppError('forbidden', 'You must change your password first', { reason: 'must_change_password' });
        return { id: p.companyId, code: '', fullName: p.name, role: 'marketing_partner', perms: new Set(), sessionId: p.sessionId,
          mustChangePassword: false, partner: p.companyId, known: await dbPermissionKeys(q) };
      }
    }
    if (await isPartnerToken(q, token)) throw new AppError('forbidden', 'Marketing company accounts see only their own pages', { reason: 'partner_account' });
  }
  if (!row || row.status !== 'active') throw new AppError('unauthenticated', 'Session expired, sign in again');
  // sliding expiry, bounded by the TTL from last activity — written at most every 5 minutes (one less database
  // round trip on almost every request)
  if (row.stale) {
    await q.query(`UPDATE sessions SET last_seen_at = now(),
                     expires_at = now() + make_interval(hours => $2) WHERE id = $1`, [row.session_id, SESSION_TTL_HOURS]);
  }
  const actor: Actor = {
    id: row.id, code: row.code, fullName: row.full_name, role: row.role_key,
    // his role's permissions, then his own exceptions (allowed / denied one by one); a key the application does not
    // register is dropped (deny by default — no row can grant something the code does not know)
    // an owner-only key (data.reset) is never held by a non-owner, whatever a row says
    perms: new Set([...row.perms, ...(row.plus ?? [])].filter((p: string) => !(row.minus ?? []).includes(p) && isRegistered(p)
      && (row.role_key === OWNER_ROLE || !isOwnerOnly(p)))),
    sessionId: row.session_id, mustChangePassword: row.must_change_password,
    prevSeenAt: row.prev_seen ? new Date(row.prev_seen) : null,
    known: await dbPermissionKeys(q),
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

/**
 * The same permission resolution as sign-in, for an employee who is not making this request (e.g. checking that a media
 * link's viewer still may see it). null = no such active account.
 */
export async function actorById(q: Q, id: string): Promise<Actor | null> {
  const row = await one(q, `
    SELECT e.id, e.code, e.full_name, e.role_key, e.status, e.legacy_fields->>'status' AS work_status,
           COALESCE((SELECT array_agg(rp.perm_key) FROM role_permissions rp WHERE rp.role_key = COALESCE(e.position_key, e.role_key)), '{}') AS perms,
           (SELECT COALESCE(array_agg(x.perm_key) FILTER (WHERE x.allow), '{}') FROM employee_permissions x WHERE x.employee_id = e.id) AS plus,
           (SELECT COALESCE(array_agg(x.perm_key) FILTER (WHERE NOT x.allow), '{}') FROM employee_permissions x WHERE x.employee_id = e.id) AS minus
      FROM employees e WHERE e.id = $1`, [id]);
  if (!row || row.status !== 'active') return null;
  const settled = row.work_status === SETTLED;
  return {
    id: row.id, code: row.code, fullName: row.full_name, role: row.role_key, sessionId: '', mustChangePassword: false, settled,
    perms: settled ? new Set() : new Set([...row.perms, ...(row.plus ?? [])].filter((p: string) => !(row.minus ?? []).includes(p) && isRegistered(p)
      && (row.role_key === OWNER_ROLE || !isOwnerOnly(p)))),
    known: await dbPermissionKeys(q),
  };
}

export const has = (a: Actor, p: string) => isRegistered(p) && a.perms.has(p);

/** An owner account (role `owner`) that is not settled — the only kind of account that may wipe / import company data. */
export const isOwner = (a: Actor) => a.role === OWNER_ROLE && !a.settled;

/**
 * A fine-grained permission split from a broad one (migration 066). Where this database already has the fine key, only the
 * fine key counts (an individual restriction on it is respected); where it does not yet (the migration has not run), the
 * broad key it was split from decides — exactly today's behaviour.
 */
export function can(a: Actor, fine: string, broad: string | string[] | null): boolean {
  if (!a.known) return false; // the database's key list is unknown: deny (never a grant on missing information)
  if (a.known.has(fine)) return holdsFine(a, fine);
  // the key is missing although its migration has run (another key of the same migration exists): a damaged or
  // partly applied permission table — deny instead of falling back to the rule from before the key existed
  if (migrationApplied(a.known, fine)) return false;
  if (broad === null) return !a.settled; // had no separate check before
  return (Array.isArray(broad) ? broad : [broad]).some((b) => has(a, b));
}

/**
 * true when the migration that added `fine` has run on this database: another registered key introduced by the same
 * migration (same `since`) is present. A key with no `since` is one of the original keys — its absence is always an anomaly.
 */
export function migrationApplied(known: ReadonlySet<string>, fine: string): boolean {
  const since = PERM_BY_KEY.get(fine)?.since;
  if (since === undefined) return true;
  return PERMISSIONS.some((p) => p.since === since && p.key !== fine && known.has(p.key));
}

/** a fine key that exists in this database: held, and — where the registry says so — together with all its required keys */
function holdsFine(a: Actor, fine: string): boolean {
  return has(a, fine) && (PERM_BY_KEY.get(fine)?.requiresAll ?? []).every((k) => has(a, k));
}

/**
 * A permission that replaces a check on the owner's role name (migration 066: data.reset, commission.void_approved).
 * Once the key exists only the permission counts; until then the previous rule (the owner) applies unchanged.
 */
export function canOwnerOnly(a: Actor, key: string): boolean {
  return a.known?.has(key) ? has(a, key) : (a.role === 'owner' && !a.settled);
}

/**
 * What the app is told (GET /me): the permissions in force, with every fine-grained key resolved the way the server
 * resolves it — so the app asks only for the fine keys, before and after migration 066 alike.
 */
export function effectivePermissions(a: Actor): string[] {
  const out = new Set(a.perms);
  if (a.settled) return [];
  for (const p of PERMISSIONS) {
    if (a.known?.has(p.key)) { if (!holdsFine(a, p.key)) out.delete(p.key); continue; }
    // the same rule as can(): no key list, or a key missing after its migration ran → not held
    if (!a.known || migrationApplied(a.known, p.key)) { out.delete(p.key); continue; }
    if (p.openBefore || (p.splitFrom ? (Array.isArray(p.splitFrom) ? p.splitFrom : [p.splitFrom]).some((b) => has(a, b)) : (p.since && a.role === 'owner'))) out.add(p.key);
  }
  return [...out].sort();
}

export function requirePerm(a: Actor, ...anyOf: string[]) {
  if (!anyOf.some((p) => has(a, p))) throw forbidden();
}

export function requireCan(a: Actor, fine: string, broad: string | string[] | null) {
  if (!can(a, fine, broad)) throw forbidden();
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
