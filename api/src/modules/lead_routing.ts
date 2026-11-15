import { one, type Q } from '../db.ts';
import { holdersOf, notify } from './notify.ts';
import { insertLead, log, OPEN_SQL, rotation, type NewLead } from './leads.ts';

/**
 * Who gets a lead that came in by itself (Value Aqar, Meta lead ads, a campaign's public form) — see
 * db/migrations/064_lead_routing.sql:
 *   one    → the one chosen salesman
 *   online → in turn among the chosen salesmen online now; nobody online → the lead waits: the general manager /
 *            administrative officer (leads.waiting_alert) are alerted, and unless one of them distributes it, the first
 *            chosen salesman to come online gets it (assignWaiting, every minute)
 *   turn   → in turn among the chosen salesmen, online or not
 */
export const ROUTE_MODES = ['one', 'online', 'turn'] as const;
export type RouteMode = (typeof ROUTE_MODES)[number];

/** online = an open session seen in the last 10 minutes (the same as «مين أونلاين» on the leads board) */
export const ONLINE_MINUTES = 10;

/** the chosen salesmen who still work here, in the chosen order */
export async function liveSales(q: Q, ids: string[]): Promise<string[]> {
  if (!ids.length) return [];
  const r = await q.query(`
    SELECT x.id FROM unnest($1::uuid[]) WITH ORDINALITY AS x(id, ord) JOIN employees e ON e.id = x.id
     WHERE e.status = 'active' AND COALESCE(e.legacy_fields->>'status', '') <> 'تم التصفيه' ORDER BY x.ord`, [ids]);
  return r.rows.map((x) => x.id);
}

export async function onlineAmong(q: Q, ids: string[], now: Date): Promise<string[]> {
  if (!ids.length) return [];
  const r = await q.query(`
    SELECT x.id FROM unnest($1::uuid[]) WITH ORDINALITY AS x(id, ord)
     WHERE EXISTS (SELECT 1 FROM sessions s WHERE s.employee_id = x.id AND s.revoked_at IS NULL AND s.expires_at > $2
                     AND s.last_seen_at > $2::timestamptz - make_interval(mins => $3))
     ORDER BY x.ord`, [ids, now, ONLINE_MINUTES]);
  return r.rows.map((x) => x.id);
}

export interface Delivery { to: string | null; wait: string[]; pool: string[] }

/** who gets it now (or who it waits for) */
export async function pickFor(q: Q, mode: RouteMode, chosen: string[], now: Date): Promise<Delivery> {
  const live = await liveSales(q, chosen);
  if (!live.length) return { to: null, wait: [], pool: [] };
  if (mode === 'one') return { to: live[0], wait: [], pool: [] };
  if (mode === 'turn') return { to: (await rotation(q, live))[0], wait: [], pool: live };
  const on = await onlineAmong(q, live, now);
  if (on.length) return { to: (await rotation(q, on))[0], wait: [], pool: live };
  return { to: null, wait: live, pool: live };
}

const namesOf = async (q: Q, ids: string[]) =>
  ids.length ? (await q.query(`SELECT full_name FROM employees WHERE id = ANY($1::uuid[]) ORDER BY full_name`, [ids])).rows.map((x) => x.full_name) : [];

/**
 * A lead from outside: inserted, then given to whoever the rule says — or left waiting, with the managers alerted.
 * `from` names where it came from in the notifications («فاليو عقار», «فيسبوك», «الفورم»).
 */
