import { ok, type Module } from '../ctx.ts';
import { one } from '../db.ts';
import { conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { bool, isUuid, num, obj, oneOf, str } from '../http/validate.ts';
import { audit, authenticate, has } from '../auth/context.ts';
import type { Req } from '../http/router.ts';
import { anyLeads, canSee, canWork, ref, seenPeople, stageShape, stagesOf } from './leads.ts';

/**
 * Like Elite (see db/migrations/060_stages_stars_deals.sql):
 *  - مراحل الليدز: add / rename / order / turn off stages, with «وقت التنبيه» and «مدة التأخير»
 *  - the client's stars and the WhatsApp tab (the messages sent from the app, and replies pasted in)
 *  - الصفقات: deals (a lead turned into a deal) on an Open / Won / Lost board
 * Registered before leadsModule: its fixed paths (/leads/stages …) must win over /leads/:id.
 */
const iso = (d: unknown) => (d ? new Date(d as string).toISOString() : null);
const n = (v: unknown) => (v == null ? null : Number(v));

export const leadsStagesDealsModule: Module = (r, { db, clock }) => {
  const auth = async (req: Req) => {
    const a = await authenticate(db, req);
    if (!anyLeads(a)) throw forbidden();
    return a;
  };

  // ------------------------------------------------------------------ مراحل الليدز
  r.get('/leads/stages', async (req) => {
    await auth(req);
    return ok({ stages: (await stagesOf(db)).map(stageShape) });
  });

  const stageBody = (b: Record<string, unknown>, partial: boolean) => {
    const out: Record<string, unknown> = {};
    if (!partial || b.name !== undefined) out.name_ar = str(b, 'name', { min: 2, max: 60 })!.trim();
    if (b.color !== undefined) {
      const c = str(b, 'color', { min: 7, max: 7 })!;
      if (!/^#[0-9A-Fa-f]{6}$/.test(c)) throw invalid('اللون مش صحيح', { field: 'color' });
      out.color = c;
    }
    if (b.alertMinutes !== undefined) out.alert_minutes = num(b, 'alertMinutes', { min: 0, max: 10080, int: true });
    if (b.delayMinutes !== undefined) out.delay_minutes = num(b, 'delayMinutes', { min: 0, max: 43200, int: true });
    if (b.needsDate !== undefined) out.needs_date = bool(b, 'needsDate');
    if (b.sort !== undefined) out.sort = num(b, 'sort', { min: 0, max: 10000, int: true });
    if (b.active !== undefined) out.active = bool(b, 'active');
    return out;
  };

  r.post('/leads/stages', async (req) => {
    const a = await auth(req);
    if (!has(a, 'leads.stages')) throw forbidden('إدارة المراحل لمن عنده الصلاحية');
    const b = obj(req.body);
    const x = stageBody(b, false);
    const key = `s_${Date.now().toString(36)}${Math.floor(Math.random() * 1296).toString(36)}`;
    if (await one(db, `SELECT 1 FROM lead_stages WHERE lower(name_ar) = lower($1)`, [x.name_ar])) throw conflict('في مرحلة بنفس الاسم');
    const max = await one(db, `SELECT COALESCE(max(sort), 0) AS m FROM lead_stages WHERE kind = 'action'`);
    const row = await one(db, `INSERT INTO lead_stages (key, name_ar, kind, needs_date, color, alert_minutes, delay_minutes, sort, active, builtin)
        VALUES ($1,$2,'action',$3,$4,$5,$6,$7,true,false) RETURNING *`,
      [key, x.name_ar, x.needs_date ?? true, x.color ?? '#7FB4E8', x.alert_minutes ?? 0, x.delay_minutes ?? 0, x.sort ?? Number(max.m) + 5]);
    await audit(db, a.id, 'leads.stage_create', 'lead_stage', null, undefined, { key, name: x.name_ar });
    return ok({ stage: stageShape(row) }, 201);
  });

  r.patch('/leads/stages/:key', async (req) => {
    const a = await auth(req);
    if (!has(a, 'leads.stages')) throw forbidden('إدارة المراحل لمن عنده الصلاحية');
    const st = await one(db, `SELECT * FROM lead_stages WHERE key = $1`, [req.params.key]);
    if (!st) throw notFound('المرحلة مش موجودة');
    const x = stageBody(obj(req.body), true);
    // the system's own stages: rename / colour / timings / order only (they can't be switched off)
    if (st.builtin) delete x.active;
    if (st.builtin && st.kind !== 'action') delete x.needs_date;
    if (x.name_ar && await one(db, `SELECT 1 FROM lead_stages WHERE lower(name_ar) = lower($1) AND key <> $2`, [x.name_ar, st.key])) {
      throw conflict('في مرحلة بنفس الاسم');
    }
    const keys = Object.keys(x);
    if (keys.length) {
      await db.query(`UPDATE lead_stages SET ${keys.map((k, i) => `${k} = $${i + 2}`).join(', ')} WHERE key = $1`, [st.key, ...keys.map((k) => x[k])]);
    }
    await audit(db, a.id, 'leads.stage_edit', 'lead_stage', null, undefined, { key: st.key, ...x });
    return ok({ stage: stageShape(await one(db, `SELECT * FROM lead_stages WHERE key = $1`, [st.key])) });
  });

  // ------------------------------------------------------------------ the client's stars
  r.post('/leads/:id/stars', async (req) => {
    const a = await auth(req);
    if (!isUuid(req.params.id)) throw notFound();
    const stars = num(obj(req.body), 'stars', { optional: true, min: 0, max: 5, int: true }) ?? 0;
    await db.tx(async (q) => {
      const l = await one(q, `SELECT * FROM leads WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!l || !await canSee(q, a, l.id)) throw notFound();
      if (!await canWork(q, a, l)) throw forbidden();
      await q.query(`UPDATE leads SET stars = $2 WHERE id = $1`, [l.id, stars || null]);
      await q.query(`INSERT INTO lead_logs (lead_id, kind, by_id, data, created_at) VALUES ($1,'stars',$2,$3,$4)`,
        [l.id, a.id, JSON.stringify({ from: l.stars, to: stars || null }), clock()]);
    });
    return ok({ stars: stars || null });
  });

  // ------------------------------------------------------------------ the WhatsApp tab
  r.get('/leads/:id/whatsapp', async (req) => {
    const a = await auth(req);
    if (!isUuid(req.params.id) || !await canSee(db, a, req.params.id)) throw notFound();
    const rows = await db.query(`SELECT w.*, e.full_name FROM lead_whatsapp w LEFT JOIN employees e ON e.id = w.by_id
                                  WHERE w.lead_id = $1 ORDER BY w.created_at, w.seq`, [req.params.id]);
    return ok({ messages: rows.rows.map((x) => ({ id: x.id, direction: x.direction, body: x.body, by: x.full_name, at: iso(x.created_at) })) });
  });
  /** «out»: a message sent from the app (logged as it opens WhatsApp); «in»: the client's reply the salesman pastes in */
  r.post('/leads/:id/whatsapp', async (req) => {
    const a = await auth(req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const direction = oneOf(b, 'direction', ['out', 'in'] as const, true) ?? 'out';
    const body = (str(b, 'body', { optional: true, max: 4000 }) ?? '').trim();
    if (direction === 'in' && !body) throw invalid('اكتب الرسالة', { field: 'body' });
    const tid = typeof b.templateId === 'string' && isUuid(b.templateId) ? b.templateId : null;
    const now = clock();
    await db.tx(async (q) => {
      const l = await one(q, `SELECT id FROM leads WHERE id = $1`, [req.params.id]);
      if (!l || !await canSee(q, a, l.id)) throw notFound();
      await q.query(`INSERT INTO lead_whatsapp (lead_id, direction, body, template_id, by_id, created_at) VALUES ($1,$2,$3,$4,$5,$6)`,
        [l.id, direction, body, tid, a.id, now]);
      if (direction === 'out') await q.query(`INSERT INTO lead_logs (lead_id, kind, by_id, created_at) VALUES ($1,'whatsapp',$2,$3)`, [l.id, a.id, now]);
    });
    return ok({ ok: true }, 201);
  });

  // ------------------------------------------------------------------ الصفقات
  const DEAL_SELECT = `
    SELECT d.*, l.full_name AS lead_name, l.phone AS lead_phone, p.name AS project_name, o.full_name AS owner_name, c.full_name AS created_name
      FROM deals d LEFT JOIN leads l ON l.id = d.lead_id LEFT JOIN commission_projects p ON p.id = d.project_id
      LEFT JOIN employees o ON o.id = d.owner_id LEFT JOIN employees c ON c.id = d.created_by`;
  const shapeDeal = (d: any) => ({
    id: d.id, refNo: Number(d.ref_no), title: d.title, value: n(d.value), stage: d.stage, unit: d.unit_text, notes: d.notes,
    lostReason: d.lost_reason, expectedAt: d.expected_at ? iso(d.expected_at)!.slice(0, 10) : null, sort: Number(d.sort),
    lead: d.lead_id ? { id: d.lead_id, name: d.lead_name, phone: d.lead_phone } : null,
    project: d.project_id ? { id: d.project_id, name: d.project_name } : null,
    owner: d.owner_id ? { id: d.owner_id, name: d.owner_name } : null,
    createdBy: d.created_name ?? null, createdAt: iso(d.created_at), updatedAt: iso(d.updated_at), closedAt: iso(d.closed_at),
  });
  /** the deals a person sees: his own (or his team's / everyone's, like the leads) */
  const dealScope = async (a: any, params: unknown[]) => {
    const people = await seenPeople(db, a);
    if (!people) return 'TRUE';
    params.push(people); const p = params.length;
    params.push(a.id); const me = params.length;
    return `(d.owner_id = ANY($${p}::uuid[]) OR d.created_by = $${me})`;
  };
  const canSeeDeal = async (a: any, id: string) => {
    const params: unknown[] = [id];
    const s = await dealScope(a, params);
    return one(db, `${DEAL_SELECT} WHERE d.id = $1 AND ${s}`, params);
  };

  r.get('/deals', async (req) => {
    const a = await auth(req);
    if (!has(a, 'deals.view')) throw forbidden('صفحة الصفقات مش متاحة ليك');
    const params: unknown[] = [];
    const where = [await dealScope(a, params)];
    const q = (req.query.get('q') ?? '').trim();
    if (q) { params.push(`%${q}%`); where.push(`(d.title ILIKE $${params.length} OR l.full_name ILIKE $${params.length} OR l.phone ILIKE $${params.length})`); }
    const owner = req.query.get('ownerId');
    if (owner && isUuid(owner)) { params.push(owner); where.push(`d.owner_id = $${params.length}`); }
    const rows = await db.query(`${DEAL_SELECT} WHERE ${where.join(' AND ')} ORDER BY d.sort, d.created_at DESC LIMIT 600`, params);
    const deals = rows.rows.map(shapeDeal);
    const sum = (s: string) => deals.filter((d) => d.stage === s).reduce((t, d) => t + (d.value ?? 0), 0);
    return ok({
      deals,
      totals: Object.fromEntries(['open', 'won', 'lost'].map((s) => [s, { count: deals.filter((d) => d.stage === s).length, value: sum(s) }])),
      can: { create: has(a, 'deals.create'), edit: has(a, 'deals.edit'), delete: has(a, 'deals.delete') },
    });
  });

  r.post('/deals', async (req) => {
    const a = await auth(req);
    if (!has(a, 'deals.create')) throw forbidden('مش مسموح لك تضيف صفقات');
    const b = obj(req.body);
    const now = clock();
    const row = await db.tx(async (q) => {
      let leadId: string | null = null, owner: string | null = a.id, projectId: string | null = null, title = (str(b, 'title', { optional: true, max: 160 }) ?? '').trim();
      if (b.leadId !== undefined && b.leadId !== null) {
        if (typeof b.leadId !== 'string' || !isUuid(b.leadId)) throw invalid('العميل مش موجود', { field: 'leadId' });
        const l = await one(q, `SELECT * FROM leads WHERE id = $1`, [b.leadId]);
        if (!l || !await canSee(q, a, l.id)) throw notFound('العميل مش موجود');
        if (!await canWork(q, a, l)) throw forbidden('التحويل لصفقة لسيلز العميل أو مديره');
        leadId = l.id; owner = l.assigned_to ?? a.id; projectId = l.project_id;
        if (!title) title = `${l.full_name}`;
      }
      if (title.length < 2) throw invalid('اكتب اسم الصفقة', { field: 'title' });
      if (b.projectId !== undefined) projectId = await ref(q, 'commission_projects', b.projectId, 'projectId', 'اختار المشروع');
      const value = num(b, 'value', { optional: true, min: 0, max: 100_000_000_000 }) ?? null;
      const top = await one(q, `SELECT COALESCE(min(sort), 0) - 1 AS s FROM deals WHERE stage = 'open'`);
      const d = await one(q, `INSERT INTO deals (lead_id, title, value, project_id, unit_text, expected_at, notes, owner_id, sort, created_by, created_at, updated_at)
          VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$11) RETURNING id`,
        [leadId, title, value, projectId, (str(b, 'unit', { optional: true, max: 120 }) ?? '').trim(),
         typeof b.expectedAt === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(b.expectedAt) ? b.expectedAt : null,
         (str(b, 'notes', { optional: true, max: 2000 }) ?? '').trim(), owner, Number(top.s), a.id, now]);
      if (leadId) await q.query(`INSERT INTO lead_logs (lead_id, kind, by_id, data, created_at) VALUES ($1,'deal',$2,$3,$4)`,
        [leadId, a.id, JSON.stringify({ dealId: d.id, value }), now]);
      await audit(q, a.id, 'deal.create', 'deal', d.id, undefined, { leadId, title, value });
      return d;
    });
    return ok({ deal: shapeDeal(await one(db, `${DEAL_SELECT} WHERE d.id = $1`, [row.id])) }, 201);
  });

  /** edit a deal, or move it (stage + its place: «beforeId» = the card it was dropped above, none = the bottom) */
  r.patch('/deals/:id', async (req) => {
    const a = await auth(req);
    if (!has(a, 'deals.edit')) throw forbidden('مش مسموح لك تعدّل الصفقات');
    if (!isUuid(req.params.id)) throw notFound();
    const d = await canSeeDeal(a, req.params.id);
    if (!d) throw notFound();
    const b = obj(req.body);
    const now = clock();
    const set: Record<string, unknown> = {};
    if (b.title !== undefined) set.title = str(b, 'title', { min: 2, max: 160 })!.trim();
    if (b.value !== undefined) set.value = num(b, 'value', { optional: true, min: 0, max: 100_000_000_000 }) ?? null;
    if (b.unit !== undefined) set.unit_text = (str(b, 'unit', { optional: true, max: 120 }) ?? '').trim();
    if (b.notes !== undefined) set.notes = (str(b, 'notes', { optional: true, max: 2000 }) ?? '').trim();
    if (b.lostReason !== undefined) set.lost_reason = (str(b, 'lostReason', { optional: true, max: 300 }) ?? '').trim();
    if (b.expectedAt !== undefined) set.expected_at = typeof b.expectedAt === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(b.expectedAt) ? b.expectedAt : null;
    if (b.projectId !== undefined) set.project_id = await ref(db, 'commission_projects', b.projectId, 'projectId', 'اختار المشروع');
    if (b.stage !== undefined) {
      const stage = oneOf(b, 'stage', ['open', 'won', 'lost'] as const)!;
      set.stage = stage;
      if (stage !== d.stage) set.closed_at = stage === 'open' ? null : now;
      // the card's place in its column
      let sort: number;
      if (typeof b.beforeId === 'string' && isUuid(b.beforeId)) {
        const before = await one(db, `SELECT sort FROM deals WHERE id = $1 AND stage = $2`, [b.beforeId, stage]);
        const prev = before ? await one(db, `SELECT max(sort) AS s FROM deals WHERE stage = $1 AND sort < $2 AND id <> $3`, [stage, before.sort, d.id]) : null;
        sort = before ? (prev?.s == null ? Number(before.sort) - 1 : (Number(prev.s) + Number(before.sort)) / 2) : 0;
      } else {
        const last = await one(db, `SELECT COALESCE(max(sort), 0) AS s FROM deals WHERE stage = $1 AND id <> $2`, [stage, d.id]);
        sort = Number(last.s) + 1;
      }
      set.sort = sort;
    }
    const keys = Object.keys(set);
    if (keys.length) {
      await db.query(`UPDATE deals SET ${keys.map((k, i) => `${k} = $${i + 2}`).join(', ')}, updated_at = $${keys.length + 2} WHERE id = $1`,
        [d.id, ...keys.map((k) => set[k]), now]);
      await audit(db, a.id, 'deal.edit', 'deal', d.id, undefined, set);
    }
    return ok({ deal: shapeDeal(await one(db, `${DEAL_SELECT} WHERE d.id = $1`, [d.id])) });
  });

  r.delete('/deals/:id', async (req) => {
    const a = await auth(req);
    if (!has(a, 'deals.delete')) throw forbidden('مش مسموح لك تحذف الصفقات');
    if (!isUuid(req.params.id)) throw notFound();
    const d = await canSeeDeal(a, req.params.id);
    if (!d) throw notFound();
    await db.query(`DELETE FROM deals WHERE id = $1`, [d.id]);
    await audit(db, a.id, 'deal.delete', 'deal', d.id, shapeDeal(d), undefined);
    return ok({ ok: true });
  });
  // the same through POST, for clients that can't send DELETE
  r.post('/deals/:id/delete', async (req) => {
    const a = await auth(req);
    if (!has(a, 'deals.delete')) throw forbidden('مش مسموح لك تحذف الصفقات');
    if (!isUuid(req.params.id)) throw notFound();
    const d = await canSeeDeal(a, req.params.id);
    if (!d) throw notFound();
    await db.query(`DELETE FROM deals WHERE id = $1`, [d.id]);
    await audit(db, a.id, 'deal.delete', 'deal', d.id, shapeDeal(d), undefined);
    return ok({ ok: true });
  });
};
