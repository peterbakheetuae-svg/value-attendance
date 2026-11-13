import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { bool, isUuid, num, obj, oneOf, str } from '../http/validate.ts';
import { audit, authenticate, has, teamMemberIds, type Actor } from '../auth/context.ts';
import type { Req } from '../http/router.ts';
import { notify } from './notify.ts';

/**
 * نظام الليدز — see db/migrations/055_leads.sql.
 *  - موزّع الليدز (leads.distribute): adds / imports leads and picks the salesmen (several → they take turns)
 *  - مدير السيلز (leads.team): sees his team's leads and moves them between his people
 *  - السيلز (leads.own): his leads only — «إضافة أكشن», the reservation from the lead
 *  - leads.read_all: every lead + the reports; leads.config: channels / campaigns / cancel reasons
 */
export const STAGES = ['new', 'no_answer', 'following', 'interested', 'meeting', 'after_meeting', 'reschedule', 'cancelled', 'reservation', 'done_deal'] as const;
export type Stage = typeof STAGES[number];
export const STAGE_AR: Record<Stage, string> = {
  new: 'جديد', no_answer: 'أول مكالمة — مردّش', following: 'متابعة', interested: 'مهتم', meeting: 'ميتنج',
  after_meeting: 'متابعة بعد الميتنج', reschedule: 'تأجيل ميتنج', cancelled: 'إلغاء', reservation: 'حجز', done_deal: 'تم البيع',
};
/** the stages the salesman picks in «إضافة أكشن» (حجز / تم البيع come from the reservation and the contract) */
const ACTION_STAGES = ['no_answer', 'following', 'interested', 'meeting', 'after_meeting', 'reschedule', 'cancelled'] as const;
const CLOSED: Stage[] = ['cancelled', 'done_deal'];
const NO_DATE: Stage[] = ['cancelled', 'reservation', 'done_deal'];
const OPEN_SQL = `l.stage NOT IN ('cancelled','done_deal','reservation')`;
const SM_OF = `NULLIF(COALESCE(e.sales_manager_id, t.manager_id), e.id)`;
const MAX_IMPORT = 1000;

const r2 = (v: number) => Math.round(v * 100) / 100;
const n = (v: unknown) => Number(v ?? 0);
const iso = (v: unknown) => (v == null ? null : v instanceof Date ? v.toISOString() : String(v));

export const canAll = (a: Actor) => has(a, 'leads.read_all') || has(a, 'leads.distribute');
const canDistribute = (a: Actor) => has(a, 'leads.distribute');
const canTeam = (a: Actor) => has(a, 'leads.team');
const canOwn = (a: Actor) => has(a, 'leads.own');
const canConfig = (a: Actor) => has(a, 'leads.config');
export const anyLeads = (a: Actor) => canAll(a) || canTeam(a) || canOwn(a);

/** digits only; an Egyptian mobile in any form (+20 / 0020 / 20 / 1xxxxxxxxx) becomes 01xxxxxxxxx */
export function phoneNorm(v: unknown): string {
  let d = String(v ?? '').replace(/[٠-٩]/g, (c) => String('٠١٢٣٤٥٦٧٨٩'.indexOf(c))).replace(/\D/g, '');
  if (d.startsWith('0020')) d = d.slice(4);
  else if (d.startsWith('20') && d.length === 12) d = d.slice(2);
  if (/^1\d{9}$/.test(d)) d = '0' + d;
  return d;
}

/** the people whose leads the actor sees: everyone (null) or a list of employee ids */
async function seenPeople(q: Q, a: Actor): Promise<string[] | null> {
  if (canAll(a)) return null;
  const ids = [a.id];
  if (canTeam(a)) ids.push(...await teamMemberIds(q, a.id));
  return ids;
}

/** SQL condition (alias l) for the leads the actor sees; pushes its parameters */
async function scopeSql(q: Q, a: Actor, params: unknown[]): Promise<string> {
  const people = await seenPeople(q, a);
  if (!people) return 'TRUE';
  params.push(people); const p = params.length;
  params.push(a.id); const me = params.length;
  return `(l.assigned_to = ANY($${p}::uuid[]) OR (l.assigned_to IS NULL AND l.created_by = $${me})
           OR EXISTS (SELECT 1 FROM lead_referrals rf WHERE rf.lead_id = l.id AND rf.employee_id = $${me}))`;
}

async function canSee(q: Q, a: Actor, leadId: string): Promise<boolean> {
  const params: unknown[] = [leadId];
  const s = await scopeSql(q, a, params);
  return !!(await one(q, `SELECT 1 FROM leads l WHERE l.id = $1 AND ${s}`, params));
}

/** who may work a lead (أكشن / حجز): its salesman, a salesman it was shared with, his team manager, the distributor */
async function canWork(q: Q, a: Actor, l: any): Promise<boolean> {
  if (l.assigned_to === a.id || canDistribute(a)) return true;
  if (await one(q, `SELECT 1 FROM lead_referrals WHERE lead_id = $1 AND employee_id = $2`, [l.id, a.id])) return true;
  if (canTeam(a) && l.assigned_to && (await teamMemberIds(q, a.id)).includes(l.assigned_to)) return true;
  return false;
}

/** the salesmen the actor may give leads to */
async function assignable(q: Q, a: Actor): Promise<any[]> {
  const rows = (await q.query(`
    SELECT DISTINCT e.id, e.full_name, e.code, e.role_key, e.team_id
      FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
     WHERE rp.perm_key = 'leads.own' AND e.status = 'active' ORDER BY e.full_name`)).rows;
  if (canDistribute(a)) return rows;
  if (canTeam(a)) {
    const team = new Set([a.id, ...await teamMemberIds(q, a.id)]);
    return rows.filter((e) => team.has(e.id));
  }
  return rows.filter((e) => e.id === a.id);
}

/** the order the given salesmen take their next leads in: the one who got a lead longest ago first */
async function rotation(q: Q, ids: string[]): Promise<string[]> {
  const r = await q.query(`
    SELECT x.id FROM unnest($1::uuid[]) WITH ORDINALITY AS x(id, ord)
     ORDER BY (SELECT max(l.assigned_at) FROM leads l WHERE l.assigned_to = x.id) ASC NULLS FIRST, x.ord`, [ids]);
  return r.rows.map((x) => x.id);
}

async function pickAssignees(q: Q, a: Actor, b: Record<string, unknown>, field = 'assignees'): Promise<string[]> {
  const raw = b[field];
  const ids = Array.isArray(raw) ? [...new Set(raw.filter((x): x is string => typeof x === 'string' && isUuid(x)))] : [];
  if (!ids.length) return [];
  const allowed = new Set((await assignable(q, a)).map((e) => e.id));
  for (const id of ids) if (!allowed.has(id)) throw invalid('اختار سيلز من اللي ينفع توزّع عليهم', { field });
  return ids;
}

async function log(q: Q, leadId: string, kind: string, by: string | null, data: Record<string, unknown> = {}) {
  await q.query(`INSERT INTO lead_logs (lead_id, kind, by_id, data) VALUES ($1,$2,$3,$4)`, [leadId, kind, by, JSON.stringify(data)]);
}

const LIST_SELECT = `
  SELECT l.*, s.full_name AS assigned_name, cr.full_name AS created_name, lb.full_name AS last_by_name,
         p.name AS project_name, ch.name AS channel_name, cp.name AS campaign_name, rs.name AS cancel_reason_name,
         d.full_name AS duplicate_of_name
    FROM leads l
    LEFT JOIN employees s ON s.id = l.assigned_to
    LEFT JOIN employees cr ON cr.id = l.created_by
    LEFT JOIN employees lb ON lb.id = l.last_action_by
    LEFT JOIN commission_projects p ON p.id = l.project_id
    LEFT JOIN lead_channels ch ON ch.id = l.channel_id
    LEFT JOIN lead_campaigns cp ON cp.id = l.campaign_id
    LEFT JOIN lead_cancel_reasons rs ON rs.id = l.cancel_reason_id
    LEFT JOIN leads d ON d.id = l.duplicate_of`;

function shape(l: any, now: Date, pendingMin: number) {
  const next = l.next_at ? new Date(l.next_at) : null;
  const open = !['cancelled', 'done_deal', 'reservation'].includes(l.stage);
  const assignedAt = l.assigned_at ? new Date(l.assigned_at) : null;
  const acted = l.last_action_at && assignedAt && new Date(l.last_action_at) >= assignedAt;
  return {
    id: l.id, refNo: Number(l.ref_no), fullName: l.full_name, phone: l.phone, extraPhones: l.extra_phones ?? [], email: l.email,
    budget: l.budget == null ? null : n(l.budget), kind: l.kind, stage: l.stage, stageAr: STAGE_AR[l.stage as Stage] ?? l.stage,
    stageChangedAt: iso(l.stage_changed_at), stageDays: Math.max(0, Math.floor((now.getTime() - new Date(l.stage_changed_at).getTime()) / 86_400_000)),
    nextAt: iso(l.next_at), overdue: !!(open && next && next < now),
    pending: !!(open && l.assigned_to && assignedAt && !acted && now.getTime() - assignedAt.getTime() >= pendingMin * 60_000),
    lastActionAt: iso(l.last_action_at), lastActionByName: l.last_by_name ?? null, lastComment: l.last_comment, noAnswerCount: l.no_answer_count,
    assignedTo: l.assigned_to ? { id: l.assigned_to, name: l.assigned_name } : null, assignedAt: iso(l.assigned_at),
    project: l.project_id ? { id: l.project_id, name: l.project_name } : null,
    channel: l.channel_id ? { id: l.channel_id, name: l.channel_name } : null,
    campaign: l.campaign_id ? { id: l.campaign_id, name: l.campaign_name } : null,
    cancelReason: l.cancel_reason_id ? { id: l.cancel_reason_id, name: l.cancel_reason_name } : null,
    duplicateOf: l.duplicate_of ? { id: l.duplicate_of, name: l.duplicate_of_name } : null,
    notes: l.notes, createdAt: iso(l.created_at), createdByName: l.created_name ?? null,
  };
}

