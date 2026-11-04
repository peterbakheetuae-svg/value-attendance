import { createSign } from 'node:crypto';
import type { Q } from '../db.ts';

/**
 * Firebase Cloud Messaging (HTTP v1) sender — free, no card. Configured only by the
 * FCM_SERVICE_ACCOUNT environment variable (the service-account JSON, kept on Netlify, never in Git).
 * Without it, push is simply off and the in-app polling alerts keep working.
 */
interface ServiceAccount { project_id: string; client_email: string; private_key: string }

let account: ServiceAccount | null | undefined;
let cached: { token: string; exp: number } | null = null;

function sa(): ServiceAccount | null {
  if (account !== undefined) return account;
  try {
    const raw = process.env.FCM_SERVICE_ACCOUNT;
    const j = raw ? JSON.parse(raw.trim().startsWith('{') ? raw : Buffer.from(raw, 'base64').toString('utf8')) : null;
    account = j?.project_id && j?.client_email && j?.private_key ? j : null;
  } catch { account = null; }
  return account ?? null;
}

export const pushEnabled = () => sa() !== null;

const b64url = (s: string | Buffer) => Buffer.from(s).toString('base64url');

async function accessToken(a: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cached && cached.exp - 60 > now) return cached.token;
  const head = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claim = b64url(JSON.stringify({ iss: a.client_email, scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600 }));
  const sig = createSign('RSA-SHA256').update(`${head}.${claim}`).sign(a.private_key).toString('base64url');
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${head}.${claim}.${sig}` }),
    signal: AbortSignal.timeout(5000),
  });
  if (!r.ok) throw new Error(`fcm auth ${r.status}`);
  const j = await r.json() as { access_token: string; expires_in: number };
  cached = { token: j.access_token, exp: now + j.expires_in };
  return j.access_token;
}

/** Push one notification to every live device of an employee. Never throws (push is best-effort). */
export async function pushTo(q: Q, employeeId: string, m: { id: string; type: string; title: string; body: string; entityId?: string | null }) {
  const a = sa();
  if (!a) return;
  try {
    const rows = await q.query<{ token: string }>(`
      SELECT p.token FROM push_tokens p JOIN sessions s ON s.id = p.session_id
       WHERE p.employee_id = $1 AND s.revoked_at IS NULL AND s.expires_at > now()`, [employeeId]);
    if (!rows.rows.length) return;
    const bearer = await accessToken(a);
    await Promise.all(rows.rows.map(async ({ token }) => {
      const r = await fetch(`https://fcm.googleapis.com/v1/projects/${a.project_id}/messages:send`, {
        method: 'POST', headers: { authorization: `Bearer ${bearer}`, 'content-type': 'application/json' },
        body: JSON.stringify({ message: {
          token,
          notification: { title: m.title, body: m.body },
          data: { id: m.id, type: m.type, entityId: m.entityId ?? '' },
          android: { priority: 'HIGH', notification: { channel_id: 'attendance_channel', sound: 'notification', default_vibrate_timings: true } },
        } }),
        signal: AbortSignal.timeout(5000),
      });
      if (r.status === 404 || r.status === 400) {
        const t = await r.text();
        if (/UNREGISTERED|INVALID_ARGUMENT/.test(t)) await q.query(`DELETE FROM push_tokens WHERE token = $1`, [token]);
      }
    }));
  } catch {
    // network / auth problem: the in-app alert still shows on the next poll
  }
}
