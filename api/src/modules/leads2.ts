import { randomBytes } from 'node:crypto';
import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { bool, isUuid, num, obj, oneOf, str } from '../http/validate.ts';
import { audit, authenticate, has, teamMemberIds, type Actor } from '../auth/context.ts';
import type { Req } from '../http/router.ts';
import { notify } from './notify.ts';
import {
  anyLeads, assignable, canAll, canConfig, canDistribute, canSee, canTeam, canWork, insertLead, log, OPEN_SQL, phoneNorm, readLead, ref,
  rotation, scopeSql, STAGE_AR, type Stage,
} from './leads.ts';

/**
 * نظام الليدز — المرحلة التانية (see db/migrations/056_leads_phase2.sql): the calendar, the bulk edit, the files, the client's
 * request and the matching units, the meeting check-in, the WhatsApp templates, the monthly targets, more reports, the export log,
 * the public form of a campaign and the automatic pull.
 * Registered before leadsModule: its fixed paths (/leads/calendar …) must win over /leads/:id.
 */
const MAX_FILE = 3_000_000;
const n = (v: unknown) => Number(v ?? 0);
const r2 = (v: number) => Math.round(v * 100) / 100;
const iso = (v: unknown) => (v == null ? null : v instanceof Date ? v.toISOString() : String(v));
const dayRe = /^\d{4}-\d{2}-\d{2}$/;
const monthRe = /^\d{4}-\d{2}$/;
const F = (i: number) => `($${i}::date::timestamp AT TIME ZONE 'Africa/Cairo')`;
const T = (i: number) => `(($${i}::date + 1)::timestamp AT TIME ZONE 'Africa/Cairo')`;

/** the people whose work the actor follows (calendar / targets / reports): everyone (null) or a list */
async function people(q: Q, a: Actor): Promise<string[] | null> {
  if (canAll(a)) return null;
  return [a.id, ...(canTeam(a) ? await teamMemberIds(q, a.id) : [])];
}

/** this month's numbers of a salesman (and the targets set for him) */
async function progress(q: Q, ids: string[] | null, month: string) {
  const r = await q.query(`
    SELECT e.id, e.full_name,
      (SELECT count(*) FROM lead_actions x WHERE x.by_id = e.id AND x.parent_id IS NULL AND NOT x.auto AND x.created_at >= ${F(1)} AND x.created_at < ${T(2)})::int AS calls,
      (SELECT count(*) FROM lead_actions x WHERE x.by_id = e.id AND x.stage = 'meeting' AND x.created_at >= ${F(1)} AND x.created_at < ${T(2)})::int AS meetings,
      (SELECT count(*) FROM ex_units u WHERE u.sales_id = e.id AND u.created_at >= ${F(1)} AND u.created_at < ${T(2)} AND u.status <> 'cancelled')::int AS reservations,
      (SELECT count(*) FROM ex_units u WHERE u.sales_id = e.id AND u.contracted_at >= ${F(1)} AND u.contracted_at < ${T(2)})::int AS deals,
      (SELECT COALESCE(sum(u.unit_price), 0) FROM ex_units u WHERE u.sales_id = e.id AND u.contracted_at >= ${F(1)} AND u.contracted_at < ${T(2)}) AS deals_value,
      t.calls AS t_calls, t.meetings AS t_meetings, t.reservations AS t_reservations, t.deals AS t_deals, t.deals_value AS t_deals_value
      FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
      LEFT JOIN lead_targets t ON t.employee_id = e.id AND t.month = $1::date
     WHERE rp.perm_key = 'leads.own' AND e.status = 'active' AND ($3::uuid[] IS NULL OR e.id = ANY($3::uuid[]))
     ORDER BY e.full_name`, [`${month}-01`, endOfMonth(month), ids]);
  const pct = (a: number, t: unknown) => (n(t) > 0 ? Math.round(a * 100 / n(t)) : null);
  return r.rows.map((x) => ({
    id: x.id, name: x.full_name,
    actual: { calls: x.calls, meetings: x.meetings, reservations: x.reservations, deals: x.deals, dealsValue: n(x.deals_value) },
    target: x.t_calls == null ? null : { calls: x.t_calls, meetings: x.t_meetings, reservations: x.t_reservations, deals: x.t_deals, dealsValue: n(x.t_deals_value) },
    pct: x.t_calls == null ? null : {
      calls: pct(x.calls, x.t_calls), meetings: pct(x.meetings, x.t_meetings), reservations: pct(x.reservations, x.t_reservations),
      deals: pct(x.deals, x.t_deals), dealsValue: pct(n(x.deals_value), x.t_deals_value),
    },
  }));
}

function endOfMonth(month: string): string {
  const [y, m] = month.split('-').map(Number);
  const d = new Date(Date.UTC(y, m, 0));
  return d.toISOString().slice(0, 10);
}

function monthOf(v: string | null, now: Date): string {
  return v && monthRe.test(v) ? v : new Date(now.getTime() + 2 * 3600_000).toISOString().slice(0, 7);
}