async function pendingMinutes(q: Q): Promise<number> {
  const s = await one(q, `SELECT lead_pending_minutes FROM company_settings LIMIT 1`);
  return n(s?.lead_pending_minutes) || 25;
}

/** a reference (channel / campaign / project / reason) that must exist and be active */
async function ref(q: Q, table: string, id: unknown, field: string, msg: string): Promise<string | null> {
  if (id === undefined || id === null || id === '') return null;
  if (typeof id !== 'string' || !isUuid(id)) throw invalid(msg, { field });
  const active = table === 'commission_projects' ? `status = 'active'` : 'active';
  if (!await one(q, `SELECT 1 FROM ${table} WHERE id = $1 AND ${active}`, [id])) throw invalid(msg, { field });
  return id;
}

interface NewLead { fullName: string; phone: string; extraPhones: string[]; email: string; budget: number | null; kind: 'fresh' | 'cold';
  channelId: string | null; campaignId: string | null; projectId: string | null; notes: string }

function readLead(b: Record<string, unknown>): NewLead {
  const fullName = str(b, 'fullName', { min: 2, max: 120 })!;
  const phone = str(b, 'phone', { min: 5, max: 30 })!;
  if (phoneNorm(phone).length < 7) throw invalid('رقم الموبايل مش صحيح', { field: 'phone' });
  const extras = Array.isArray(b.extraPhones) ? b.extraPhones.filter((x): x is string => typeof x === 'string' && phoneNorm(x).length >= 7).slice(0, 5) : [];
  return {
    fullName, phone, extraPhones: extras.map((x) => x.trim()),
    email: (str(b, 'email', { optional: true, max: 160 }) ?? '').trim(),
    budget: num(b, 'budget', { optional: true, min: 0, max: 100_000_000_000 }) ?? null,
    kind: oneOf(b, 'kind', ['fresh', 'cold'] as const, true) ?? 'fresh',
    channelId: (b.channelId as string) || null, campaignId: (b.campaignId as string) || null, projectId: (b.projectId as string) || null,
    notes: (str(b, 'notes', { optional: true, max: 2000 }) ?? '').trim(),
  };
}

/** an existing lead with the same number (main or extra) */
async function findDuplicate(q: Q, phones: string[]) {
  const norms = [...new Set(phones.map(phoneNorm).filter((p) => p.length >= 7))];
  return one(q, `SELECT l.*, e.full_name AS assigned_name, e.status AS assigned_status FROM leads l LEFT JOIN employees e ON e.id = l.assigned_to
                  WHERE l.duplicate_of IS NULL AND (l.phone_norm = ANY($1::text[]) OR EXISTS (
                    SELECT 1 FROM unnest(l.extra_phones) x WHERE regexp_replace(x, '\\D', '', 'g') = ANY($1::text[])))
                  ORDER BY l.created_at LIMIT 1`, [norms]);
}

/**
 * Insert one lead. Its salesman: the one asked for, else the original lead's salesman for a repeated number,
 * else nobody (it waits in «مش متوزع»).
 */
async function insertLead(q: Q, a: Actor, x: NewLead, assignTo: string | null, now: Date, source: 'create' | 'import') {
  const dup = await findDuplicate(q, [x.phone, ...x.extraPhones]);
  if (dup && !canDistribute(a) && !canTeam(a)) {
    throw conflict(dup.assigned_to === a.id ? 'العميل ده موجود عندك بالفعل' : `الرقم ده موجود قبل كده${dup.assigned_name ? ` عند ${dup.assigned_name}` : ''}`);
  }
  let to = assignTo;
  if (dup && dup.assigned_to && dup.assigned_status === 'active') to = dup.assigned_to;
  const l = await one(q, `INSERT INTO leads (full_name, phone, phone_norm, extra_phones, email, budget, kind, channel_id, campaign_id, project_id,
        notes, created_by, created_at, updated_at, stage_changed_at, assigned_to, assigned_at, assigned_by, duplicate_of)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$13,$13,$14,CASE WHEN $14::uuid IS NULL THEN NULL ELSE $13::timestamptz END,
              CASE WHEN $14::uuid IS NULL THEN NULL ELSE $12::uuid END,$15) RETURNING *`,
    [x.fullName, x.phone, phoneNorm(x.phone), x.extraPhones, x.email, x.budget, x.kind, x.channelId, x.campaignId, x.projectId, x.notes, a.id, now, to, dup?.id ?? null]);
  await log(q, l.id, source, a.id, {});
  if (dup) await log(q, l.id, 'duplicate', a.id, { of: dup.id, ofRef: Number(dup.ref_no) });
  if (to) await log(q, l.id, 'assign', a.id, { to, mode: dup && to === dup.assigned_to ? 'duplicate' : 'manual' });
  if (dup && dup.assigned_to && dup.assigned_to !== a.id) {
    await notify(q, { to: dup.assigned_to, type: 'lead_duplicate', title: `العميل ${dup.full_name} رجع تاني`, body: `دخل كليد جديد برقم ${x.phone}`,
      entity: 'lead', entityId: l.id, dedupeKey: `lead:${l.id}:dup` });
  }
  return { lead: l, duplicate: !!dup, to };
}

