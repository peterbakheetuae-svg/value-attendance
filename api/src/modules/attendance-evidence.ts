import { one, type Db } from '../db.ts';
import { AppError, invalid } from '../http/errors.ts';
import type { Req, Reply } from '../http/router.ts';
import type { Actor } from '../auth/context.ts';
import { audit } from '../auth/context.ts';

/**
 * SEC-06 — attendance evidence (migration 096). Every check-in / check-out / «I'm back» leaves one attendance_events
 * row with the phone's claims (its clock, location, mock-location flag) next to the server's own facts (the time the
 * request arrived, the session and its device), the time the record was given and review flags for HR. The punch
 * rules themselves (trusted time, geofence, fake-GPS refusal, duplicates) are unchanged: this only records and dedupes.
 *
 * Idempotency: the app sends `clientId` (a UUID made when the button is pressed, kept with an offline punch). The same
 * punch sent again — a retry after a lost reply, an offline queue sent twice, a replay — gets the first reply back and
 * changes nothing. A punch that was refused may be sent again (the reason may have been fixed). Without a clientId (an
 * older app) the punch works exactly as before and is still recorded.
 */
export type Step = 'check_in' | 'check_out' | 'return';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const LATE_MS = 5 * 60_000, DRIFT_MS = 2 * 60_000, MAX_ACCURACY_M = 200;

const numOrNull = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
const timeOrNull = (v: unknown) => {
  if (typeof v !== 'string' || !v) return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d;
};

export function clientIdOf(body: Record<string, unknown>): string | null {
  const v = body.clientId;
  if (v === undefined || v === null || v === '') return null;
  if (typeof v !== 'string' || !UUID.test(v)) throw invalid('clientId must be a UUID', { field: 'clientId' });
  return v.toLowerCase();
}

/** review flags from the claims and the facts (pure: tested on its own) */
export function evidenceFlags(p: {
  offline: boolean; deviceTime: Date | null; receivedAt: Date; usedTime: Date | null; claimOverridden: boolean;
  previousUsed: Date | null; mocked: boolean | null; accuracyM: number | null; hasLocation: boolean; deviceChanged: boolean;
}): string[] {
  const f: string[] = [];
  if (p.offline) f.push('offline');
  if (p.offline && p.deviceTime && p.receivedAt.getTime() - p.deviceTime.getTime() > LATE_MS) f.push('late_arrival');
  if (!p.offline && p.deviceTime && Math.abs(p.receivedAt.getTime() - p.deviceTime.getTime()) > DRIFT_MS) f.push('clock_drift');
  if (p.claimOverridden) f.push('claim_overridden');
  if (p.deviceTime && p.previousUsed && p.deviceTime.getTime() < p.previousUsed.getTime()) f.push('ordering');
  if (p.mocked === true) f.push('mock_reported');
  if (p.accuracyM !== null && p.accuracyM > MAX_ACCURACY_M) f.push('low_accuracy');
  if (!p.hasLocation) f.push('no_location');
  if (p.deviceChanged) f.push('device_changed');
  return f;
}

/**
 * Run one punch with its evidence. [run] does the punch exactly as before and returns its reply plus the time used
 * and whether the offline claim was overridden; an AppError it throws is recorded as a refusal and re-thrown.
 */