export async function deliverLead(q: Q, x: NewLead, mode: RouteMode, chosen: string[], now: Date, from: string, about = '') {
  const d = await pickFor(q, mode, chosen, now);
  const res = await insertLead(q, null, x, d.to, now, 'form', d.pool);
  await q.query(`UPDATE leads SET assign_mode = $2 WHERE id = $1`, [res.lead.id, mode]);
  if (res.to) {
    await notify(q, { to: res.to, type: 'lead_assigned', title: `ليد جديد من ${from}: ${x.fullName}`, body: about || from, entity: 'lead',
      entityId: res.lead.id, dedupeKey: `lead:${res.lead.id}:${from}` });
    return res.lead;
  }
  // nobody got it: it waits for the chosen salesmen (online mode) and the managers are told either way
  if (d.wait.length) {
    await q.query(`UPDATE leads SET wait_pool = $2, wait_since = $3 WHERE id = $1`, [res.lead.id, d.wait, now]);
  }
  const names = await namesOf(q, d.wait);
  const body = d.wait.length
    ? `مفيش سيلز متصل دلوقتي. وزّعه بنفسك، أو هيروح أوتوماتيك لأول واحد يفتح من: ${names.join('، ')}`
    : 'مفيش سيلز متحدد يستقبله. وزّعه من لوحة الليدز';
  for (const to of await holdersOf(q, 'leads.waiting_alert')) {
    await notify(q, { to, type: 'lead_waiting', title: `ليد جديد من ${from} ومفيش سيلز متصل: ${x.fullName}`,
      body: about ? `${about} — ${body}` : body, entity: 'lead', entityId: res.lead.id, dedupeKey: `lead:${res.lead.id}:waiting` });
  }
  return res.lead;
}

/**
 * Every minute (the sweep): a waiting lead nobody distributed goes, in turn, to one of its chosen salesmen who came
 * online. A lead a manager distributed in the meantime is no longer waiting (it has someone).
 */
export async function assignWaiting(q: Q, now: Date) {
  const rows = await q.query(`
    SELECT l.id, l.full_name, l.wait_pool FROM leads l
     WHERE l.assigned_to IS NULL AND l.wait_since IS NOT NULL AND cardinality(l.wait_pool) > 0 AND ${OPEN_SQL}
     ORDER BY l.wait_since LIMIT 200 FOR UPDATE OF l SKIP LOCKED`);
  for (const l of rows.rows) {
    const live = await liveSales(q, l.wait_pool);
    const on = await onlineAmong(q, live, now);
    if (!on.length) {
      if (!live.length) await q.query(`UPDATE leads SET wait_pool = '{}', wait_since = NULL WHERE id = $1`, [l.id]); // nobody left to wait for
      continue;
    }
    const to = (await rotation(q, on))[0];
    await q.query(`UPDATE leads SET assigned_to = $2, assigned_at = $3, assign_pool = $4, wait_pool = '{}', wait_since = NULL,
                     pending_alerted_at = NULL, reminded_at = NULL, updated_at = $3 WHERE id = $1`, [l.id, to, now, live.length > 1 ? live : []]);
    await log(q, l.id, 'assign', null, { to, mode: 'online', turn: live.length > 1 });
    await notify(q, { to, type: 'lead_assigned', title: `ليد جديد ليك: ${l.full_name}`, body: 'كان مستني أول سيلز يفتح', entity: 'lead',
      entityId: l.id, dedupeKey: `lead:${l.id}:online` });
  }
}

/** a rule for a lead of Value Aqar: the property's, else its project's, else the default one */
export async function valueAqarRoute(q: Q, propertyExt: string, projectExt: string) {
  if (propertyExt) {
    const r = await one(q, `SELECT * FROM lead_routes WHERE source = 'valueaqar' AND target = 'property' AND external_id = $1`, [propertyExt]);
    if (r) return r;
    if (!projectExt) {
      const u = await one(q, `SELECT external_project_id FROM partner_units WHERE source = 'valueaqar' AND external_id = $1`, [propertyExt]);
      projectExt = u?.external_project_id ?? '';
    }
  }
  if (projectExt) {
    const r = await one(q, `SELECT * FROM lead_routes WHERE source = 'valueaqar' AND target = 'project' AND external_id = $1`, [projectExt]);
    if (r) return r;
  }
  return one(q, `SELECT * FROM lead_routes WHERE source = 'valueaqar' AND target = 'default'`);
}