export const leadsModule: Module = (r, { db, clock }) => {
  const auth = async (req: Req) => {
    const a = await authenticate(db, req);
    if (!anyLeads(a)) throw forbidden();
    return a;
  };

  // ------------------------------------------------------------------ meta
  r.get('/leads/meta', async (req) => {
    const a = await auth(req);
    const [channels, campaigns, reasons, projects, people] = await Promise.all([
      db.query(`SELECT id, name FROM lead_channels WHERE active ORDER BY sort, name`),
      db.query(`SELECT id, name, channel_id, project_id FROM lead_campaigns WHERE active ORDER BY created_at DESC`),
      db.query(`SELECT id, name FROM lead_cancel_reasons WHERE active ORDER BY sort, name`),
      db.query(`SELECT id, name, kind FROM commission_projects WHERE status = 'active' ORDER BY name`),
      assignable(db, a),
    ]);
    return ok({
      stages: STAGES.map((k) => ({ key: k, name: STAGE_AR[k], action: (ACTION_STAGES as readonly string[]).includes(k) })),
      channels: channels.rows, cancelReasons: reasons.rows, projects: projects.rows,
      campaigns: campaigns.rows.map((c) => ({ id: c.id, name: c.name, channelId: c.channel_id, projectId: c.project_id })),
      assignees: (canDistribute(a) || canTeam(a)) ? people.map((e) => ({ id: e.id, name: e.full_name, code: e.code })) : [],
      can: { all: canAll(a), distribute: canDistribute(a), team: canTeam(a), own: canOwn(a), config: canConfig(a),
        reports: canAll(a) || canTeam(a), import: canDistribute(a), assign: canDistribute(a) || canTeam(a) },
      pendingMinutes: await pendingMinutes(db), me: a.id,
    });
  });

  // ------------------------------------------------------------------ the list
  r.get('/leads', async (req) => {
    const a = await auth(req);
    const qs = req.query;
    const now = clock();
    const pm = await pendingMinutes(db);
    const params: unknown[] = [];
    const base: string[] = [await scopeSql(db, a, params)];
    const add = (sql: (i: number) => string, v: unknown) => { params.push(v); base.push(sql(params.length)); };
    const uuidQ = (k: string) => { const v = qs.get(k); return v && isUuid(v) ? v : null; };
    if (uuidQ('projectId')) add((i) => `l.project_id = $${i}`, uuidQ('projectId'));
    if (uuidQ('channelId')) add((i) => `l.channel_id = $${i}`, uuidQ('channelId'));
    if (uuidQ('campaignId')) add((i) => `l.campaign_id = $${i}`, uuidQ('campaignId'));
    if (uuidQ('cancelReasonId')) add((i) => `l.cancel_reason_id = $${i}`, uuidQ('cancelReasonId'));
    if (uuidQ('assignedTo')) add((i) => `l.assigned_to = $${i}`, uuidQ('assignedTo'));
    const from = qs.get('from'), to = qs.get('to');
    if (from && /^\d{4}-\d{2}-\d{2}$/.test(from)) add((i) => `l.created_at >= ($${i}::date::timestamp AT TIME ZONE 'Africa/Cairo')`, from);
    if (to && /^\d{4}-\d{2}-\d{2}$/.test(to)) add((i) => `l.created_at < (($${i}::date + 1)::timestamp AT TIME ZONE 'Africa/Cairo')`, to);
    if (qs.get('noAnswer') === '1') base.push(`l.no_answer_count > 0`);
    if (qs.get('noAction') === '1') base.push(`l.last_action_at IS NULL`);
    const search = (qs.get('q') ?? '').trim();
    if (search) {
      const digits = phoneNorm(search);
      params.push(`%${search.toLowerCase()}%`); const i = params.length;
      const conds = [`lower(l.full_name) LIKE $${i}`, `lower(l.last_comment) LIKE $${i}`, `lower(l.email) LIKE $${i}`];
      if (/^\d{4,7}$/.test(search)) conds.push(`l.ref_no = ${Number(search)}`);
      if (digits.length >= 4) { params.push(`%${digits.replace(/^0/, '')}%`); conds.push(`l.phone_norm LIKE $${params.length}`); }
      base.push(`(${conds.join(' OR ')})`);
    }
    params.push(now); const nowI = params.length;
    params.push(pm); const pmI = params.length;
    // every query below binds all of these (Postgres wants each parameter used)
    base.push(`$${nowI}::timestamptz IS NOT NULL AND $${pmI}::int IS NOT NULL`);
    const baseLen = params.length;
    const TABS: Record<string, string> = {
      all: 'TRUE',
      mine: `l.assigned_to = '${a.id}'`,
      fresh: `l.stage = 'new' AND l.kind = 'fresh'`,
      cold: `l.kind = 'cold' AND ${OPEN_SQL}`,
      duplicated: `l.duplicate_of IS NOT NULL`,
      delay: `${OPEN_SQL} AND l.next_at < $${nowI}`,
      pending: `${OPEN_SQL} AND l.assigned_to IS NOT NULL AND (l.last_action_at IS NULL OR l.last_action_at < l.assigned_at)
                AND l.assigned_at <= $${nowI}::timestamptz - make_interval(mins => $${pmI})`,
      unassigned: `l.assigned_to IS NULL`,
      shared: `EXISTS (SELECT 1 FROM lead_referrals rf WHERE rf.lead_id = l.id)`,
      today: `${OPEN_SQL} AND (l.next_at AT TIME ZONE 'Africa/Cairo')::date = ($${nowI}::timestamptz AT TIME ZONE 'Africa/Cairo')::date`,
    };
    const tab = qs.get('tab') && TABS[qs.get('tab')!] ? qs.get('tab')! : 'all';
    const stage = qs.get('stage');
    const where = [...base];
    where.push(TABS[tab]);
    if (stage && (STAGES as readonly string[]).includes(stage)) { params.push(stage); where.push(`l.stage = $${params.length}`); }
    const size = Math.min(Math.max(Number(qs.get('size')) || 25, 5), 200);
    const page = Math.max(Number(qs.get('page')) || 1, 1);
    const sortKey = qs.get('sort') ?? (canAll(a) || canTeam(a) ? 'created' : 'next');
    const ORDER: Record<string, string> = {
      created: 'l.created_at DESC',
      next: `(CASE WHEN ${OPEN_SQL} THEN 0 ELSE 1 END), l.next_at ASC NULLS LAST, l.created_at DESC`,
      action: 'l.last_action_at DESC NULLS LAST',
      name: 'l.full_name',
    };
    const order = ORDER[sortKey] ?? ORDER.created;
    const W = where.join(' AND ');
    const [rows, total, tabs, stages] = await Promise.all([
      db.query(`${LIST_SELECT} WHERE ${W} ORDER BY ${order} LIMIT ${size} OFFSET ${(page - 1) * size}`, params),
      one(db, `SELECT count(*)::int AS n FROM leads l WHERE ${W}`, params),
      one(db, `SELECT ${Object.entries(TABS).map(([k, v]) => `count(*) FILTER (WHERE ${v})::int AS "${k}"`).join(', ')} FROM leads l WHERE ${base.join(' AND ')}`, params.slice(0, baseLen)),
      db.query(`SELECT l.stage, count(*)::int AS n FROM leads l WHERE ${base.join(' AND ')} AND ${TABS[tab]} GROUP BY 1`, params.slice(0, baseLen)),
    ]);
    return ok({
      leads: rows.rows.map((l) => shape(l, now, pm)), total: total.n, page, size, tab,
      tabs, stages: Object.fromEntries(stages.rows.map((x) => [x.stage, x.n])),
    });
  });

  // ------------------------------------------------------------------ add one lead
  r.post('/leads', async (req) => {
    const a = await auth(req);
    const b = obj(req.body);
    const x = readLead(b);
    const now = clock();
    const out = await db.tx(async (q) => {
      x.channelId = await ref(q, 'lead_channels', x.channelId, 'channelId', 'اختار القناة');
      x.campaignId = await ref(q, 'lead_campaigns', x.campaignId, 'campaignId', 'اختار الحملة');
      x.projectId = await ref(q, 'commission_projects', x.projectId, 'projectId', 'اختار المشروع');
      if (!x.projectId) throw invalid('اختار المشروع', { field: 'projectId' });
      // a salesman's own lead is his; the distributor / manager pick the salesmen (several → their turn)
      let to: string | null = null;
      if (canDistribute(a) || canTeam(a)) {
        const ids = await pickAssignees(q, a, b);
        if (ids.length) to = (await rotation(q, ids))[0];
        else if (!canDistribute(a)) to = a.id;
      } else to = a.id;
      const res = await insertLead(q, a, x, to, now, 'create');
      if (res.to && res.to !== a.id) {
        await notify(q, { to: res.to, type: 'lead_assigned', title: `ليد جديد: ${x.fullName}`, body: res.duplicate ? 'عميل قديم رجع تاني' : 'ابدأ كلّمه',
          entity: 'lead', entityId: res.lead.id, dedupeKey: `lead:${res.lead.id}:assign:${now.getTime()}` });
      }
      await audit(q, a.id, 'lead.create', 'lead', res.lead.id, undefined, { to: res.to, duplicate: res.duplicate });
      return res;
    });
    const [l] = (await db.query(`${LIST_SELECT} WHERE l.id = $1`, [out.lead.id])).rows;
    return ok({ lead: shape(l, now, await pendingMinutes(db)), duplicate: out.duplicate }, 201);
  });

  // ------------------------------------------------------------------ import (Excel rows, sent as JSON by the app)
  r.post('/leads/import', async (req) => {
    const a = await auth(req);
    if (!canDistribute(a)) throw forbidden('الاستيراد لموزّع الليدز بس');
    const b = obj(req.body);
    const rows = Array.isArray(b.rows) ? b.rows : [];
    if (!rows.length) throw invalid('الملف فاضي', { field: 'rows' });
    if (rows.length > MAX_IMPORT) throw invalid(`أقصى عدد ${MAX_IMPORT} ليد في المرة`, { field: 'rows' });
    const kind = oneOf(b, 'kind', ['fresh', 'cold'] as const, true) ?? 'fresh';
    const now = clock();
    const result = await db.tx(async (q) => {
      const defProject = await ref(q, 'commission_projects', b.projectId, 'projectId', 'اختار المشروع');
      const defChannel = await ref(q, 'lead_channels', b.channelId, 'channelId', 'اختار القناة');
      const defCampaign = await ref(q, 'lead_campaigns', b.campaignId, 'campaignId', 'اختار الحملة');
      const ids = await pickAssignees(q, a, b);
      const turn = ids.length ? await rotation(q, ids) : [];
      const projects = new Map((await q.query(`SELECT id, lower(trim(name)) AS k FROM commission_projects WHERE status = 'active'`)).rows.map((p) => [p.k, p.id]));
      const channels = new Map((await q.query(`SELECT id, lower(trim(name)) AS k FROM lead_channels WHERE active`)).rows.map((p) => [p.k, p.id]));
      const seen = new Set<string>();
      const failed: { row: number; error: string }[] = [];
      let created = 0, duplicates = 0, k = 0;
      const perPerson = new Map<string, number>();
      for (let i = 0; i < rows.length; i++) {
        const raw = rows[i] && typeof rows[i] === 'object' ? rows[i] as Record<string, unknown> : {};
        const text = (v: unknown) => (v === undefined || v === null ? '' : String(v).trim());
        const row: Record<string, unknown> = { ...raw, fullName: text(raw.fullName), phone: text(raw.phone), email: text(raw.email), notes: text(raw.notes) };
        const budget = Number(String(raw.budget ?? '').replace(/[^\d.]/g, ''));
        row.budget = text(raw.budget) && Number.isFinite(budget) ? budget : undefined;
        row.extraPhones = text(raw.phone2) ? [text(raw.phone2)] : [];
        if (text(row.fullName).length < 2) { failed.push({ row: i + 1, error: 'الاسم ناقص' }); continue; }
        if (phoneNorm(row.phone).length < 7) { failed.push({ row: i + 1, error: 'رقم الموبايل ناقص أو غلط' }); continue; }
        await q.query('SAVEPOINT imp');
        try {
          const x = readLead({ ...row, kind });
          const norm = phoneNorm(x.phone);
          if (seen.has(norm)) { await q.query('RELEASE SAVEPOINT imp'); failed.push({ row: i + 1, error: 'الرقم متكرر في الملف' }); continue; }
          seen.add(norm);
          const pName = String(row.project ?? '').trim().toLowerCase(), cName = String(row.channel ?? '').trim().toLowerCase();
          x.projectId = (pName && projects.get(pName)) || defProject;
          x.channelId = (cName && channels.get(cName)) || defChannel;
          x.campaignId = defCampaign;
          if (!x.projectId) { await q.query('RELEASE SAVEPOINT imp'); failed.push({ row: i + 1, error: 'المشروع مش معروف' }); continue; }
          const to = turn.length ? turn[k % turn.length] : null;
          const res = await insertLead(q, a, x, to, now, 'import');
          await q.query('RELEASE SAVEPOINT imp');
          if (res.to === to) k++;
          created++;
          if (res.duplicate) duplicates++;
          if (res.to && res.to !== a.id) perPerson.set(res.to, (perPerson.get(res.to) ?? 0) + 1);
        } catch (e: any) {
          await q.query('ROLLBACK TO SAVEPOINT imp');
          failed.push({ row: i + 1, error: e?.message ?? 'خطأ' });
        }
      }
      for (const [to, count] of perPerson) {
        await notify(q, { to, type: 'lead_assigned', title: `اتوزع عليك ${count} ليد ${kind === 'cold' ? 'كولد' : 'فريش'}`, body: 'ابدأ كلّمهم',
          entity: 'lead', dedupeKey: `lead:import:${to}:${now.getTime()}` });
      }
      await audit(q, a.id, 'lead.import', 'lead', null, undefined, { created, duplicates, failed: failed.length });
      return { created, duplicates, failed };
    });
    return ok(result, 201);
  });

  // ------------------------------------------------------------------ «إضافة أكشن»
  r.post('/leads/:id/actions', async (req) => {
    const a = await auth(req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const stage = oneOf(b, 'stage', ACTION_STAGES)!;
    const comment = str(b, 'comment', { min: 1, max: 2000 })!;
    const answered = bool(b, 'answered') ?? stage !== 'no_answer';
    const callSeconds = num(b, 'callSeconds', { optional: true, min: 0, max: 36000, int: true }) ?? null;
    const now = clock();
    let nextAt: Date | null = null;
    if (!NO_DATE.includes(stage)) {
      const raw = str(b, 'nextAt', { optional: true, max: 40 });
      if (!raw) throw invalid('حدد معاد المتابعة الجاية', { field: 'nextAt' });
      nextAt = new Date(raw);
      if (Number.isNaN(nextAt.getTime())) throw invalid('معاد المتابعة مش صحيح', { field: 'nextAt' });
      if (nextAt.getTime() < now.getTime() - 5 * 60_000) throw invalid('معاد المتابعة لازم يكون بعد دلوقتي', { field: 'nextAt' });
    }
    const meetingKind = (str(b, 'meetingKind', { optional: true, max: 60 }) ?? '').trim();
    const meetingPlace = (str(b, 'meetingPlace', { optional: true, max: 120 }) ?? '').trim();
    const out = await db.tx(async (q) => {
      const l = await one(q, `SELECT * FROM leads WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!l || !await canSee(q, a, l.id)) throw notFound();
      if (!await canWork(q, a, l)) throw forbidden('الأكشن لسيلز العميل أو مديره');
      if (l.stage === 'done_deal') throw conflict('العميل ده اتباعله خلاص');
      const reasonId = stage === 'cancelled' ? await ref(q, 'lead_cancel_reasons', b.cancelReasonId, 'cancelReasonId', 'اختار سبب الإلغاء') : null;
      if (stage === 'cancelled' && !reasonId) throw invalid('اختار سبب الإلغاء', { field: 'cancelReasonId' });
      const x = await one(q, `INSERT INTO lead_actions (lead_id, stage, answered, call_seconds, comment, next_at, meeting_kind, meeting_place, cancel_reason_id, by_id, created_at)
          VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) RETURNING *`,
        [l.id, stage, answered, callSeconds, comment, nextAt, meetingKind, meetingPlace, reasonId, a.id, now]);
      await q.query(`UPDATE leads SET stage = $2, stage_changed_at = CASE WHEN stage = $2 THEN stage_changed_at ELSE $3 END, next_at = $4, reminded_at = NULL,
          last_action_at = $3, last_action_by = $5, last_comment = $6, no_answer_count = no_answer_count + CASE WHEN $7 THEN 0 ELSE 1 END,
          cancel_reason_id = $8, updated_at = $3 WHERE id = $1`,
        [l.id, stage, now, nextAt, a.id, comment.slice(0, 300), answered, reasonId]);
      if (l.assigned_to && l.assigned_to !== a.id) {
        await notify(q, { to: l.assigned_to, type: 'lead_comment', title: `${a.fullName} علّق على عميلك ${l.full_name}`, body: comment.slice(0, 120),
          entity: 'lead', entityId: l.id, dedupeKey: `lead:action:${x.id}` });
      }
      return x;
    });
    return ok({ action: { id: out.id } }, 201);
  });

  /** a reply on a comment (the manager's note to the salesman, or his answer) */
  r.post('/leads/actions/:id/reply', async (req) => {
    const a = await auth(req);
    if (!isUuid(req.params.id)) throw notFound();
    const comment = str(obj(req.body), 'comment', { min: 1, max: 2000 })!;
    const now = clock();
    await db.tx(async (q) => {
      const p = await one(q, `SELECT x.*, l.assigned_to, l.full_name FROM lead_actions x JOIN leads l ON l.id = x.lead_id WHERE x.id = $1`, [req.params.id]);
      if (!p || p.parent_id || !await canSee(q, a, p.lead_id)) throw notFound();
      const x = await one(q, `INSERT INTO lead_actions (lead_id, parent_id, comment, by_id, created_at) VALUES ($1,$2,$3,$4,$5) RETURNING id`,
        [p.lead_id, p.id, comment, a.id, now]);
      for (const to of new Set([p.by_id, p.assigned_to].filter((v) => v && v !== a.id))) {
        await notify(q, { to, type: 'lead_reply', title: `${a.fullName} ردّ على تعليق — ${p.full_name}`, body: comment.slice(0, 120),
          entity: 'lead', entityId: p.lead_id, dedupeKey: `lead:reply:${x.id}:${to}` });
      }
    });
    return ok({ ok: true }, 201);
  });

  // ------------------------------------------------------------------ التوزيع / إعادة التوزيع
  r.post('/leads/assign', async (req) => {
    const a = await auth(req);
    if (!canDistribute(a) && !canTeam(a)) throw forbidden();
    const b = obj(req.body);
    const ids = Array.isArray(b.ids) ? [...new Set(b.ids.filter((x): x is string => typeof x === 'string' && isUuid(x)))] : [];
    if (!ids.length) throw invalid('اختار الليدز', { field: 'ids' });
    if (ids.length > 1000) throw invalid('أقصى 1000 ليد في المرة', { field: 'ids' });
    const mode = oneOf(b, 'mode', ['fresh', 'cold', 'same'] as const, true) ?? 'same';
    const keepStage = bool(b, 'keepStage') ?? mode === 'same';
    const now = clock();
    const done = await db.tx(async (q) => {
      const to = await pickAssignees(q, a, b, 'to');
      if (!to.length) throw invalid('اختار السيلز', { field: 'to' });
      const order = await rotation(q, to);
      const params: unknown[] = [ids];
      const s = await scopeSql(q, a, params);
      const leads = (await q.query(`SELECT l.* FROM leads l WHERE l.id = ANY($1::uuid[]) AND ${s} ORDER BY l.created_at FOR UPDATE OF l`, params)).rows;
      if (leads.length !== ids.length) throw notFound('في ليدز مش عندك');
      const per = new Map<string, number>();
      const lastOf = new Map<string, any>();
      let k = 0;
      for (const l of leads) {
        const who = order[k++ % order.length];
        await q.query(`UPDATE leads SET assigned_to = $2, assigned_at = $3, assigned_by = $4, pending_alerted_at = NULL, reminded_at = NULL,
            kind = CASE WHEN $5 = 'same' THEN kind ELSE $5 END,
            stage = CASE WHEN $6 OR stage IN ('reservation','done_deal') THEN stage ELSE 'new' END,
            next_at = CASE WHEN $6 OR stage IN ('reservation','done_deal') THEN next_at ELSE NULL END,
            stage_changed_at = CASE WHEN $6 OR stage IN ('reservation','done_deal') THEN stage_changed_at ELSE $3 END,
            cancel_reason_id = CASE WHEN $6 THEN cancel_reason_id ELSE NULL END, updated_at = $3 WHERE id = $1`,
          [l.id, who, now, a.id, mode, keepStage]);
        await log(q, l.id, 'assign', a.id, { from: l.assigned_to, to: who, mode, keepStage, turn: order.length > 1 });
        if (who !== a.id) { per.set(who, (per.get(who) ?? 0) + 1); lastOf.set(who, l); }
      }
      for (const [who, count] of per) {
        await notify(q, { to: who, type: 'lead_assigned', title: count === 1 ? `اتوزع عليك ليد: ${lastOf.get(who).full_name}` : `اتوزع عليك ${count} ليد`,
          body: mode === 'cold' ? 'كولد كول' : 'ابدأ كلّمهم', entity: 'lead', entityId: count === 1 ? lastOf.get(who).id : undefined,
          dedupeKey: `lead:assign:${who}:${now.getTime()}` });
      }
      await audit(q, a.id, 'lead.assign', 'lead', null, undefined, { count: leads.length, to, mode });
      return leads.length;
    });
    return ok({ assigned: done });
  });

  /** مشاركة الليد مع سيلز تاني (it stays its salesman's) */
  r.post('/leads/:id/referral', async (req) => {
    const a = await auth(req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const now = clock();
    await db.tx(async (q) => {
      const l = await one(q, `SELECT * FROM leads WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!l || !await canSee(q, a, l.id)) throw notFound();
      if (!await canWork(q, a, l)) throw forbidden();
      const raw = Array.isArray(b.to) ? b.to.filter((x): x is string => typeof x === 'string' && isUuid(x)) : [];
      if (!raw.length) throw invalid('اختار السيلز', { field: 'to' });
      const people = new Set((await q.query(`SELECT DISTINCT e.id FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
                                               WHERE rp.perm_key = 'leads.own' AND e.status = 'active'`)).rows.map((e) => e.id));
      for (const id of raw) {
        if (!people.has(id) || id === l.assigned_to) continue;
        const ins = await q.query(`INSERT INTO lead_referrals (lead_id, employee_id, by_id, created_at) VALUES ($1,$2,$3,$4) ON CONFLICT DO NOTHING`, [l.id, id, a.id, now]);
        if (!ins.rowCount) continue;
        await log(q, l.id, 'referral', a.id, { to: id });
        await notify(q, { to: id, type: 'lead_referral', title: `${a.fullName} شاركك في عميل: ${l.full_name}`, entity: 'lead', entityId: l.id,
          dedupeKey: `lead:${l.id}:ref:${id}` });
      }
    });
    return ok({ ok: true });
  });

  // ------------------------------------------------------------------ the dashboard
  r.get('/leads/dashboard', async (req) => {
    const a = await auth(req);
    const now = clock();
    const pm = await pendingMinutes(db);
    const params: unknown[] = [];
    let scope = await scopeSql(db, a, params);
    const view = req.query.get('view') ?? (canAll(a) || canTeam(a) ? 'all' : 'me');
    const who = req.query.get('employeeId');
    if (view === 'me') { params.push(a.id); scope += ` AND l.assigned_to = $${params.length}`; }
    else if (who && isUuid(who)) { params.push(who); scope += ` AND l.assigned_to = $${params.length}`; }
    params.push(now); const t = params.length;
    params.push(pm); const p = params.length;
    scope += ` AND $${t}::timestamptz IS NOT NULL AND $${p}::int IS NOT NULL`;
    const c = await one(db, `
      SELECT count(*)::int AS total,
             count(*) FILTER (WHERE l.stage = 'new')::int AS fresh,
             count(*) FILTER (WHERE l.kind = 'cold' AND ${OPEN_SQL})::int AS cold,
             count(*) FILTER (WHERE l.duplicate_of IS NOT NULL)::int AS duplicated,
             count(*) FILTER (WHERE l.assigned_to IS NULL)::int AS unassigned,
             count(*) FILTER (WHERE ${OPEN_SQL} AND l.next_at < $${t})::int AS delay,
             count(*) FILTER (WHERE ${OPEN_SQL} AND (l.next_at AT TIME ZONE 'Africa/Cairo')::date = ($${t}::timestamptz AT TIME ZONE 'Africa/Cairo')::date)::int AS today,
             count(*) FILTER (WHERE ${OPEN_SQL} AND l.assigned_to IS NOT NULL AND (l.last_action_at IS NULL OR l.last_action_at < l.assigned_at)
                                AND l.assigned_at <= $${t}::timestamptz - make_interval(mins => $${p}))::int AS pending
        FROM leads l WHERE ${scope}`, params);
    const stages = await db.query(`SELECT l.stage, count(*)::int AS n FROM leads l WHERE ${scope} GROUP BY 1`, params);
    const delay = await db.query(`SELECT l.stage, count(*)::int AS n FROM leads l WHERE ${scope} AND ${OPEN_SQL} AND l.next_at < $${t} GROUP BY 1`, params);
    const due = await db.query(`${LIST_SELECT} WHERE ${scope} AND ${OPEN_SQL} AND l.next_at < $${t}::timestamptz + interval '1 day'
                                  ORDER BY l.next_at LIMIT 15`, params);
    // «الأحسن»: actions per salesman (all of them, like Engaz — everyone sees the ranking)
    const period = oneOf(Object.fromEntries(req.query), 'period', ['today', 'week', 'month', 'all'] as const, true) ?? 'month';
    const since = period === 'today' ? `date_trunc('day', $1::timestamptz AT TIME ZONE 'Africa/Cairo') AT TIME ZONE 'Africa/Cairo'`
      : period === 'week' ? `$1::timestamptz - interval '7 days'` : period === 'month' ? `date_trunc('month', $1::timestamptz AT TIME ZONE 'Africa/Cairo') AT TIME ZONE 'Africa/Cairo'` : `'-infinity'::timestamptz`;
    const best = await db.query(`
      SELECT e.id, e.full_name, count(x.id)::int AS actions,
             count(x.id) FILTER (WHERE x.stage IN ('meeting','after_meeting'))::int AS meetings
        FROM lead_actions x JOIN employees e ON e.id = x.by_id
       WHERE x.parent_id IS NULL AND NOT x.auto AND x.created_at >= ${since}
       GROUP BY e.id ORDER BY actions DESC LIMIT 10`, [now]);
    const tasks = await one(db, `SELECT count(*) FILTER (WHERE status IN ('open','doing'))::int AS open,
                                        count(*) FILTER (WHERE status IN ('open','doing') AND due_at < $2)::int AS late FROM tasks WHERE assigned_to = $1`, [a.id, now]);
    return ok({
      view, counts: c, stages: Object.fromEntries(stages.rows.map((x) => [x.stage, x.n])),
      delayByStage: Object.fromEntries(delay.rows.map((x) => [x.stage, x.n])),
      due: due.rows.map((l) => shape(l, now, pm)),
      best: best.rows.map((x, i) => ({ rank: i + 1, id: x.id, name: x.full_name, actions: x.actions, meetings: x.meetings, me: x.id === a.id })),
      period, tasks,
    });
  });

  // ------------------------------------------------------------------ reports
  r.get('/leads/reports', async (req) => {
    const a = await auth(req);
    if (!canAll(a) && !canTeam(a)) throw forbidden();
    const now = clock();
    const from = req.query.get('from') && /^\d{4}-\d{2}-\d{2}$/.test(req.query.get('from')!) ? req.query.get('from')! : `${now.toISOString().slice(0, 7)}-01`;
    const to = req.query.get('to') && /^\d{4}-\d{2}-\d{2}$/.test(req.query.get('to')!) ? req.query.get('to')! : now.toISOString().slice(0, 10);
    const people = await seenPeople(db, a);
    const F = `($1::date::timestamp AT TIME ZONE 'Africa/Cairo')`, T = `(($2::date + 1)::timestamp AT TIME ZONE 'Africa/Cairo')`;
    const P = [from, to, people, now];
    const K4 = `AND $4::timestamptz IS NOT NULL`;
    const inPeople = (col: string) => `($3::uuid[] IS NULL OR ${col} = ANY($3::uuid[]))`;
    const sales = await db.query(`
      SELECT e.id, e.full_name,
        (SELECT count(*) FROM lead_logs g WHERE g.kind = 'assign' AND (g.data->>'to')::uuid = e.id AND g.created_at >= ${F} AND g.created_at < ${T})::int AS assigned,
        (SELECT count(*) FROM lead_actions x WHERE x.by_id = e.id AND x.parent_id IS NULL AND NOT x.auto AND x.created_at >= ${F} AND x.created_at < ${T})::int AS actions,
        (SELECT count(*) FROM lead_actions x WHERE x.by_id = e.id AND x.answered AND NOT x.auto AND x.created_at >= ${F} AND x.created_at < ${T})::int AS answered,
        (SELECT count(*) FROM lead_actions x WHERE x.by_id = e.id AND x.stage = 'no_answer' AND x.created_at >= ${F} AND x.created_at < ${T})::int AS no_answer,
        (SELECT count(*) FROM lead_actions x WHERE x.by_id = e.id AND x.stage = 'meeting' AND x.created_at >= ${F} AND x.created_at < ${T})::int AS meetings,
        (SELECT count(*) FROM lead_actions x WHERE x.by_id = e.id AND x.stage = 'cancelled' AND x.created_at >= ${F} AND x.created_at < ${T})::int AS cancelled,
        (SELECT count(*) FROM ex_units u WHERE u.sales_id = e.id AND u.lead_id IS NOT NULL AND u.created_at >= ${F} AND u.created_at < ${T})::int AS reservations,
        (SELECT count(*) FROM ex_units u WHERE u.sales_id = e.id AND u.lead_id IS NOT NULL AND u.contracted_at >= ${F} AND u.contracted_at < ${T})::int AS deals,
        (SELECT COALESCE(sum(u.unit_price), 0) FROM ex_units u WHERE u.sales_id = e.id AND u.lead_id IS NOT NULL AND u.contracted_at >= ${F} AND u.contracted_at < ${T}) AS deals_value,
        (SELECT count(*) FROM leads l WHERE l.assigned_to = e.id AND ${OPEN_SQL} AND l.next_at < $4)::int AS overdue,
        (SELECT count(*) FROM leads l WHERE l.assigned_to = e.id AND ${OPEN_SQL})::int AS open_leads,
        (SELECT round(avg(extract(epoch FROM (fx.at - l.assigned_at)) / 60)) FROM leads l
           CROSS JOIN LATERAL (SELECT min(x.created_at) AS at FROM lead_actions x WHERE x.lead_id = l.id AND x.by_id = e.id AND x.created_at >= l.assigned_at) fx
          WHERE l.assigned_to = e.id AND l.assigned_at >= ${F} AND l.assigned_at < ${T} AND fx.at IS NOT NULL) AS first_response_min
        FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
       WHERE rp.perm_key = 'leads.own' AND e.status = 'active' AND ${inPeople('e.id')}
       ORDER BY e.full_name`, P);
    const scope = `${inPeople('l.assigned_to')}`;
    const channels = await db.query(`
      SELECT COALESCE(ch.name, 'بدون قناة') AS name, ch.id, count(*)::int AS leads,
             ${STAGES.map((s) => `count(*) FILTER (WHERE l.stage = '${s}')::int AS "${s}"`).join(', ')},
             (SELECT count(*) FROM ex_units u JOIN leads l2 ON l2.id = u.lead_id WHERE l2.channel_id IS NOT DISTINCT FROM ch.id AND u.status NOT IN ('cancelled')
                AND l2.created_at >= ${F} AND l2.created_at < ${T})::int AS reservations
        FROM leads l LEFT JOIN lead_channels ch ON ch.id = l.channel_id
       WHERE l.created_at >= ${F} AND l.created_at < ${T} AND ${scope}
       ${K4} GROUP BY ch.id, ch.name ORDER BY leads DESC`, P);
    const campaigns = await db.query(`
      SELECT c.id, c.name, c.cost, c.starts_on, c.ends_on, ch.name AS channel_name, p.name AS project_name,
             (SELECT count(*) FROM leads l WHERE l.campaign_id = c.id AND ${scope})::int AS leads,
             (SELECT count(*) FROM ex_units u JOIN leads l ON l.id = u.lead_id WHERE l.campaign_id = c.id AND u.status <> 'cancelled')::int AS reservations,
             (SELECT count(*) FROM ex_units u JOIN leads l ON l.id = u.lead_id WHERE l.campaign_id = c.id AND u.status IN ('contracted','completed'))::int AS deals,
             (SELECT COALESCE(sum(u.unit_price), 0) FROM ex_units u JOIN leads l ON l.id = u.lead_id WHERE l.campaign_id = c.id AND u.status IN ('contracted','completed')) AS sales_value,
             (SELECT COALESCE(sum(u.unit_price * u.total_pct / 100), 0) FROM ex_units u JOIN leads l ON l.id = u.lead_id WHERE l.campaign_id = c.id AND u.status IN ('contracted','completed')) AS commission
        FROM lead_campaigns c LEFT JOIN lead_channels ch ON ch.id = c.channel_id LEFT JOIN commission_projects p ON p.id = c.project_id
       WHERE (c.starts_on IS NULL OR c.starts_on <= $2::date) AND (c.ends_on IS NULL OR c.ends_on >= $1::date) ${K4}
         AND ($3::uuid[] IS NULL OR TRUE)
       ORDER BY c.created_at DESC`, P);
    const reasons = await db.query(`
      SELECT rs.name, count(*)::int AS n FROM leads l JOIN lead_cancel_reasons rs ON rs.id = l.cancel_reason_id
       WHERE l.stage = 'cancelled' AND l.stage_changed_at >= ${F} AND l.stage_changed_at < ${T} AND ${scope} ${K4}
       GROUP BY rs.name ORDER BY n DESC`, P);
    const funnel = await db.query(`SELECT l.stage, count(*)::int AS n FROM leads l WHERE l.created_at >= ${F} AND l.created_at < ${T} AND ${scope} ${K4} GROUP BY 1`, P);
    const delays = await db.query(`
      SELECT e.full_name, l.id, l.full_name AS lead_name, l.stage, l.next_at,
             round(extract(epoch FROM ($4::timestamptz - l.next_at)) / 3600) AS hours
        FROM leads l JOIN employees e ON e.id = l.assigned_to
       WHERE ${OPEN_SQL} AND l.next_at < $4 AND ${scope} AND $1::date IS NOT NULL AND $2::date IS NOT NULL
       ORDER BY l.next_at LIMIT 300`, P);
    return ok({
      from, to,
      sales: sales.rows.map((x) => ({ id: x.id, name: x.full_name, assigned: x.assigned, actions: x.actions, answered: x.answered, noAnswer: x.no_answer,
        meetings: x.meetings, cancelled: x.cancelled, reservations: x.reservations, deals: x.deals, dealsValue: n(x.deals_value),
        overdue: x.overdue, openLeads: x.open_leads, firstResponseMin: x.first_response_min == null ? null : n(x.first_response_min) })),
      channels: channels.rows.map((x) => ({ id: x.id, name: x.name, leads: x.leads, reservations: x.reservations,
        stages: Object.fromEntries(STAGES.map((s) => [s, x[s]])) })),
      campaigns: campaigns.rows.map((x) => {
        const cost = n(x.cost), leads = x.leads, deals = x.deals, commission = r2(n(x.commission));
        return { id: x.id, name: x.name, channelName: x.channel_name, projectName: x.project_name, startsOn: iso(x.starts_on)?.slice(0, 10) ?? null,
          endsOn: iso(x.ends_on)?.slice(0, 10) ?? null, cost, leads, reservations: x.reservations, deals, salesValue: n(x.sales_value), commission,
          cpl: leads ? r2(cost / leads) : null, cpa: deals ? r2(cost / deals) : null, roi: cost ? r2((commission - cost) / cost * 100) : null };
      }),
      cancelReasons: reasons.rows, funnel: Object.fromEntries(funnel.rows.map((x) => [x.stage, x.n])),
      delays: delays.rows.map((x) => ({ salesName: x.full_name, leadId: x.id, leadName: x.lead_name, stage: x.stage, stageAr: STAGE_AR[x.stage as Stage],
        nextAt: iso(x.next_at), hours: n(x.hours) })),
    });
  });

  // ------------------------------------------------------------------ settings: channels / campaigns / cancel reasons
  r.get('/leads/config', async (req) => {
    const a = await auth(req);
    if (!canConfig(a)) throw forbidden();
    const [channels, campaigns, reasons] = await Promise.all([
      db.query(`SELECT id, name, sort, active FROM lead_channels ORDER BY sort, name`),
      db.query(`SELECT c.*, ch.name AS channel_name, p.name AS project_name,
                       (SELECT count(*) FROM leads l WHERE l.campaign_id = c.id)::int AS leads
                  FROM lead_campaigns c LEFT JOIN lead_channels ch ON ch.id = c.channel_id LEFT JOIN commission_projects p ON p.id = c.project_id
                 ORDER BY c.active DESC, c.created_at DESC`),
      db.query(`SELECT id, name, sort, active FROM lead_cancel_reasons ORDER BY sort, name`),
    ]);
    return ok({
      channels: channels.rows, cancelReasons: reasons.rows, pendingMinutes: await pendingMinutes(db),
      campaigns: campaigns.rows.map((c) => ({ id: c.id, name: c.name, channelId: c.channel_id, channelName: c.channel_name, projectId: c.project_id,
        projectName: c.project_name, startsOn: iso(c.starts_on)?.slice(0, 10) ?? null, endsOn: iso(c.ends_on)?.slice(0, 10) ?? null,
        cost: n(c.cost), active: c.active, leads: c.leads })),
    });
  });

  const simpleList = (path: string, table: string, label: string) => {
    r.post(path, async (req) => {
      const a = await auth(req);
      if (!canConfig(a)) throw forbidden();
      const b = obj(req.body);
      const name = str(b, 'name', { min: 2, max: 80 })!;
      const sort = num(b, 'sort', { optional: true, min: 0, max: 10000, int: true }) ?? 100;
      if (await one(db, `SELECT 1 FROM ${table} WHERE lower(trim(name)) = lower(trim($1))`, [name])) throw conflict(`${label} ده موجود قبل كده`);
      const x = await one(db, `INSERT INTO ${table} (name, sort) VALUES ($1,$2) RETURNING *`, [name, sort]);
      await audit(db, a.id, `lead.config.${table}.create`, table, x.id, undefined, x);
      return ok({ item: x }, 201);
    });
    r.patch(`${path}/:id`, async (req) => {
      const a = await auth(req);
      if (!canConfig(a)) throw forbidden();
      if (!isUuid(req.params.id)) throw notFound();
      const b = obj(req.body);
      const old = await one(db, `SELECT * FROM ${table} WHERE id = $1`, [req.params.id]);
      if (!old) throw notFound();
      const name = b.name !== undefined ? str(b, 'name', { min: 2, max: 80 })! : old.name;
      if (name.toLowerCase() !== String(old.name).toLowerCase() && await one(db, `SELECT 1 FROM ${table} WHERE lower(trim(name)) = lower(trim($1)) AND id <> $2`, [name, old.id])) {
        throw conflict(`${label} ده موجود قبل كده`);
      }
      const x = await one(db, `UPDATE ${table} SET name = $2, sort = $3, active = $4 WHERE id = $1 RETURNING *`,
        [old.id, name, num(b, 'sort', { optional: true, min: 0, max: 10000, int: true }) ?? old.sort, bool(b, 'active') ?? old.active]);
      await audit(db, a.id, `lead.config.${table}.update`, table, old.id, old, x);
      return ok({ item: x });
    });
  };
  simpleList('/leads/channels', 'lead_channels', 'القناة');
  simpleList('/leads/cancel-reasons', 'lead_cancel_reasons', 'السبب');

  const readCampaign = async (q: Q, b: Record<string, unknown>, old?: any) => {
    const name = b.name !== undefined || !old ? str(b, 'name', { min: 2, max: 120 })! : old.name;
    const day = (k: string) => {
      const v = b[k];
      if (v === undefined) return old ? (iso(old[k === 'startsOn' ? 'starts_on' : 'ends_on'])?.slice(0, 10) ?? null) : null;
      if (v === null || v === '') return null;
      if (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(v)) throw invalid('التاريخ مش صحيح', { field: k });
      return v;
    };
    const startsOn = day('startsOn'), endsOn = day('endsOn');
    if (startsOn && endsOn && endsOn < startsOn) throw invalid('تاريخ النهاية قبل البداية', { field: 'endsOn' });
    return {
      name, startsOn, endsOn,
      cost: b.cost !== undefined ? num(b, 'cost', { optional: true, min: 0, max: 1_000_000_000 }) ?? 0 : n(old?.cost),
      channelId: b.channelId !== undefined ? await ref(q, 'lead_channels', b.channelId, 'channelId', 'اختار القناة') : old?.channel_id ?? null,
      projectId: b.projectId !== undefined ? await ref(q, 'commission_projects', b.projectId, 'projectId', 'اختار المشروع') : old?.project_id ?? null,
      active: bool(b, 'active') ?? old?.active ?? true,
    };
  };
  r.post('/leads/campaigns', async (req) => {
    const a = await auth(req);
    if (!canConfig(a)) throw forbidden();
    const c = await readCampaign(db, obj(req.body));
    const x = await one(db, `INSERT INTO lead_campaigns (name, channel_id, project_id, starts_on, ends_on, cost, active, created_by)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING *`, [c.name, c.channelId, c.projectId, c.startsOn, c.endsOn, c.cost, c.active, a.id]);
    await audit(db, a.id, 'lead.campaign.create', 'lead_campaign', x.id, undefined, x);
    return ok({ campaign: { id: x.id } }, 201);
  });
  r.patch('/leads/campaigns/:id', async (req) => {
    const a = await auth(req);
    if (!canConfig(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const old = await one(db, `SELECT * FROM lead_campaigns WHERE id = $1`, [req.params.id]);
    if (!old) throw notFound();
    const c = await readCampaign(db, obj(req.body), old);
    const x = await one(db, `UPDATE lead_campaigns SET name = $2, channel_id = $3, project_id = $4, starts_on = $5, ends_on = $6, cost = $7, active = $8
        WHERE id = $1 RETURNING *`, [old.id, c.name, c.channelId, c.projectId, c.startsOn, c.endsOn, c.cost, c.active]);
    await audit(db, a.id, 'lead.campaign.update', 'lead_campaign', old.id, old, x);
    return ok({ campaign: { id: x.id } });
  });
  r.patch('/leads/settings', async (req) => {
    const a = await auth(req);
    if (!canConfig(a)) throw forbidden();
    const m = num(obj(req.body), 'pendingMinutes', { min: 5, max: 1440, int: true })!;
    await db.query(`UPDATE company_settings SET lead_pending_minutes = $1`, [m]);
    await audit(db, a.id, 'lead.settings', 'company', null, undefined, { pendingMinutes: m });
    return ok({ pendingMinutes: m });
  });

  // (after the fixed paths /leads/dashboard, /leads/reports, /leads/config, /leads/settings: the router takes the first match)
  // ------------------------------------------------------------------ one lead
  r.get('/leads/:id', async (req) => {
    const a = await auth(req);
    if (!isUuid(req.params.id)) throw notFound();
    if (!await canSee(db, a, req.params.id)) throw notFound();
    const now = clock();
    const [l] = (await db.query(`${LIST_SELECT} WHERE l.id = $1`, [req.params.id])).rows;
    if (!l) throw notFound();
    // «مين فتح الليد»: once per person every 30 minutes
    if (!await one(db, `SELECT 1 FROM lead_logs WHERE lead_id = $1 AND kind = 'view' AND by_id = $2 AND created_at > $3::timestamptz - interval '30 minutes'`, [l.id, a.id, now])) {
      await log(db, l.id, 'view', a.id);
    }
    const manager = canAll(a) || canTeam(a);
    const [actions, logs, refs, units] = await Promise.all([
      db.query(`SELECT x.*, e.full_name AS by_name, rs.name AS reason_name, u.unit_no, u.status AS unit_status
                  FROM lead_actions x LEFT JOIN employees e ON e.id = x.by_id LEFT JOIN lead_cancel_reasons rs ON rs.id = x.cancel_reason_id
                  LEFT JOIN ex_units u ON u.id = x.ex_unit_id
                 WHERE x.lead_id = $1 ORDER BY x.created_at DESC`, [l.id]),
      manager ? db.query(`SELECT g.*, e.full_name AS by_name FROM lead_logs g LEFT JOIN employees e ON e.id = g.by_id
                           WHERE g.lead_id = $1 ORDER BY g.created_at DESC LIMIT 200`, [l.id]) : Promise.resolve({ rows: [] as any[] }),
      db.query(`SELECT rf.employee_id, e.full_name, rf.created_at FROM lead_referrals rf JOIN employees e ON e.id = rf.employee_id WHERE rf.lead_id = $1`, [l.id]),
      db.query(`SELECT u.id, u.unit_no, u.status, u.unit_price, u.deposit_amount, u.created_at, p.name AS project_name
                  FROM ex_units u JOIN commission_projects p ON p.id = u.project_id WHERE u.lead_id = $1 ORDER BY u.created_at DESC`, [l.id]),
    ]);
    const names = new Map<string, string>();
    const ids = [...new Set(logs.rows.flatMap((g) => [g.data?.to, g.data?.from].filter(Boolean)))];
    if (ids.length) for (const e of (await db.query(`SELECT id, full_name FROM employees WHERE id = ANY($1::uuid[])`, [ids])).rows) names.set(e.id, e.full_name);
    const top = actions.rows.filter((x) => !x.parent_id);
    const replies = actions.rows.filter((x) => x.parent_id);
    const act = (x: any) => ({
      id: x.id, stage: x.stage, stageAr: x.stage ? STAGE_AR[x.stage as Stage] : null, answered: x.answered, callSeconds: x.call_seconds,
      comment: x.comment, nextAt: iso(x.next_at), meetingKind: x.meeting_kind, meetingPlace: x.meeting_place,
      cancelReason: x.reason_name ?? null, unitNo: x.unit_no ?? null, auto: x.auto, byName: x.by_name ?? 'النظام', byId: x.by_id, at: iso(x.created_at),
    });
    const STATUS_AR: Record<string, string> = { reserving: 'مستني استلام العربون', reserved: 'محجوز', contract_pending: 'مستني موافقة التعاقد',
      contracted: 'متعاقد', completed: 'مكتمل', cancel_pending: 'مستني موافقة الإلغاء', cancelled: 'ملغي' };
    const work = await canWork(db, a, l);
    return ok({
      lead: shape(l, now, await pendingMinutes(db)),
      actions: top.map((x) => ({ ...act(x), replies: replies.filter((y) => y.parent_id === x.id).reverse().map(act) })),
      logs: logs.rows.map((g) => ({ kind: g.kind, byName: g.by_name ?? 'النظام', at: iso(g.created_at),
        data: { ...g.data, toName: g.data?.to ? names.get(g.data.to) : undefined, fromName: g.data?.from ? names.get(g.data.from) : undefined } })),
      referrals: refs.rows.map((x) => ({ id: x.employee_id, name: x.full_name, at: iso(x.created_at) })),
      units: units.rows.map((u) => ({ id: u.id, unitNo: u.unit_no, projectName: u.project_name, status: u.status, statusAr: STATUS_AR[u.status] ?? u.status,
        price: n(u.unit_price), deposit: n(u.deposit_amount), at: iso(u.created_at) })),
      can: { act: work, reserve: work && l.assigned_to != null && !CLOSED.includes(l.stage), edit: work || canDistribute(a),
        editPhone: canDistribute(a), editSource: canDistribute(a), assign: canDistribute(a) || (canTeam(a) && work),
        refer: work, log: manager, reply: true },
    });
  });

  r.patch('/leads/:id', async (req) => {
    const a = await auth(req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const now = clock();
    await db.tx(async (q) => {
      const l = await one(q, `SELECT * FROM leads WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!l || !await canSee(q, a, l.id)) throw notFound();
      if (!await canWork(q, a, l) && !canDistribute(a)) throw forbidden();
      const set: string[] = [], vals: unknown[] = [l.id], changed: string[] = [];
      const put = (col: string, v: unknown, key: string) => { vals.push(v); set.push(`${col} = $${vals.length}`); changed.push(key); };
      if (b.fullName !== undefined) put('full_name', str(b, 'fullName', { min: 2, max: 120 }), 'fullName');
      if (b.email !== undefined) put('email', (str(b, 'email', { optional: true, max: 160 }) ?? '').trim(), 'email');
      if (b.budget !== undefined) put('budget', num(b, 'budget', { optional: true, min: 0, max: 100_000_000_000 }) ?? null, 'budget');
      if (b.kind !== undefined) put('kind', oneOf(b, 'kind', ['fresh', 'cold'] as const), 'kind');
      if (b.notes !== undefined) put('notes', (str(b, 'notes', { optional: true, max: 2000 }) ?? '').trim(), 'notes');
      if (b.projectId !== undefined) put('project_id', await ref(q, 'commission_projects', b.projectId, 'projectId', 'اختار المشروع'), 'projectId');
      if (b.extraPhones !== undefined) {
        const extras = Array.isArray(b.extraPhones) ? b.extraPhones.filter((x): x is string => typeof x === 'string' && phoneNorm(x).length >= 7).slice(0, 5) : [];
        put('extra_phones', extras.map((x) => x.trim()), 'extraPhones');
      }
      if (b.phone !== undefined || b.channelId !== undefined || b.campaignId !== undefined) {
        if (!canDistribute(a)) throw forbidden('رقم العميل ومصدره بيعدّلهم موزّع الليدز بس');
        if (b.phone !== undefined) {
          const phone = str(b, 'phone', { min: 5, max: 30 })!;
          if (phoneNorm(phone).length < 7) throw invalid('رقم الموبايل مش صحيح', { field: 'phone' });
          put('phone', phone, 'phone'); vals.push(phoneNorm(phone)); set.push(`phone_norm = $${vals.length}`);
        }
        if (b.channelId !== undefined) put('channel_id', await ref(q, 'lead_channels', b.channelId, 'channelId', 'اختار القناة'), 'channelId');
        if (b.campaignId !== undefined) put('campaign_id', await ref(q, 'lead_campaigns', b.campaignId, 'campaignId', 'اختار الحملة'), 'campaignId');
      }
      if (!set.length) return;
      vals.push(now);
      await q.query(`UPDATE leads SET ${set.join(', ')}, updated_at = $${vals.length} WHERE id = $1`, vals);
      await log(q, l.id, 'edit', a.id, { fields: changed });
    });
    const [l] = (await db.query(`${LIST_SELECT} WHERE l.id = $1`, [req.params.id])).rows;
    return ok({ lead: shape(l, now, await pendingMinutes(db)) });
  });

  // ------------------------------------------------------------------ المهام
  const TASK_SELECT = `SELECT k.*, e.full_name AS assigned_name, c.full_name AS created_name, l.full_name AS lead_name
                         FROM tasks k JOIN employees e ON e.id = k.assigned_to JOIN employees c ON c.id = k.created_by LEFT JOIN leads l ON l.id = k.lead_id`;
  const shapeTask = (k: any, a: Actor, now: Date) => ({
    id: k.id, refNo: Number(k.ref_no), title: k.title, description: k.description, status: k.status,
    assignedTo: { id: k.assigned_to, name: k.assigned_name }, createdBy: { id: k.created_by, name: k.created_name },
    lead: k.lead_id ? { id: k.lead_id, name: k.lead_name } : null, dueAt: iso(k.due_at), doneAt: iso(k.done_at), createdAt: iso(k.created_at),
    late: !!(k.due_at && ['open', 'doing'].includes(k.status) && new Date(k.due_at) < now),
    can: { edit: k.created_by === a.id || canAll(a), status: k.assigned_to === a.id || k.created_by === a.id || canAll(a) },
  });
  const canGiveTasks = (a: Actor) => canAll(a) || canTeam(a) || has(a, 'employee.read_all');
  async function taskPeople(q: Q, a: Actor): Promise<any[]> {
    if (canAll(a) || has(a, 'employee.read_all')) return (await q.query(`SELECT id, full_name FROM employees WHERE status = 'active' ORDER BY full_name`)).rows;
    const ids = [a.id, ...(canTeam(a) ? await teamMemberIds(q, a.id) : [])];
    return (await q.query(`SELECT id, full_name FROM employees WHERE status = 'active' AND id = ANY($1::uuid[]) ORDER BY full_name`, [ids])).rows;
  }

  r.get('/tasks', async (req) => {
    const a = await authenticate(db, req);
    const now = clock();
    const view = req.query.get('view') ?? 'mine';
    const status = req.query.get('status') ?? 'open';
    const params: unknown[] = [a.id];
    const where: string[] = [];
    if (view === 'created') where.push(`k.created_by = $1`);
    else if (view === 'team' && canGiveTasks(a)) {
      if (canAll(a) || has(a, 'employee.read_all')) where.push(`TRUE`);
      else { params.push([a.id, ...await teamMemberIds(db, a.id)]); where.push(`(k.assigned_to = ANY($${params.length}::uuid[]) OR k.created_by = $1)`); }
    } else where.push(`k.assigned_to = $1`);
    if (status === 'open') where.push(`k.status IN ('open','doing')`);
    else if (status === 'done') where.push(`k.status IN ('done','cancelled')`);
    const leadId = req.query.get('leadId');
    if (leadId && isUuid(leadId)) { params.push(leadId); where.push(`k.lead_id = $${params.length}`); }
    const rows = await db.query(`${TASK_SELECT} WHERE ${where.join(' AND ')}
                                  ORDER BY (k.status IN ('open','doing')) DESC, k.due_at ASC NULLS LAST, k.created_at DESC LIMIT 300`, params);
    return ok({
      tasks: rows.rows.map((k) => shapeTask(k, a, now)),
      people: (await taskPeople(db, a)).map((e) => ({ id: e.id, name: e.full_name })),
      canAssignOthers: canGiveTasks(a),
    });
  });

  r.post('/tasks', async (req) => {
    const a = await authenticate(db, req);
    const b = obj(req.body);
    const now = clock();
    const title = str(b, 'title', { min: 2, max: 160 })!;
    const description = (str(b, 'description', { optional: true, max: 3000 }) ?? '').trim();
    const assignedTo = typeof b.assignedTo === 'string' && isUuid(b.assignedTo) ? b.assignedTo : a.id;
    const dueRaw = str(b, 'dueAt', { optional: true, max: 40 });
    const due = dueRaw ? new Date(dueRaw) : null;
    if (due && Number.isNaN(due.getTime())) throw invalid('المعاد مش صحيح', { field: 'dueAt' });
    const x = await db.tx(async (q) => {
      if (assignedTo !== a.id && !(await taskPeople(q, a)).some((e) => e.id === assignedTo)) throw invalid('مينفعش تدّي مهمة للموظف ده', { field: 'assignedTo' });
      const leadId = typeof b.leadId === 'string' && isUuid(b.leadId) ? b.leadId : null;
      if (leadId && !await canSee(q, a, leadId).catch(() => false)) throw invalid('الليد مش عندك', { field: 'leadId' });
      const k = await one(q, `INSERT INTO tasks (title, description, assigned_to, created_by, lead_id, due_at, created_at, updated_at)
          VALUES ($1,$2,$3,$4,$5,$6,$7,$7) RETURNING *`, [title, description, assignedTo, a.id, leadId, due, now]);
      if (assignedTo !== a.id) {
        await notify(q, { to: assignedTo, type: 'task_assigned', title: `مهمة جديدة: ${title}`, body: `من ${a.fullName}`,
          entity: 'task', entityId: k.id, dedupeKey: `task:${k.id}:new` });
      }
      return k;
    });
    return ok({ task: { id: x.id } }, 201);
  });

  r.patch('/tasks/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const now = clock();
    await db.tx(async (q) => {
      const k = await one(q, `SELECT * FROM tasks WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!k) throw notFound();
      const editor = k.created_by === a.id || canAll(a);
      const worker = k.assigned_to === a.id;
      if (!editor && !worker) throw notFound();
      const status = oneOf(b, 'status', ['open', 'doing', 'done', 'cancelled'] as const, true);
      if (status === 'cancelled' && !editor) throw forbidden('الإلغاء للي عمل المهمة');
      const set: string[] = [], vals: unknown[] = [k.id];
      const put = (col: string, v: unknown) => { vals.push(v); set.push(`${col} = $${vals.length}`); };
      if (status) { put('status', status); put('done_at', status === 'done' ? now : null); }
      if (editor) {
        if (b.title !== undefined) put('title', str(b, 'title', { min: 2, max: 160 }));
        if (b.description !== undefined) put('description', (str(b, 'description', { optional: true, max: 3000 }) ?? '').trim());
        if (b.dueAt !== undefined) {
          const d = b.dueAt ? new Date(String(b.dueAt)) : null;
          if (d && Number.isNaN(d.getTime())) throw invalid('المعاد مش صحيح', { field: 'dueAt' });
          put('due_at', d); put('reminded_at', null);
        }
        if (b.assignedTo !== undefined && b.assignedTo !== k.assigned_to) {
          const to = typeof b.assignedTo === 'string' && isUuid(b.assignedTo) ? b.assignedTo : '';
          if (!(await taskPeople(q, a)).some((e) => e.id === to)) throw invalid('مينفعش تدّي مهمة للموظف ده', { field: 'assignedTo' });
          put('assigned_to', to);
          await notify(q, { to, type: 'task_assigned', title: `مهمة جديدة: ${k.title}`, body: `من ${a.fullName}`, entity: 'task', entityId: k.id,
            dedupeKey: `task:${k.id}:to:${to}:${now.getTime()}` });
        }
      }
      if (!set.length) return;
      put('updated_at', now);
      await q.query(`UPDATE tasks SET ${set.join(', ')} WHERE id = $1`, vals);
      if (status === 'done' && k.created_by !== a.id) {
        await notify(q, { to: k.created_by, type: 'task_done', title: `خلصت المهمة: ${k.title}`, body: a.fullName, entity: 'task', entityId: k.id,
          dedupeKey: `task:${k.id}:done:${now.getTime()}` });
      }
    });
    const [k] = (await db.query(`${TASK_SELECT} WHERE k.id = $1`, [req.params.id])).rows;
    return ok({ task: shapeTask(k, a, now) });
  });
};

/**
 * Every minute (with the attendance reminders):
 *  - a follow-up whose time came rings its salesman («عندك متابعة مع …»)
 *  - a lead nobody acted on within lead_pending_minutes rings the salesman's manager (and whoever gave it)
 *  - a task whose time came rings its person
 */
export async function leadsSweep(q: Q, now: Date) {
  const due = await q.query(`
    SELECT l.id, l.full_name, l.stage, l.assigned_to, l.next_at FROM leads l
     WHERE ${OPEN_SQL} AND l.assigned_to IS NOT NULL AND l.next_at IS NOT NULL AND l.next_at <= $1
       AND (l.reminded_at IS NULL OR l.reminded_at < l.next_at)
     ORDER BY l.next_at LIMIT 300 FOR UPDATE OF l SKIP LOCKED`, [now]);
  for (const l of due.rows) {
    await q.query(`UPDATE leads SET reminded_at = $2 WHERE id = $1`, [l.id, now]);
    await notify(q, { to: l.assigned_to, type: 'lead_due', title: `عندك ${STAGE_AR[l.stage as Stage] ?? 'متابعة'} مع ${l.full_name} ⏰`,
      body: 'افتح العميل وسجّل الأكشن', entity: 'lead', entityId: l.id, dedupeKey: `lead:${l.id}:due:${new Date(l.next_at).getTime()}` });
  }
  const pending = await q.query(`
    SELECT l.id, l.full_name, l.assigned_to, l.assigned_by, e.full_name AS sales_name, ${SM_OF} AS manager_id
      FROM leads l JOIN employees e ON e.id = l.assigned_to LEFT JOIN teams t ON t.id = e.team_id
     WHERE ${OPEN_SQL} AND l.pending_alerted_at IS NULL AND (l.last_action_at IS NULL OR l.last_action_at < l.assigned_at)
       AND l.assigned_at <= $1::timestamptz - make_interval(mins => (SELECT lead_pending_minutes FROM company_settings LIMIT 1))
     LIMIT 300 FOR UPDATE OF l SKIP LOCKED`, [now]);
  for (const l of pending.rows) {
    await q.query(`UPDATE leads SET pending_alerted_at = $2 WHERE id = $1`, [l.id, now]);
    for (const to of new Set([l.manager_id, l.assigned_by].filter((v) => v && v !== l.assigned_to))) {
      await notify(q, { to, type: 'lead_pending', title: `${l.sales_name} لسه ماكلّمش ${l.full_name}`, body: 'الليد اتوزع ومحدش عمل عليه أكشن',
        entity: 'lead', entityId: l.id, dedupeKey: `lead:${l.id}:pending:${to}` });
    }
  }
  const tasks = await q.query(`SELECT id, title, assigned_to, due_at FROM tasks WHERE status IN ('open','doing') AND due_at IS NOT NULL AND due_at <= $1
                                  AND reminded_at IS NULL LIMIT 300 FOR UPDATE SKIP LOCKED`, [now]);
  for (const k of tasks.rows) {
    await q.query(`UPDATE tasks SET reminded_at = $2 WHERE id = $1`, [k.id, now]);
    await notify(q, { to: k.assigned_to, type: 'task_due', title: `معاد المهمة: ${k.title} ⏰`, entity: 'task', entityId: k.id, dedupeKey: `task:${k.id}:due` });
  }
}

/**
 * The reservation side tells the lead: «حجز» made from it (the deposit still to be received), the deposit received,
 * the contract approved (تم البيع), the reservation cancelled (back to متابعة).
 */
export async function leadFromUnit(q: Q, unitId: string, event: 'reserved' | 'deposit' | 'contract' | 'cancel', byId: string | null, now: Date) {
  const u = await one(q, `SELECT u.*, p.name AS project_name FROM ex_units u JOIN commission_projects p ON p.id = u.project_id WHERE u.id = $1`, [unitId]);
  if (!u?.lead_id) return;
  const l = await one(q, `SELECT * FROM leads WHERE id = $1 FOR UPDATE`, [u.lead_id]);
  if (!l) return;
  const text = {
    reserved: `حجز وحدة ${u.unit_no} — ${u.project_name}${u.status === 'reserving' ? ' — مستني تأكيد استلام العربون' : ''}`,
    deposit: `اتأكد استلام عربون حجز وحدة ${u.unit_no} ✅`,
    contract: `تم التعاقد على وحدة ${u.unit_no} — ${u.project_name} 🎉`,
    cancel: `اتلغى حجز وحدة ${u.unit_no}`,
  }[event];
  const stage: Stage = event === 'contract' ? 'done_deal' : event === 'cancel' ? 'following' : 'reservation';
  const next = event === 'cancel' ? new Date(now.getTime() + 24 * 3600_000) : null;
  await q.query(`INSERT INTO lead_actions (lead_id, stage, answered, comment, next_at, ex_unit_id, auto, by_id, created_at) VALUES ($1,$2,true,$3,$4,$5,true,$6,$7)`,
    [l.id, stage, text, next, u.id, byId, now]);
  await q.query(`UPDATE leads SET stage = $2, stage_changed_at = CASE WHEN stage = $2 THEN stage_changed_at ELSE $3 END, next_at = $4, reminded_at = NULL,
      last_action_at = $3, last_action_by = COALESCE($5, last_action_by), last_comment = $6, updated_at = $3 WHERE id = $1`,
    [l.id, stage, now, next, byId, text]);
}

/** the reservation form asks for a lead: may this person reserve for it? (its salesman / his manager / the distributor) */
export async function leadForReservation(q: Q, a: Actor, leadId: string) {
  const l = await one(q, `SELECT * FROM leads WHERE id = $1 FOR UPDATE`, [leadId]);
  if (!l || !await canSee(q, a, l.id)) throw invalid('الليد مش عندك', { field: 'leadId' });
  if (!await canWork(q, a, l)) throw forbidden('الحجز لسيلز العميل');
  if (l.stage === 'done_deal') throw conflict('العميل ده اتباعله خلاص');
  return l;
}