/** the HTML of the public form (served by the API: nothing to host) */
function formPage(title: string, sub: string, token: string, done = false) {
  const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
  return `<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title><style>
body{margin:0;font-family:system-ui,-apple-system,"Segoe UI",Tahoma,sans-serif;background:linear-gradient(160deg,#1d1d1f,#3a2414);min-height:100vh;display:flex;align-items:center;justify-content:center;color:#222}
.card{background:#fff;border-radius:22px;padding:28px 22px;width:min(420px,92vw);box-shadow:0 20px 60px rgba(0,0,0,.35)}
h1{margin:0 0 6px;font-size:22px}p{margin:0 0 18px;color:#666;line-height:1.6}
label{display:block;font-weight:700;margin:12px 0 6px}input,textarea{width:100%;box-sizing:border-box;border:1.5px solid #ddd;border-radius:12px;padding:12px;font-size:16px;font-family:inherit}
input:focus,textarea:focus{outline:none;border-color:#f26a1b}button{margin-top:18px;width:100%;background:#f26a1b;color:#fff;border:0;border-radius:14px;padding:14px;font-size:17px;font-weight:800;cursor:pointer}
.hp{position:absolute;left:-5000px}.ok{text-align:center;font-size:18px;line-height:1.8}.err{color:#c62828;margin-top:10px;display:none}
</style></head><body><div class="card">${done ? `<div class="ok">✅<br>شكراً! هنتواصل مع حضرتك قريب.</div>` : `
<h1>${esc(title)}</h1><p>${esc(sub)}</p>
<form id="f"><label>الاسم</label><input name="fullName" required minlength="2" maxlength="120" autocomplete="name">
<label>رقم الموبايل</label><input name="phone" required inputmode="tel" minlength="7" maxlength="30" autocomplete="tel">
<label>ملاحظات (اختياري)</label><textarea name="notes" rows="3" maxlength="500"></textarea>
<input class="hp" name="website" tabindex="-1" autocomplete="off"><button>ابعت</button><div class="err" id="e"></div></form>
<script>document.getElementById('f').addEventListener('submit',async function(ev){ev.preventDefault();var b=this.querySelector('button');b.disabled=true;
var d=Object.fromEntries(new FormData(this));try{var r=await fetch(location.pathname.replace('/f/','/public/leads/'),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(d)});
if(r.ok){document.querySelector('.card').innerHTML='<div class="ok">✅<br>شكراً! هنتواصل مع حضرتك قريب.</div>';return}
var j=await r.json().catch(function(){return{}});var e=document.getElementById('e');e.textContent=(j.error&&j.error.message)||'حصلت مشكلة، جرّب تاني';e.style.display='block'}catch(x){}
b.disabled=false})</script>`}</div></body></html>`;
}