export async function withPunchEvidence(db: Db, a: Actor, req: Req, step: Step, receivedAt: Date,
  run: () => Promise<{ reply: Reply & { json: unknown }; usedTime: Date; overridden?: boolean }>): Promise<Reply> {
  const b = (req.body && typeof req.body === 'object' ? req.body : {}) as Record<string, unknown>;
  const clientId = clientIdOf(b);
  const offline = b.offlineAt !== undefined && b.offlineAt !== null && b.offlineAt !== '';
  const deviceTime = offline ? timeOrNull(b.offlineAt) : timeOrNull(b.deviceTime);
  const lat = numOrNull(b.lat), lng = numOrNull(b.lng), acc = numOrNull(b.accuracyM);
  const mocked = typeof b.mocked === 'boolean' ? b.mocked : null;
  const ses = await one(db, `SELECT device_id FROM sessions WHERE id = $1`, [a.sessionId]).catch(() => null);
  const deviceId: string | null = ses?.device_id ?? null;

  // claim this punch: the first sender of a clientId owns it; a later one gets the stored reply
  let eventId: string | null = null;
  const fields = [a.id, step, clientId, deviceTime, receivedAt, offline, lat, lng, acc, mocked, a.sessionId, deviceId];
  const ins = await one(db, `
    INSERT INTO attendance_events (employee_id, step, client_id, device_time, server_received_at, offline, lat, lng, accuracy_m, mocked, session_id, device_id)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
    ON CONFLICT (employee_id, client_id) WHERE client_id IS NOT NULL DO NOTHING RETURNING id`, fields);
  if (ins) eventId = ins.id;
  else {
    const prev = await one(db, `SELECT id, step, state, reply_status, reply FROM attendance_events WHERE employee_id = $1 AND client_id = $2`, [a.id, clientId]);
    if (prev?.state === 'accepted' && prev.step === step) {
      await audit(db, a.id, 'attendance.replayed', 'attendance_event', prev.id, undefined, { step });
      return { status: prev.reply_status ?? 200, json: prev.reply };
    }
    if (prev?.state === 'accepted' || (prev && prev.step !== step)) {
      throw new AppError('conflict', 'This punch id was already used for another step', { reason: 'client_id_reused', field: 'clientId' });
    }
    // refused before (may be sent again), or another request with it is still running
    const re = await one(db, `UPDATE attendance_events SET state = 'pending', refusal = NULL, device_time = $3, server_received_at = $4,
                                offline = $5, lat = $6, lng = $7, accuracy_m = $8, mocked = $9, session_id = $10, device_id = $11, flags = '{}'
                               WHERE employee_id = $1 AND client_id = $2 AND state = 'refused' RETURNING id`,
      [a.id, clientId, deviceTime, receivedAt, offline, lat, lng, acc, mocked, a.sessionId, deviceId]);
    if (!re) throw new AppError('conflict', 'This punch is already being recorded — try again in a moment', { reason: 'punch_in_progress' });
    eventId = re.id;
  }

  const prevUsed = (await one(db, `SELECT max(used_time) AS t FROM attendance_events WHERE employee_id = $1 AND state = 'accepted' AND id <> $2`, [a.id, eventId]))?.t ?? null;
  const prevDevice = (await one(db, `SELECT device_id FROM attendance_events WHERE employee_id = $1 AND state = 'accepted' AND id <> $2
                                      ORDER BY server_received_at DESC LIMIT 1`, [a.id, eventId]))?.device_id ?? null;
  const flagsFor = (usedTime: Date | null, overridden: boolean) => evidenceFlags({
    offline, deviceTime, receivedAt, usedTime, claimOverridden: overridden, previousUsed: prevUsed ? new Date(prevUsed) : null, mocked,
    accuracyM: acc, hasLocation: lat !== null && lng !== null, deviceChanged: !!(prevDevice && deviceId && prevDevice !== deviceId) });
  try {
    const out = await run();
    await db.query(`UPDATE attendance_events SET state = 'accepted', used_time = $2, flags = $3, reply_status = $4, reply = $5 WHERE id = $1`,
      [eventId, out.usedTime, flagsFor(out.usedTime, !!out.overridden), out.reply.status ?? 200, JSON.stringify(out.reply.json)]);
    return out.reply;
  } catch (e) {
    const why = e instanceof AppError ? String((e.details as any)?.reason ?? e.code) : 'error';
    await db.query(`UPDATE attendance_events SET state = 'refused', refusal = $2, flags = $3 WHERE id = $1`, [eventId, why.slice(0, 80), flagsFor(null, false)])
      .catch(() => undefined);
    throw e;
  }
}

/** HR's evidence list for one employee and day (read-only) */
export async function eventsFor(db: Db, employeeId: string, date: string) {
  return (await db.query(`
    SELECT id, step, state, refusal, device_time, server_received_at, used_time, offline, lat, lng, accuracy_m, mocked,
           device_id, flags, client_id IS NOT NULL AS has_client_id
      FROM attendance_events
     WHERE employee_id = $1 AND (server_received_at AT TIME ZONE 'Africa/Cairo')::date = $2::date
     ORDER BY server_received_at`, [employeeId, date])).rows;
}
