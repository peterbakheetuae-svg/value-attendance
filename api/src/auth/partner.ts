import type { Q } from '../db.ts';
import { one } from '../db.ts';
import { AppError } from '../http/errors.ts';
import type { Req } from '../http/router.ts';
import { sha256 } from './password.ts';
import { SESSION_TTL_HOURS } from './context.ts';

/**
 * A marketing company signed in (see db/migrations/075_marketing_partners.sql). It is not an employee: its sessions are
 * in partner_sessions, so `authenticate` (every employee endpoint) never accepts its token — only /partner/… and the
 * shared /auth/logout, /auth/change-password and /me (which answer it in its own shape).
 */
export interface Partner {
  companyId: string;
  name: string;
  sessionId: string;
  mustChangePassword: boolean;
}

const bearer = (req: Req) => {
  const h = req.headers.authorization;
  if (!h || !h.startsWith('Bearer ')) return null;
  const t = h.slice(7).trim();
  return t && t.length <= 200 ? t : null;
};

/** the marketing company behind this request's token, or null (not a partner token) */
export async function partnerOf(q: Q, req: Req): Promise<Partner | null> {
  const token = bearer(req);
  if (!token) return null;
  const row = await one(q, `
    SELECT s.id AS session_id, (s.last_seen_at IS NULL OR s.last_seen_at < now() - interval '5 minutes') AS stale,
           c.id, c.name, c.status = 'active' AS active, c.must_change_password
      FROM partner_sessions s JOIN marketing_companies c ON c.id = s.company_id
     WHERE s.token_hash = $1 AND s.revoked_at IS NULL AND s.expires_at > now()`, [sha256(token)]);
  if (!row) return null;
  if (!row.active) throw new AppError('unauthenticated', 'This account is deactivated');
  if (row.stale) {
    await q.query(`UPDATE partner_sessions SET last_seen_at = now(), expires_at = now() + make_interval(hours => $2) WHERE id = $1`,
      [row.session_id, SESSION_TTL_HOURS]);
  }
  return { companyId: row.id, name: row.name, sessionId: row.session_id, mustChangePassword: row.must_change_password };
}

/** /partner/… : the signed-in marketing company (401 otherwise) */
export async function authenticatePartner(q: Q, req: Req, opts: { allowPasswordChange?: boolean } = {}): Promise<Partner> {
  const p = await partnerOf(q, req);
  if (!p) throw new AppError('unauthenticated', 'Sign in required');
  if (p.mustChangePassword && !opts.allowPasswordChange) {
    throw new AppError('forbidden', 'You must change your password first', { reason: 'must_change_password' });
  }
  return p;
}

/** a valid partner token used on an employee endpoint: refused (403, not 401 — the app must not sign it out) */
export async function isPartnerToken(q: Q, token: string): Promise<boolean> {
  return !!(await one(q, `SELECT 1 FROM partner_sessions WHERE token_hash = $1 AND revoked_at IS NULL AND expires_at > now()`, [sha256(token)]));
}