export const leadsExtraModule: Module = (r, { db, clock }) => {
  const auth = async (req: Req) => {
    const a = await authenticate(db, req);
    if (!anyLeads(a)) throw forbidden();
    return a;
  };

  // ------------------------------------------------------------------ the calendar: follow-ups / meetings + tasks
  r.get('/leads/calendar', async (req) => {
    const a = await auth(req);
    const from = req.query.get('from'), to = req.query.get('to');
    if (!from || !to || !dayRe.test(from) || !dayRe.test(to)) throw invalid('حدد الفترة', { field: 'from' });
    if ((Date.parse(to) - Date.parse(from)) / 86_400_000 > 62) throw invalid('الفترة طويلة', { field: 'to' });
    const now = clock();
    const view = req.query.get('view') ?? 'me';
    const who = req.query.get('employeeId');
    const params: unknown[] = [from, to];
    let scope = await scopeSql(db, a, params);
    if (view === 'me') { params.push(a.id); scope += ` AND l.assigned_to = $${params.length}`; }
    else if (who && isUuid(who)) { params.push(who); scope += ` AND l.assigned_to = $${params.length}`; }
    const leads = await db.query(`
      SELECT l.id, l.full_name, l.phone, l.stage, l.next_at, e.full_name AS assigned_name, p.name AS project_name
        FROM leads l LEFT JOIN employees e ON e.id = l.assigned_to LEFT JOIN commission_projects p ON p.id = l.project_id
       WHERE ${scope} AND ${OPEN_SQL} AND l.next_at >= ${F(1)} AND l.next_at < ${T(2)} ORDER BY l.next_at LIMIT 1500`, params);
    const ppl = view === 'me' ? [a.id] : who && isUuid(who) ? [who] : await people(db, a);
    const tasks = await db.query(`
      SELECT k.id, k.title, k.due_at, k.status, e.full_name AS assigned_name, k.lead_id FROM tasks k JOIN employees e ON e.id = k.assigned_to
       WHERE k.status IN ('open','doing') AND k.due_at >= ${F(1)} AND k.due_at < ${T(2)} AND ($3::uuid[] IS NULL OR k.assigned_to = ANY($3::uuid[]))
       ORDER BY k.due_at LIMIT 500`, [from, to, ppl]);
    return ok({
      from, to,
      items: [
        ...leads.rows.map((l) => ({ kind: 'lead', id: l.id, title: l.full_name, phone: l.phone, stage: l.stage, stageAr: STAGE_AR[l.stage as Stage],
          at: iso(l.next_at), who: l.assigned_name, project: l.project_name, overdue: new Date(l.next_at) < now })),
        ...tasks.rows.map((k) => ({ kind: 'task', id: k.id, title: k.title, at: iso(k.due_at), who: k.assigned_name, status: k.status, leadId: k.lead_id,
          overdue: new Date(k.due_at) < now })),
      ].sort((x, y) => String(x.at).localeCompare(String(y.at))),
    });
  });

  // ------------------------------------------------------------------ تعديل جماعي
  r.post('/leads/bulk', async (req) => {
    const a = await auth(req);
    if (!canDistribute(a) && !canTeam(a)) throw forbidden();
    const b = obj(req.body);
    const ids = Array.isArray(b.ids) ? [...new Set(b.ids.filter((x): x is string => typeof x === 'string' && isUuid(x)))] : [];
    if (!ids.length) throw invalid('اختار الليدز', { field: 'ids' });
    if (ids.length > 1000) throw invalid('أقصى 1000 ليد في المرة', { field: 'ids' });
    const now = clock();
    const count = await db.tx(async (q) => {
      const params: unknown[] = [ids];
      const s = await scopeSql(q, a, params);
      const leads = (await q.query(`SELECT l.id FROM leads l WHERE l.id = ANY($1::uuid[]) AND ${s} FOR UPDATE OF l`, params)).rows;
      if (leads.length !== ids.length) throw notFound('في ليدز مش عندك');
      const set: string[] = [], vals: unknown[] = [ids], fields: string[] = [];
      const put = (col: string, v: unknown, key: string) => { vals.push(v); set.push(`${col} = $${vals.length}`); fields.push(key); };
      if (b.projectId !== undefined && b.projectId !== null) put('project_id', await ref(q, 'commission_projects', b.projectId, 'projectId', 'اختار المشروع'), 'projectId');
      if (b.kind !== undefined && b.kind !== null) put('kind', oneOf(b, 'kind', ['fresh', 'cold'] as const), 'kind');
      if (b.rating !== undefined) put('rating', b.rating === null || b.rating === '' ? null : oneOf(b, 'rating', ['hot', 'warm', 'cold'] as const), 'rating');
      if (b.channelId !== undefined || b.campaignId !== undefined) {
        if (!canDistribute(a)) throw forbidden('مصدر العميل بيعدّله موزّع الليدز بس');
        if (b.channelId !== undefined) put('channel_id', await ref(q, 'lead_channels', b.channelId, 'channelId', 'اختار القناة'), 'channelId');
        if (b.campaignId !== undefined) put('campaign_id', await ref(q, 'lead_campaigns', b.campaignId, 'campaignId', 'اختار الحملة'), 'campaignId');
      }
      if (!set.length) throw invalid('اختار اللي عايز تغيّره', { field: 'projectId' });
      vals.push(now);
      await q.query(`UPDATE leads SET ${set.join(', ')}, updated_at = $${vals.length} WHERE id = ANY($1::uuid[])`, vals);
      for (const l of leads) await log(q, l.id, 'bulk', a.id, { fields });
      await audit(q, a.id, 'lead.bulk', 'lead', null, undefined, { count: leads.length, fields });
      return leads.length;
    });
    return ok({ updated: count });
  });

  // ------------------------------------------------------------------ the lead's extras: files, request + matching units, check-ins
  const workLead = async (q: Q, a: Actor, id: string, must: 'see' | 'work') => {
    if (!isUuid(id)) throw notFound();
    const l = await one(q, `SELECT * FROM leads WHERE id = $1`, [id]);
    if (!l || !await canSee(q, a, l.id)) throw notFound();
    if (must === 'work' && !await canWork(q, a, l) && !canDistribute(a)) throw forbidden();
    return l;
  };

  async function matches(q: Q, req: any, limit = 30) {
    if (!req) return [];
    const rows = await q.query(`
      SELECT i.id, i.unit_no, i.unit_type, i.floor, i.area_m2, i.net_area_m2, i.meter_price,
             COALESCE(i.unit_price, i.area_m2 * i.meter_price) AS price, p.id AS project_id, p.name AS project_name
        FROM ex_inventory i JOIN commission_projects p ON p.id = i.project_id
       WHERE i.active AND p.status = 'active'
         AND NOT EXISTS (SELECT 1 FROM ex_units d WHERE d.status <> 'cancelled' AND (d.inventory_id = i.id
               OR (d.project_id = i.project_id AND lower(trim(d.unit_no)) = lower(trim(i.unit_no)))))
         AND ($1::uuid IS NULL OR i.project_id = $1)
         AND ($2 = '' OR i.unit_type ILIKE '%' || $2 || '%')
         AND ($3 = '' OR i.floor ILIKE '%' || $3 || '%')
         AND ($4::numeric IS NULL OR COALESCE(i.area_m2, i.net_area_m2) >= $4)
         AND ($5::numeric IS NULL OR COALESCE(i.area_m2, i.net_area_m2) <= $5)
         AND ($6::numeric IS NULL OR COALESCE(i.unit_price, i.area_m2 * i.meter_price) <= $6)
       ORDER BY COALESCE(i.unit_price, i.area_m2 * i.meter_price) NULLS LAST LIMIT ${limit}`,
      [req.project_id, req.unit_type ?? '', req.floor ?? '', req.min_area, req.max_area, req.max_price]);
    return rows.rows.map((u) => ({ id: u.id, unitNo: u.unit_no, unitType: u.unit_type, floor: u.floor, area: u.area_m2 == null ? null : n(u.area_m2),
      netArea: u.net_area_m2 == null ? null : n(u.net_area_m2), meterPrice: u.meter_price == null ? null : n(u.meter_price),
      price: u.price == null ? null : r2(n(u.price)), projectId: u.project_id, projectName: u.project_name }));
  }

  r.get('/leads/:id/extra', async (req) => {
    const a = await auth(req);
    const l = await workLead(db, a, req.params.id, 'see');
    const [files, rq, checkins] = await Promise.all([
      db.query(`SELECT f.id, f.file_name, f.mime, f.size_bytes, f.created_at, e.full_name AS by_name
                  FROM lead_attachments f LEFT JOIN employees e ON e.id = f.by_id WHERE f.lead_id = $1 ORDER BY f.created_at DESC`, [l.id]),
      one(db, `SELECT r.*, p.name AS project_name FROM lead_requests r LEFT JOIN commission_projects p ON p.id = r.project_id WHERE r.lead_id = $1`, [l.id]),
      db.query(`SELECT c.*, e.full_name FROM lead_checkins c JOIN employees e ON e.id = c.employee_id WHERE c.lead_id = $1 ORDER BY c.created_at DESC`, [l.id]),
    ]);
    return ok({
      attachments: files.rows.map((f) => ({ id: f.id, fileName: f.file_name, mime: f.mime, size: f.size_bytes, at: iso(f.created_at), byName: f.by_name })),
      request: rq ? { projectId: rq.project_id, projectName: rq.project_name, unitType: rq.unit_type, floor: rq.floor,
        minArea: rq.min_area == null ? null : n(rq.min_area), maxArea: rq.max_area == null ? null : n(rq.max_area),
        maxPrice: rq.max_price == null ? null : n(rq.max_price), payment: rq.payment, notes: rq.notes } : null,
      matches: await matches(db, rq),
      checkins: checkins.rows.map((c) => ({ id: c.id, name: c.full_name, lat: c.lat, lng: c.lng, accuracy: c.accuracy_m, note: c.note, at: iso(c.created_at) })),
    });
  });

  r.post('/leads/:id/attachments', async (req) => {
    const a = await auth(req);
    const b = obj(req.body);
    const now = clock();
    const l = await workLead(db, a, req.params.id, 'work');
    const fileName = str(b, 'fileName', { min: 1, max: 160 })!;
    const raw = String(b.data ?? '');
    const buf = Buffer.from(raw, 'base64');
    if (!raw || buf.length < 10) throw invalid('الملف فاضي', { field: 'data' });
    if (buf.length > MAX_FILE) throw invalid('الملف أكبر من 3 ميجا — صغّره وجرّب تاني', { field: 'data' });
    const mime = (str(b, 'mime', { optional: true, max: 120 }) ?? 'application/octet-stream').trim();
    const x = await db.tx(async (q) => {
      const f = await one(q, `INSERT INTO lead_attachments (lead_id, file_name, mime, size_bytes, data, by_id, created_at) VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
        [l.id, fileName, mime, buf.length, buf, a.id, now]);
      await log(q, l.id, 'attachment', a.id, { fileName });
      return f;
    });
    return ok({ attachment: { id: x.id } }, 201);
  });

  r.get('/leads/attachments/:aid', async (req) => {
    const a = await auth(req);
    if (!isUuid(req.params.aid)) throw notFound();
    const f = await one(db, `SELECT * FROM lead_attachments WHERE id = $1`, [req.params.aid]);
    if (!f || !await canSee(db, a, f.lead_id)) throw notFound();
    return ok({ fileName: f.file_name, mime: f.mime, data: Buffer.from(f.data).toString('base64') });
  });

  r.post('/leads/attachments/:aid/delete', async (req) => {
    const a = await auth(req);
    if (!isUuid(req.params.aid)) throw notFound();
    const f = await one(db, `SELECT id, lead_id, by_id, file_name FROM lead_attachments WHERE id = $1`, [req.params.aid]);
    if (!f || !await canSee(db, a, f.lead_id)) throw notFound();
    if (f.by_id !== a.id && !canDistribute(a)) throw forbidden('بيمسحه اللي رفعه');
    await db.tx(async (q) => {
      await q.query(`DELETE FROM lead_attachments WHERE id = $1`, [f.id]);
      await log(q, f.lead_id, 'attachment', a.id, { deleted: f.file_name });
    });
    return ok({ ok: true });
  });

  // ------------------------------------------------------------------ الإعدادات / التحكم في الوصول / صلاحيات الأدوار
  // (like Elite) the owner gives each role the sales-board permissions, then exceptions per employee on top.
  const LEAD_PERMS: { key: string; ar: string; group: string }[] = [
    { key: 'leads.own', ar: 'يشتغل على ليدز (سيلز)', group: 'العملاء' },
    { key: 'leads.team', ar: 'يشوف ليدز فريقه', group: 'العملاء' },
    { key: 'leads.read_all', ar: 'يشوف كل الليدز', group: 'العملاء' },
    { key: 'leads.create', ar: 'إضافة العملاء المحتملين', group: 'العملاء' },
    { key: 'leads.edit', ar: 'تعديل بيانات العميل', group: 'العملاء' },
    { key: 'leads.distribute', ar: 'توزيع وإعادة إسناد الليدز', group: 'العملاء' },
    { key: 'leads.import', ar: 'استيراد الليدز', group: 'البيانات' },
    { key: 'leads.export', ar: 'تصدير إكسيل', group: 'البيانات' },
    { key: 'leads.reports', ar: 'عرض التقارير', group: 'البيانات' },
    { key: 'leads.tasks', ar: 'إضافة مهام لغيره', group: 'المهام' },
    { key: 'leads.config', ar: 'إعدادات الليدز (القنوات، الحملات، أسباب الإلغاء، القوالب)', group: 'الإعدادات' },
  ];
  const leadPerm = (k: unknown) => {
    const p = LEAD_PERMS.find((x) => x.key === k);
    if (!p) throw invalid('صلاحية مش معروفة', { field: 'perm' });
    return p.key;
  };
  r.get('/leads/permissions', async (req) => {
    const a = await auth(req);
    if (!has(a, 'roles.manage')) throw forbidden('صلاحيات الأدوار للمالك بس');
    const roles = await db.query(`SELECT key, name_ar, name_en, rank, builtin, base_key FROM roles WHERE key <> 'owner' ORDER BY rank DESC, name_ar`);
    const grants = await db.query(`SELECT role_key, perm_key FROM role_permissions WHERE perm_key LIKE 'leads.%'`);
    const people = await db.query(`
      SELECT e.id, e.full_name, e.code, COALESCE(p.name_ar, r.name_ar) AS role_name, COALESCE(e.position_key, e.role_key) AS role_key
        FROM employees e JOIN roles r ON r.key = e.role_key LEFT JOIN roles p ON p.key = e.position_key
       WHERE e.status = 'active' AND e.role_key <> 'owner' AND COALESCE(e.legacy_fields->>'status', '') <> 'تم التصفيه'
       ORDER BY e.full_name`);
    const ov = await db.query(`SELECT employee_id, perm_key, allow FROM employee_permissions WHERE perm_key LIKE 'leads.%'`);
    const byRole: Record<string, string[]> = {};
    for (const g of grants.rows) (byRole[g.role_key] ??= []).push(g.perm_key);
    const byEmp: Record<string, Record<string, boolean>> = {};
    for (const o of ov.rows) (byEmp[o.employee_id] ??= {})[o.perm_key] = o.allow;
    return ok({
      perms: LEAD_PERMS,
      roles: roles.rows.map((x) => ({ key: x.key, name: x.name_ar, builtin: x.builtin, base: x.base_key, perms: byRole[x.key] ?? [] })),
      employees: people.rows.map((x) => ({ id: x.id, name: x.full_name, code: x.code, role: x.role_name, roleKey: x.role_key, overrides: byEmp[x.id] ?? {} })),
    });
  });
  r.put('/leads/permissions/role', async (req) => {
    const a = await auth(req);
    if (!has(a, 'roles.manage')) throw forbidden('صلاحيات الأدوار للمالك بس');
    const b = obj(req.body);
    const perm = leadPerm(b.perm);
    const on = bool(b, 'on', false)!;
    const role = await one(db, `SELECT key FROM roles WHERE key = $1`, [str(b, 'role', { min: 1, max: 60 })]);
    if (!role) throw notFound('الدور مش موجود');
    if (role.key === 'owner') throw forbidden('المالك عنده كل الصلاحيات دايمًا');
    if (on) await db.query(`INSERT INTO role_permissions (role_key, perm_key) VALUES ($1,$2) ON CONFLICT DO NOTHING`, [role.key, perm]);
    else await db.query(`DELETE FROM role_permissions WHERE role_key = $1 AND perm_key = $2`, [role.key, perm]);
    await audit(db, a.id, 'leads.role_permission', 'role', role.key, undefined, { perm, on });
    return ok({ ok: true });
  });
  r.put('/leads/permissions/employee', async (req) => {
    const a = await auth(req);
    if (!has(a, 'roles.manage')) throw forbidden('صلاحيات المستخدمين للمالك بس');
    const b = obj(req.body);
    const perm = leadPerm(b.perm);
    const value = oneOf(b, 'value', ['allow', 'deny', 'inherit'] as const)!;
    const id = str(b, 'employeeId', { min: 36, max: 36 })!;
    if (!isUuid(id)) throw notFound();
    const e = await one(db, `SELECT id, role_key FROM employees WHERE id = $1`, [id]);
    if (!e) throw notFound('الموظف مش موجود');
    if (e.role_key === 'owner') throw forbidden('المالك عنده كل الصلاحيات دايمًا');
    if (value === 'inherit') await db.query(`DELETE FROM employee_permissions WHERE employee_id = $1 AND perm_key = $2`, [id, perm]);
    else await db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow, by_id, updated_at) VALUES ($1,$2,$3,$4,$5)
                           ON CONFLICT (employee_id, perm_key) DO UPDATE SET allow = EXCLUDED.allow, by_id = EXCLUDED.by_id, updated_at = EXCLUDED.updated_at`,
      [id, perm, value === 'allow', a.id, clock()]);
    await audit(db, a.id, 'leads.employee_permission', 'employee', id, undefined, { perm, value });
    return ok({ ok: true });
  });

  // «اتصال» / «واتساب» tapped on a lead: counted on the sales board (Phone Call / WhatsApp Contacts)
  r.post('/leads/:id/contact', async (req) => {
    const a = await auth(req);
    if (!isUuid(req.params.id)) throw notFound();
    const via = oneOf(obj(req.body), 'via', ['call', 'whatsapp'] as const)!;
    if (!await canSee(db, a, req.params.id)) throw notFound();
    await db.query(`INSERT INTO lead_logs (lead_id, kind, by_id, created_at) VALUES ($1,$2,$3,$4)`, [req.params.id, via, a.id, clock()]);
    return ok({ ok: true });
  });

  r.post('/leads/:id/request', async (req) => {
    const a = await auth(req);
    const b = obj(req.body);
    const now = clock();
    const l = await workLead(db, a, req.params.id, 'work');
    const area = (k: string) => num(b, k, { optional: true, min: 1, max: 1_000_000 }) ?? null;
    const x = {
      projectId: await ref(db, 'commission_projects', b.projectId, 'projectId', 'اختار المشروع'),
      unitType: (str(b, 'unitType', { optional: true, max: 60 }) ?? '').trim(), floor: (str(b, 'floor', { optional: true, max: 30 }) ?? '').trim(),
      minArea: area('minArea'), maxArea: area('maxArea'),
      maxPrice: num(b, 'maxPrice', { optional: true, min: 1, max: 100_000_000_000 }) ?? null,
      payment: oneOf(b, 'payment', ['any', 'cash', 'installments'] as const, true) ?? 'any',
      notes: (str(b, 'notes', { optional: true, max: 1000 }) ?? '').trim(),
    };
    if (x.minArea && x.maxArea && x.maxArea < x.minArea) throw invalid('أقصى مساحة أقل من أقل مساحة', { field: 'maxArea' });
    await db.tx(async (q) => {
      await q.query(`INSERT INTO lead_requests (lead_id, project_id, unit_type, floor, min_area, max_area, max_price, payment, notes, updated_by, updated_at)
          VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
          ON CONFLICT (lead_id) DO UPDATE SET project_id = EXCLUDED.project_id, unit_type = EXCLUDED.unit_type, floor = EXCLUDED.floor, min_area = EXCLUDED.min_area,
            max_area = EXCLUDED.max_area, max_price = EXCLUDED.max_price, payment = EXCLUDED.payment, notes = EXCLUDED.notes,
            updated_by = EXCLUDED.updated_by, updated_at = EXCLUDED.updated_at`,
        [l.id, x.projectId, x.unitType, x.floor, x.minArea, x.maxArea, x.maxPrice, x.payment, x.notes, a.id, now]);
      if (x.maxPrice) await q.query(`UPDATE leads SET budget = COALESCE(budget, $2) WHERE id = $1`, [l.id, x.maxPrice]);
      await log(q, l.id, 'request', a.id, {});
    });
    const rq = await one(db, `SELECT * FROM lead_requests WHERE lead_id = $1`, [l.id]);
    return ok({ matches: await matches(db, rq) });
  });

  /** the available units of a project (to pick one for a price offer) */
  r.get('/leads/available-units', async (req) => {
    await auth(req);
    const pid = req.query.get('projectId');
    return ok({ units: await matches(db, { project_id: pid && isUuid(pid) ? pid : null, unit_type: '', floor: '', min_area: null, max_area: null, max_price: null }, 300) });
  });

  r.post('/leads/:id/checkins', async (req) => {
    const a = await auth(req);
    const b = obj(req.body);
    const now = clock();
    const l = await workLead(db, a, req.params.id, 'work');
    const lat = num(b, 'lat', { min: -90, max: 90 })!, lng = num(b, 'lng', { min: -180, max: 180 })!;
    const accuracy = num(b, 'accuracy', { optional: true, min: 0, max: 100_000 }) ?? null;
    const note = (str(b, 'note', { optional: true, max: 500 }) ?? '').trim();
    await db.tx(async (q) => {
      await q.query(`INSERT INTO lead_checkins (lead_id, employee_id, lat, lng, accuracy_m, note, created_at) VALUES ($1,$2,$3,$4,$5,$6,$7)`,
        [l.id, a.id, lat, lng, accuracy, note, now]);
      await log(q, l.id, 'checkin', a.id, { lat, lng });
      await q.query(`INSERT INTO lead_actions (lead_id, stage, answered, comment, auto, by_id, created_at, next_at)
          VALUES ($1,'after_meeting',true,$2,true,$3,$4,$5)`,
        [l.id, `وصل الميتنج 📍${note ? ` — ${note}` : ''}`, a.id, now, new Date(now.getTime() + 24 * 3600_000)]);
      await q.query(`UPDATE leads SET stage = CASE WHEN stage IN ('meeting','reschedule') THEN 'after_meeting' ELSE stage END,
          stage_changed_at = CASE WHEN stage IN ('meeting','reschedule') THEN $2 ELSE stage_changed_at END,
          next_at = CASE WHEN stage IN ('meeting','reschedule') THEN $3 ELSE next_at END, last_action_at = $2, last_action_by = $4,
          last_comment = 'وصل الميتنج 📍', updated_at = $2 WHERE id = $1`, [l.id, now, new Date(now.getTime() + 24 * 3600_000), a.id]);
    });
    return ok({ ok: true }, 201);
  });

  // ------------------------------------------------------------------ رسايل واتساب جاهزة
  r.get('/leads/templates', async (req) => {
    await auth(req);
    const t = await db.query(`SELECT id, name, body FROM lead_templates WHERE active ORDER BY sort, name`);
    const c = await one(db, `SELECT company_name_ar FROM company_settings LIMIT 1`);
    return ok({ templates: t.rows, companyName: c?.company_name_ar ?? '' });
  });
  r.post('/leads/templates', async (req) => {
    const a = await auth(req);
    if (!canConfig(a)) throw forbidden();
    const b = obj(req.body);
    const x = await one(db, `INSERT INTO lead_templates (name, body, sort) VALUES ($1,$2,$3) RETURNING *`,
      [str(b, 'name', { min: 2, max: 80 }), str(b, 'body', { min: 2, max: 1500 }), num(b, 'sort', { optional: true, min: 0, max: 10000, int: true }) ?? 100]);
    await audit(db, a.id, 'lead.template.create', 'lead_template', x.id, undefined, x);
    return ok({ item: x }, 201);
  });
  r.patch('/leads/templates/:id', async (req) => {
    const a = await auth(req);
    if (!canConfig(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const o = await one(db, `SELECT * FROM lead_templates WHERE id = $1`, [req.params.id]);
    if (!o) throw notFound();
    const b = obj(req.body);
    const x = await one(db, `UPDATE lead_templates SET name = $2, body = $3, sort = $4, active = $5 WHERE id = $1 RETURNING *`, [o.id,
      b.name !== undefined ? str(b, 'name', { min: 2, max: 80 }) : o.name, b.body !== undefined ? str(b, 'body', { min: 2, max: 1500 }) : o.body,
      num(b, 'sort', { optional: true, min: 0, max: 10000, int: true }) ?? o.sort, bool(b, 'active') ?? o.active]);
    await audit(db, a.id, 'lead.template.update', 'lead_template', o.id, o, x);
    return ok({ item: x });
  });

  // ------------------------------------------------------------------ التارجت الشهري
  r.get('/leads/targets/me', async (req) => {
    const a = await auth(req);
    const month = monthOf(req.query.get('month'), clock());
    const [me] = await progress(db, [a.id], month);
    return ok({ month, me: me ?? null });
  });
  r.get('/leads/targets', async (req) => {
    const a = await auth(req);
    if (!canAll(a) && !canTeam(a)) throw forbidden();
    const month = monthOf(req.query.get('month'), clock());
    return ok({ month, people: await progress(db, await people(db, a), month), canEdit: canConfig(a) });
  });
  r.post('/leads/targets', async (req) => {
    const a = await auth(req);
    if (!canConfig(a)) throw forbidden();
    const b = obj(req.body);
    const month = typeof b.month === 'string' && monthRe.test(b.month) ? b.month : null;
    if (!month) throw invalid('اختار الشهر', { field: 'month' });
    const items = Array.isArray(b.items) ? b.items : [];
    if (!items.length || items.length > 500) throw invalid('مفيش تارجت', { field: 'items' });
    const now = clock();
    await db.tx(async (q) => {
      const allowed = new Set((await assignable(q, a)).map((e) => e.id));
      for (const raw of items) {
        const t = obj(raw);
        const id = typeof t.employeeId === 'string' && isUuid(t.employeeId) && allowed.has(t.employeeId) ? t.employeeId : null;
        if (!id) throw invalid('موظف مش في السيلز', { field: 'items' });
        const v = (k: string) => num(t, k, { optional: true, min: 0, max: 1_000_000, int: true }) ?? 0;
        const value = num(t, 'dealsValue', { optional: true, min: 0, max: 100_000_000_000 }) ?? 0;
        if (!v('calls') && !v('meetings') && !v('reservations') && !v('deals') && !value) {
          await q.query(`DELETE FROM lead_targets WHERE employee_id = $1 AND month = $2::date`, [id, `${month}-01`]);
          continue;
        }
        await q.query(`INSERT INTO lead_targets (employee_id, month, calls, meetings, reservations, deals, deals_value, updated_by, updated_at)
            VALUES ($1,$2::date,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT (employee_id, month) DO UPDATE SET calls = EXCLUDED.calls, meetings = EXCLUDED.meetings,
            reservations = EXCLUDED.reservations, deals = EXCLUDED.deals, deals_value = EXCLUDED.deals_value, updated_by = EXCLUDED.updated_by, updated_at = EXCLUDED.updated_at`,
          [id, `${month}-01`, v('calls'), v('meetings'), v('reservations'), v('deals'), value, a.id, now]);
      }
      await audit(q, a.id, 'lead.targets', 'lead_target', null, undefined, { month, count: items.length });
    });
    return ok({ month, people: await progress(db, await people(db, a), month) });
  });

  // ------------------------------------------------------------------ more reports
  /** الشغل اليومي: the actions of every salesman per hour of the day */
  r.get('/leads/reports/hourly', async (req) => {
    const a = await auth(req);
    if (!has(a, 'leads.reports')) throw forbidden();
    const now = clock();
    const from = dayRe.test(req.query.get('from') ?? '') ? req.query.get('from')! : now.toISOString().slice(0, 10);
    const to = dayRe.test(req.query.get('to') ?? '') ? req.query.get('to')! : from;
    const rows = await db.query(`
      SELECT e.id, e.full_name, extract(hour FROM x.created_at AT TIME ZONE 'Africa/Cairo')::int AS h, count(*)::int AS n
        FROM lead_actions x JOIN employees e ON e.id = x.by_id
       WHERE x.parent_id IS NULL AND NOT x.auto AND x.created_at >= ${F(1)} AND x.created_at < ${T(2)} AND ($3::uuid[] IS NULL OR e.id = ANY($3::uuid[]))
       GROUP BY e.id, e.full_name, h ORDER BY e.full_name`, [from, to, await people(db, a)]);
    const map = new Map<string, { id: string; name: string; hours: number[]; total: number }>();
    for (const x of rows.rows) {
      const p = map.get(x.id) ?? { id: x.id, name: x.full_name, hours: Array(24).fill(0), total: 0 };
      p.hours[x.h] += x.n; p.total += x.n;
      map.set(x.id, p);
    }
    return ok({ from, to, people: [...map.values()] });
  });

  /** الأداء السنوي: per month — leads given, actions, meetings, reservations, contracts */
  r.get('/leads/reports/yearly', async (req) => {
    const a = await auth(req);
    const now = clock();
    const year = Number(req.query.get('year')) || now.getUTCFullYear();
    let who = req.query.get('employeeId');
    if (!who || !isUuid(who)) who = a.id;
    if (who !== a.id) {
      const ppl = await people(db, a);
      if (ppl && !ppl.includes(who)) throw forbidden();
    }
    const rows = await db.query(`
      SELECT m::date AS month,
        (SELECT count(*) FROM lead_logs g WHERE g.kind = 'assign' AND (g.data->>'to')::uuid = $2 AND g.created_at >= (m AT TIME ZONE 'Africa/Cairo') AND g.created_at < ((m + interval '1 month') AT TIME ZONE 'Africa/Cairo'))::int AS leads,
        (SELECT count(*) FROM lead_actions x WHERE x.by_id = $2 AND x.parent_id IS NULL AND NOT x.auto AND x.created_at >= (m AT TIME ZONE 'Africa/Cairo') AND x.created_at < ((m + interval '1 month') AT TIME ZONE 'Africa/Cairo'))::int AS calls,
        (SELECT count(*) FROM lead_actions x WHERE x.by_id = $2 AND x.stage = 'meeting' AND x.created_at >= (m AT TIME ZONE 'Africa/Cairo') AND x.created_at < ((m + interval '1 month') AT TIME ZONE 'Africa/Cairo'))::int AS meetings,
        (SELECT count(*) FROM lead_checkins c WHERE c.employee_id = $2 AND c.created_at >= (m AT TIME ZONE 'Africa/Cairo') AND c.created_at < ((m + interval '1 month') AT TIME ZONE 'Africa/Cairo'))::int AS meetings_done,
        (SELECT count(*) FROM ex_units u WHERE u.sales_id = $2 AND u.status <> 'cancelled' AND u.created_at >= (m AT TIME ZONE 'Africa/Cairo') AND u.created_at < ((m + interval '1 month') AT TIME ZONE 'Africa/Cairo'))::int AS reservations,
        (SELECT count(*) FROM ex_units u WHERE u.sales_id = $2 AND u.contracted_at >= (m AT TIME ZONE 'Africa/Cairo') AND u.contracted_at < ((m + interval '1 month') AT TIME ZONE 'Africa/Cairo'))::int AS deals
        FROM generate_series(make_date($1, 1, 1)::timestamp, make_date($1, 12, 1)::timestamp, interval '1 month') AS m ORDER BY 1`, [year, who]);
    const e = await one(db, `SELECT full_name FROM employees WHERE id = $1`, [who]);
    return ok({ year, employee: { id: who, name: e?.full_name ?? '' }, months: rows.rows.map((x) => ({ ...x, month: iso(x.month)?.slice(0, 7) })) });
  });

  /** تقرير التوزيع: who received how many leads, from whom, in turn or by hand */
  r.get('/leads/reports/distribution', async (req) => {
    const a = await auth(req);
    if (!has(a, 'leads.reports')) throw forbidden();
    const now = clock();
    const from = dayRe.test(req.query.get('from') ?? '') ? req.query.get('from')! : `${now.toISOString().slice(0, 7)}-01`;
    const to = dayRe.test(req.query.get('to') ?? '') ? req.query.get('to')! : now.toISOString().slice(0, 10);
    const rows = await db.query(`
      SELECT t.full_name AS to_name, (g.data->>'to')::uuid AS to_id, COALESCE(b.full_name, 'فورم الحملة') AS by_name,
             count(*)::int AS n, count(*) FILTER (WHERE (g.data->>'turn')::boolean)::int AS turn,
             count(*) FILTER (WHERE g.data->>'mode' = 'auto')::int AS auto, count(*) FILTER (WHERE g.data->>'from' IS NOT NULL)::int AS moved
        FROM lead_logs g JOIN employees t ON t.id = (g.data->>'to')::uuid LEFT JOIN employees b ON b.id = g.by_id
       WHERE g.kind = 'assign' AND g.created_at >= ${F(1)} AND g.created_at < ${T(2)} AND ($3::uuid[] IS NULL OR (g.data->>'to')::uuid = ANY($3::uuid[]))
       GROUP BY 1, 2, 3 ORDER BY 1, 4 DESC`, [from, to, await people(db, a)]);
    const by = new Map<string, any>();
    for (const x of rows.rows) {
      const p = by.get(x.to_id) ?? { id: x.to_id, name: x.to_name, total: 0, turn: 0, auto: 0, moved: 0, from: [] as any[] };
      p.total += x.n; p.turn += x.turn; p.auto += x.auto; p.moved += x.moved; p.from.push({ name: x.by_name, n: x.n });
      by.set(x.to_id, p);
    }
    return ok({ from, to, people: [...by.values()] });
  });

  // ------------------------------------------------------------------ سجل التصدير
  r.post('/leads/exports', async (req) => {
    const a = await auth(req);
    if (!has(a, 'leads.export')) throw forbidden('مش مسموح لك تصدّر');
    const b = obj(req.body);
    const kind = str(b, 'kind', { min: 2, max: 60 })!;
    const rows = num(b, 'rows', { optional: true, min: 0, max: 1_000_000, int: true }) ?? 0;
    const filters = b.filters && typeof b.filters === 'object' ? b.filters : {};
    await db.query(`INSERT INTO lead_exports (kind, rows_count, filters, by_id, created_at) VALUES ($1,$2,$3,$4,$5)`, [kind, rows, JSON.stringify(filters), a.id, clock()]);
    return ok({ ok: true }, 201);
  });
  r.get('/leads/exports', async (req) => {
    const a = await auth(req);
    if (!canConfig(a)) throw forbidden();
    const x = await db.query(`SELECT x.*, e.full_name FROM lead_exports x LEFT JOIN employees e ON e.id = x.by_id ORDER BY x.created_at DESC LIMIT 200`);
    return ok({ exports: x.rows.map((e) => ({ kind: e.kind, rows: e.rows_count, filters: e.filters, byName: e.full_name, at: iso(e.created_at) })) });
  });

  // ------------------------------------------------------------------ the public form of a campaign
  r.post('/leads/campaigns/:id/form', async (req) => {
    const a = await auth(req);
    if (!canConfig(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const c = await one(db, `SELECT * FROM lead_campaigns WHERE id = $1`, [req.params.id]);
    if (!c) throw notFound();
    const enabled = bool(b, 'enabled') ?? true;
    const ids = Array.isArray(b.assignees) ? [...new Set(b.assignees.filter((x): x is string => typeof x === 'string' && isUuid(x)))] : [];
    const allowed = new Set((await assignable(db, a)).map((e) => e.id));
    if (ids.some((id) => !allowed.has(id))) throw invalid('اختار السيلز', { field: 'assignees' });
    if (enabled && !c.project_id) throw invalid('حدد مشروع الحملة الأول', { field: 'projectId' });
    const token = enabled ? c.form_token ?? randomBytes(9).toString('base64url') : null;
    const title = (str(b, 'title', { optional: true, max: 120 }) ?? '').trim();
    await db.query(`UPDATE lead_campaigns SET form_token = $2, form_assignees = $3, form_title = $4 WHERE id = $1`, [c.id, token, ids, title]);
    await audit(db, a.id, 'lead.campaign.form', 'lead_campaign', c.id, undefined, { enabled, assignees: ids.length });
    return ok({ token, path: token ? `/f/${token}` : null });
  });

  const formCampaign = async (token: string) => {
    if (!/^[A-Za-z0-9_-]{6,40}$/.test(token)) return null;
    return one(db, `SELECT c.*, p.name AS project_name FROM lead_campaigns c LEFT JOIN commission_projects p ON p.id = c.project_id
                     WHERE c.form_token = $1 AND c.active AND (c.ends_on IS NULL OR c.ends_on >= ($2::timestamptz AT TIME ZONE 'Africa/Cairo')::date)`, [token, clock()]);
  };

  r.get('/f/:token', async (req) => {
    const c = await formCampaign(req.params.token);
    const html = c ? formPage(c.form_title || c.project_name || c.name, `سيب بياناتك وهنكلّمك بخصوص ${c.project_name ?? c.name}`, req.params.token)
      : formPage('الفورم ده مش متاح', '', req.params.token, false).replace(/<form[\s\S]*<\/script>/, '<p>اللينك ده انتهى.</p>');
    return { status: c ? 200 : 404, binary: Buffer.from(html, 'utf8'), contentType: 'text/html; charset=utf-8' };
  });

  r.post('/public/leads/:token', async (req) => {
    const c = await formCampaign(req.params.token);
    if (!c) throw notFound('اللينك ده انتهى');
    const b = obj(req.body);
    if (typeof b.website === 'string' && b.website.trim()) return ok({ ok: true }, 201); // a bot filled the hidden field
    const now = clock();
    const x = readLead({ fullName: b.fullName, phone: b.phone, notes: b.notes, kind: 'fresh' });
    x.projectId = c.project_id; x.channelId = c.channel_id; x.campaignId = c.id;
    await db.tx(async (q) => {
      // the same number on the same campaign within a day: once
      if (await one(q, `SELECT 1 FROM leads WHERE campaign_id = $1 AND phone_norm = $2 AND created_at > $3::timestamptz - interval '1 day'`, [c.id, phoneNorm(x.phone), now])) return;
      const today = await one(q, `SELECT count(*)::int AS n FROM leads WHERE campaign_id = $1 AND created_at > $2::timestamptz - interval '1 day'`, [c.id, now]);
      if (today.n >= 1000) throw conflict('الفورم مقفول النهارده');
      const pool: string[] = c.form_assignees ?? [];
      const live = pool.length ? (await q.query(`SELECT id FROM employees WHERE id = ANY($1::uuid[]) AND status = 'active' AND COALESCE(legacy_fields->>'status', '') <> 'تم التصفيه'`, [pool])).rows.map((e) => e.id) : [];
      const to = live.length ? (await rotation(q, live))[0] : null;
      const res = await insertLead(q, null, x, to, now, 'form', live);
      if (res.to) {
        await notify(q, { to: res.to, type: 'lead_assigned', title: `ليد جديد من الفورم: ${x.fullName}`, body: c.name, entity: 'lead', entityId: res.lead.id,
          dedupeKey: `lead:${res.lead.id}:form` });
      }
    });
    return ok({ ok: true }, 201);
  });
};

/**
 * السحب الأوتوماتيك (company_settings.lead_auto_reassign_minutes, off when null): a lead given to one of several salesmen
 * (its pool) that nobody acted on for that long goes to the next of them; both and the manager are told.
 */
export async function leadsAutoReassign(q: Q, now: Date) {
  const s = await one(q, `SELECT lead_auto_reassign_minutes AS m FROM company_settings LIMIT 1`);
  if (!s?.m) return;
  const rows = await q.query(`
    SELECT l.id, l.full_name, l.assigned_to, l.assign_pool, e.full_name AS from_name FROM leads l JOIN employees e ON e.id = l.assigned_to
     WHERE ${OPEN_SQL} AND cardinality(l.assign_pool) > 1 AND (l.last_action_at IS NULL OR l.last_action_at < l.assigned_at)
       AND l.assigned_at <= $1::timestamptz - make_interval(mins => $2)
     LIMIT 200 FOR UPDATE OF l SKIP LOCKED`, [now, s.m]);
  for (const l of rows.rows) {
    const live = (await q.query(`SELECT id FROM employees WHERE id = ANY($1::uuid[]) AND status = 'active' AND COALESCE(legacy_fields->>'status', '') <> 'تم التصفيه' AND id <> $2`, [l.assign_pool, l.assigned_to])).rows.map((e) => e.id);
    if (!live.length) continue;
    const to = (await rotation(q, live))[0];
    await q.query(`UPDATE leads SET assigned_to = $2, assigned_at = $3, pending_alerted_at = NULL, reminded_at = NULL, updated_at = $3 WHERE id = $1`, [l.id, to, now]);
    await log(q, l.id, 'assign', null, { from: l.assigned_to, to, mode: 'auto', turn: true });
    await notify(q, { to, type: 'lead_assigned', title: `اتحوّل عليك ليد: ${l.full_name}`, body: `${l.from_name} ماعملش عليه أكشن`, entity: 'lead', entityId: l.id,
      dedupeKey: `lead:${l.id}:auto:${now.getTime()}` });
    await notify(q, { to: l.assigned_to, type: 'lead_moved', title: `الليد ${l.full_name} اتنقل لزميلك`, body: 'عشان ماتعملش عليه أكشن في الوقت', entity: 'lead',
      dedupeKey: `lead:${l.id}:autofrom:${now.getTime()}` });
  }
}

