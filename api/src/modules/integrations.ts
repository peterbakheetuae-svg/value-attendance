import { createHash, randomBytes } from 'node:crypto';
import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, forbidden, invalid, notFound } from '../http/errors.ts';
import { isUuid, obj, oneOf, str } from '../http/validate.ts';
import { audit, authenticate, has } from '../auth/context.ts';
import type { Req } from '../http/router.ts';
import { notify } from './notify.ts';
import { insertLead, phoneNorm, readLead, rotation } from './leads.ts';
import { canSetup, resolveDeveloper } from './exclusive.ts';

/**
 * الربط التلقائي (see db/migrations/062_integrations.sql):
 *  - POST /public/hooks/valueaqar  ← Value Aqar's Supabase database webhooks (header x-value-key):
 *      a new inquiry → a lead on the chosen campaign; a project / unit → «المشاريع الواردة» (+ the adopted ones' units)
 *  - GET/POST /public/hooks/meta    ← Meta lead ads (the page's lead forms) → a lead on the matching campaign
 *  - /integrations…                 ← the settings (leads.config): keys, the campaign, the incoming projects
 */
const sha = (s: string) => createHash('sha256').update(s).digest('hex');
const iso = (d: unknown) => (d ? new Date(d as string).toISOString() : null);

/** the first non-empty text among the given keys (any case, nested one level under «data» / «fields») */
function pick(rec: Record<string, any>, keys: string[]): string {
  const flat: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(rec ?? {})) {
    flat[k.toLowerCase()] = v;
    if (v && typeof v === 'object' && !Array.isArray(v)) for (const [k2, v2] of Object.entries(v)) flat[`${k2}`.toLowerCase()] ??= v2;
  }
  for (const k of keys) {
    const v = flat[k.toLowerCase()];
    if (v !== undefined && v !== null && `${v}`.trim() !== '' && typeof v !== 'object') return `${v}`.trim();
  }
  return '';
}
const numOf = (s: string) => {
  const x = Number(s.replace(/[^\d.]/g, ''));
  return s && Number.isFinite(x) && x > 0 ? x : null;
};

const NAME = ['full_name', 'fullname', 'name', 'client_name', 'customer_name', 'user_name', 'contact_name'];
const PHONE = ['phone', 'phone_number', 'mobile', 'mobile_number', 'whatsapp', 'whatsapp_number', 'tel', 'contact_phone'];
const EMAIL = ['email', 'mail', 'contact_email'];
const MSG = ['message', 'notes', 'note', 'details', 'body', 'comment', 'inquiry', 'description'];
const PROJECT_NAME = ['project_name', 'project_title', 'compound_name', 'project'];

export const integrationsModule: Module = (r, { db, clock }) => {
  const admin = async (req: Req) => {
    const a = await authenticate(db, req);
    if (!has(a, 'leads.config')) throw forbidden('الربط لمن عنده إعدادات الليدز');
    return a;
  };
  const row = (source: string) => one(db, `SELECT * FROM integrations WHERE source = $1`, [source]);
  const ensure = async (source: string) => {
    await db.query(`INSERT INTO integrations (source) VALUES ($1) ON CONFLICT DO NOTHING`, [source]);
    return (await row(source))!;
  };
  const noteError = (source: string, e: string) =>
    db.query(`UPDATE integrations SET last_error = $2 WHERE source = $1`, [source, e.slice(0, 300)]).catch(() => undefined);

  /** a lead from outside, on a campaign: its project / channel, and its salesmen take turns (like the campaign form) */
  async function addLead(q: Q, c: any, x: ReturnType<typeof readLead>, now: Date, from: string) {
    x.projectId ??= c?.project_id ?? null; x.channelId ??= c?.channel_id ?? null; x.campaignId = c?.id ?? null;
    if (c && await one(q, `SELECT 1 FROM leads WHERE campaign_id = $1 AND phone_norm = $2 AND created_at > $3::timestamptz - interval '1 day'`,
      [c.id, phoneNorm(x.phone), now])) return null;   // the same number twice on the same day
    const pool: string[] = c?.form_assignees ?? [];
    const live = pool.length ? (await q.query(`SELECT id FROM employees WHERE id = ANY($1::uuid[]) AND status = 'active'
        AND COALESCE(legacy_fields->>'status', '') <> 'تم التصفيه'`, [pool])).rows.map((e) => e.id) : [];
    const to = live.length ? (await rotation(q, live))[0] : null;
    const res = await insertLead(q, null, x, to, now, 'form', live);
    if (res.to) {
      await notify(q, { to: res.to, type: 'lead_assigned', title: `ليد جديد من ${from}: ${x.fullName}`, body: c?.name ?? from, entity: 'lead',
        entityId: res.lead.id, dedupeKey: `lead:${res.lead.id}:${from}` });
    }
    return res.lead;
  }
  const campaignOf = async (id: string | null) => (id ? one(db, `SELECT * FROM lead_campaigns WHERE id = $1 AND active`, [id]) : null);

  // ------------------------------------------------------------------ the settings
  r.get('/integrations', async (req) => {
    await admin(req);
    const [va, meta] = [await ensure('valueaqar'), await ensure('meta')];
    const campaigns = await db.query(`SELECT id, name, meta_form_id FROM lead_campaigns WHERE active ORDER BY created_at DESC`);
    const projects = await db.query(`
      SELECT pp.*, p.name AS project_name, p.kind AS project_kind,
             (SELECT count(*) FROM partner_units u WHERE u.source = pp.source AND u.external_project_id = pp.external_id AND NOT u.deleted)::int AS units
        FROM partner_projects pp LEFT JOIN commission_projects p ON p.id = pp.project_id
       WHERE pp.status <> 'deleted' ORDER BY pp.status = 'new' DESC, pp.updated_at DESC LIMIT 300`);
    const shapeI = (x: any) => ({ source: x.source, active: x.active, campaignId: x.campaign_id, keyHint: x.key_hint, hasKey: !!x.key_hash,
      hasToken: !!x.access_token, verifyToken: x.source === 'meta' ? x.verify_token : undefined, lastAt: iso(x.last_at), lastError: x.last_error });
    return ok({
      valueaqar: shapeI(va), meta: shapeI(meta),
      campaigns: campaigns.rows.map((c) => ({ id: c.id, name: c.name, metaFormId: c.meta_form_id })),
      projects: projects.rows.map((x) => ({ id: x.id, externalId: x.external_id, name: x.name, developer: x.developer, location: x.location,
        status: x.status, units: x.units, project: x.project_id ? { id: x.project_id, name: x.project_name, kind: x.project_kind } : null,
        receivedAt: iso(x.received_at), updatedAt: iso(x.updated_at) })),
    });
  });

  /** a new key for Value Aqar — shown this once; the old one stops */
  r.post('/integrations/valueaqar/key', async (req) => {
    const a = await admin(req);
    await ensure('valueaqar');
    const key = `va_${randomBytes(24).toString('base64url')}`;
    await db.query(`UPDATE integrations SET key_hash = $1, key_hint = $2, updated_by = $3, updated_at = $4 WHERE source = 'valueaqar'`,
      [sha(key), `…${key.slice(-4)}`, a.id, clock()]);
    await audit(db, a.id, 'integration.key', 'integration', null, undefined, { source: 'valueaqar' });
    return ok({ key });
  });

  r.patch('/integrations/:source', async (req) => {
    const a = await admin(req);
    const source = oneOf({ s: req.params.source }, 's', ['valueaqar', 'meta'] as const)!;
    await ensure(source);
    const b = obj(req.body);
    const set: Record<string, unknown> = {};
    if (b.campaignId !== undefined) {
      if (b.campaignId !== null && (typeof b.campaignId !== 'string' || !isUuid(b.campaignId) || !await campaignOf(b.campaignId))) {
        throw invalid('اختار الحملة', { field: 'campaignId' });
      }
      set.campaign_id = b.campaignId;
    }
    if (b.active !== undefined) set.active = b.active === true;
    if (source === 'meta' && b.accessToken !== undefined) {
      const t = (str(b, 'accessToken', { optional: true, max: 2000 }) ?? '').trim();
      set.access_token = t || null;
    }
    if (source === 'meta' && b.newVerifyToken === true) set.verify_token = randomBytes(12).toString('base64url');
    const keys = Object.keys(set);
    if (keys.length) {
      await db.query(`UPDATE integrations SET ${keys.map((k, i) => `${k} = $${i + 2}`).join(', ')}, updated_by = $${keys.length + 2}, updated_at = $${keys.length + 3}
                       WHERE source = $1`, [source, ...keys.map((k) => set[k]), a.id, clock()]);
      await audit(db, a.id, 'integration.edit', 'integration', null, undefined, { source, fields: keys });
    }
    return ok({ ok: true });
  });

  /** a campaign ↔ a Meta lead form */
  r.patch('/integrations/meta/forms', async (req) => {
    const a = await admin(req);
    const b = obj(req.body);
    if (typeof b.campaignId !== 'string' || !isUuid(b.campaignId)) throw invalid('اختار الحملة', { field: 'campaignId' });
    const form = (str(b, 'formId', { optional: true, max: 40 }) ?? '').replace(/\D/g, '');
    await db.query(`UPDATE lead_campaigns SET meta_form_id = NULL WHERE meta_form_id = $1 AND id <> $2`, [form || null, b.campaignId]);
    await db.query(`UPDATE lead_campaigns SET meta_form_id = $2 WHERE id = $1`, [b.campaignId, form || null]);
    await audit(db, a.id, 'integration.meta_form', 'lead_campaign', b.campaignId, undefined, { form });
    return ok({ ok: true });
  });

  // ------------------------------------------------------------------ «المشاريع الواردة»: adopt / ignore
  /** units of an adopted project → its inventory (new ones added, changed ones updated, deleted ones switched off) */
  async function syncUnits(q: Q, pp: any) {
    if (!pp.project_id) return 0;
    const units = (await q.query(`SELECT * FROM partner_units WHERE source = $1 AND external_project_id = $2`, [pp.source, pp.external_id])).rows;
    let n = 0;
    for (const u of units) {
      const d = u.data ?? {};
      const unitNo = (pick(d, ['unit_no', 'unit_number', 'unit_code', 'code', 'number', 'title', 'name']) || `${u.external_id}`).slice(0, 60);
      const area = numOf(pick(d, ['area_m2', 'area', 'size', 'bua', 'gross_area', 'built_up_area']));
      const net = numOf(pick(d, ['net_area_m2', 'net_area']));
      const price = numOf(pick(d, ['unit_price', 'price', 'total_price']));
      const meter = numOf(pick(d, ['meter_price', 'price_per_meter', 'price_per_m2']));
      const ref = `${pp.source}:${u.external_id}`;
      const vals = [unitNo, pick(d, ['unit_type', 'type', 'property_type', 'category']).slice(0, 60), pick(d, ['floor', 'floor_no', 'level']).slice(0, 60),
        net, area, meter, price, pick(d, ['activity', 'usage']).slice(0, 200), !u.deleted && !/^(sold|reserved|hidden|inactive)$/i.test(pick(d, ['status', 'availability']))];
      const old = await one(q, `SELECT id FROM ex_inventory WHERE external_ref = $1`, [ref]);
      if (old) {
        await q.query(`UPDATE ex_inventory SET unit_no = $2, unit_type = $3, floor = $4, net_area_m2 = $5, area_m2 = $6, meter_price = $7, unit_price = $8,
                         activity = $9, active = $10 WHERE id = $1`, [old.id, ...vals]);
      } else if (!u.deleted) {
        // the same unit number typed by hand already → link it instead of a second one
        const same = await one(q, `SELECT id FROM ex_inventory WHERE project_id = $1 AND lower(trim(unit_no)) = lower(trim($2)) AND external_ref IS NULL`, [pp.project_id, unitNo]);
        if (same) await q.query(`UPDATE ex_inventory SET external_ref = $2 WHERE id = $1`, [same.id, ref]);
        else {
          await q.query(`INSERT INTO ex_inventory (project_id, unit_no, unit_type, floor, net_area_m2, area_m2, meter_price, unit_price, activity, active, notes, external_ref)
              VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,'من فاليو عقار',$11)`, [pp.project_id, ...vals, ref]);
        }
      }
      n++;
    }
    return n;
  }

  r.post('/integrations/projects/:id/adopt', async (req) => {
    const a = await admin(req);
    if (!canSetup(a)) throw forbidden('اعتماد المشاريع للمدير العام والمحاسب');
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const as = oneOf(b, 'as', ['marketing', 'exclusive'] as const)!;
    const out = await db.tx(async (q) => {
      const pp = await one(q, `SELECT * FROM partner_projects WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!pp || pp.status === 'deleted') throw notFound();
      let pid: string | null = typeof b.projectId === 'string' && isUuid(b.projectId) ? b.projectId : null;
      if (pid) {
        if (!await one(q, `SELECT 1 FROM commission_projects WHERE id = $1`, [pid])) throw notFound('المشروع مش موجود');
      } else {
        const name = (pp.name || `مشروع ${pp.external_id}`).slice(0, 120);
        const same = await one(q, `SELECT id FROM commission_projects WHERE lower(trim(name)) = lower(trim($1))`, [name]);
        if (same) pid = same.id;
        else {
          const dev = await resolveDeveloper(q, a, { developerName: pp.developer || 'فاليو عقار' });
          // the office's usual percentages — editable later from the project
          const p = as === 'marketing'
            ? await one(q, `INSERT INTO commission_projects (name, total_pct, sales_pct, manager_pct, company_pct, created_by, kind, marketing_pct, developer_id)
                VALUES ($1,3,0.2,0.1,2.7,$2,'marketing',0,$3) RETURNING id`, [name, a.id, dev?.id ?? null])
            : await one(q, `INSERT INTO commission_projects (name, total_pct, sales_pct, manager_pct, company_pct, created_by, kind,
                owner_name, owner_phone, contract_pct, installment_pct, marketing_pct, developer_id)
                VALUES ($1,5,0.2,0.1,4.7,$2,'exclusive',$3,$4,3,0.5,0,$5) RETURNING id`,
              [name, a.id, (dev?.owner_name || dev?.name || 'فاليو عقار').slice(0, 120), (dev?.phone || '-').slice(0, 30), dev?.id ?? null]);
          pid = p.id;
        }
      }
      await q.query(`UPDATE partner_projects SET status = 'adopted', project_id = $2, adopted_by = $3, updated_at = $4 WHERE id = $1`, [pp.id, pid, a.id, clock()]);
      const units = await syncUnits(q, { ...pp, project_id: pid });
      await audit(q, a.id, 'integration.adopt', 'partner_project', pp.id, undefined, { as, projectId: pid, units });
      return { projectId: pid, units };
    });
    return ok(out);
  });

  r.post('/integrations/projects/:id/ignore', async (req) => {
    const a = await admin(req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const back = b.undo === true;
    await db.query(`UPDATE partner_projects SET status = $2, updated_at = $3 WHERE id = $1 AND status IN ('new','ignored')`, [req.params.id, back ? 'new' : 'ignored', clock()]);
    await audit(db, a.id, 'integration.ignore', 'partner_project', req.params.id, undefined, { undo: back });
    return ok({ ok: true });
  });

  // ------------------------------------------------------------------ Value Aqar's webhooks (Supabase «Database Webhooks»)
  r.post('/public/hooks/valueaqar', async (req) => {
    const key = String(req.headers['x-value-key'] ?? '').trim() || String(req.headers.authorization ?? '').replace(/^Bearer\s+/i, '').trim();
    const it = await row('valueaqar');
    if (!it?.key_hash || !key || sha(key) !== it.key_hash) throw new AppError('unauthenticated', 'Wrong key');
    if (!it.active) return ok({ ok: true, skipped: 'off' });
    const b = obj(req.body);
    const type = String(b.type ?? 'INSERT').toUpperCase();
    const table = String(b.table ?? b.kind ?? '').toLowerCase();
    const rec: Record<string, any> = (b.record && typeof b.record === 'object' ? b.record : b.old_record && typeof b.old_record === 'object' ? b.old_record : b) as any;
    const now = clock();
    const extId = String(rec.id ?? rec.uuid ?? rec.external_id ?? '').slice(0, 80);
    try {
      let result: Record<string, unknown> = {};
      if (/inquir|lead|request|contact|message/.test(table) || (!table && pick(rec, PHONE))) {
        if (type === 'DELETE') return ok({ ok: true, skipped: 'delete' });
        const fullName = pick(rec, NAME) || 'عميل فاليو عقار';
        const phone = pick(rec, PHONE);
        if (phoneNorm(phone).length < 7) throw invalid('رقم الموبايل ناقص', { field: 'phone' });
        const pname = pick(rec, PROJECT_NAME);
        const notes = [pick(rec, MSG), pname ? `المشروع على فاليو عقار: ${pname}` : '', pick(rec, ['unit', 'unit_no', 'property_title', 'listing_title'])]
          .filter(Boolean).join(' — ').slice(0, 1900);
        const x = readLead({ fullName, phone, email: pick(rec, EMAIL), notes, kind: 'fresh' });
        // the project: the adopted one it came from, else the campaign's
        const fromProject = pick(rec, ['project_id', 'compound_id', 'listing_project_id']);
        const adopted = fromProject ? await one(db, `SELECT project_id FROM partner_projects WHERE source = 'valueaqar' AND external_id = $1 AND status = 'adopted'`, [fromProject]) : null;
        if (adopted?.project_id) x.projectId = adopted.project_id;
        const ch = await one(db, `SELECT id FROM lead_channels WHERE name = 'فاليو عقار' AND active`);
        if (ch && !x.channelId) x.channelId = ch.id;
        const c = await campaignOf(it.campaign_id);
        if (!x.projectId && !c?.project_id) throw invalid('اختار حملة ليها مشروع لاستفسارات فاليو عقار', { field: 'campaignId' });
        const lead = await db.tx((q) => addLead(q, c, x, now, 'فاليو عقار'));
        result = { lead: lead ? lead.id : null, duplicate: !lead };
      } else if (/unit|propert|listing|inventory/.test(table)) {
        if (!extId) throw invalid('الوحدة من غير id', { field: 'id' });
        const projectExt = String(rec.project_id ?? rec.compound_id ?? rec.projectId ?? '').slice(0, 80);
        await db.tx(async (q) => {
          await q.query(`INSERT INTO partner_units (source, external_id, external_project_id, data, deleted, received_at, updated_at)
              VALUES ('valueaqar',$1,$2,$3,$4,$5,$5)
              ON CONFLICT (source, external_id) DO UPDATE SET
                external_project_id = CASE WHEN EXCLUDED.deleted AND EXCLUDED.external_project_id = '' THEN partner_units.external_project_id ELSE EXCLUDED.external_project_id END,
                data = CASE WHEN EXCLUDED.deleted THEN partner_units.data ELSE EXCLUDED.data END,
                deleted = EXCLUDED.deleted, updated_at = EXCLUDED.updated_at`, [extId, projectExt, JSON.stringify(rec), type === 'DELETE', now]);
          const u = await one(q, `SELECT external_project_id FROM partner_units WHERE source = 'valueaqar' AND external_id = $1`, [extId]);
          const pp = await one(q, `SELECT * FROM partner_projects WHERE source = 'valueaqar' AND external_id = $1 AND status = 'adopted'`, [u?.external_project_id ?? projectExt]);
          if (pp) await syncUnits(q, pp);
        });
        result = { unit: extId };
      } else if (/project|compound|development/.test(table)) {
        if (!extId) throw invalid('المشروع من غير id', { field: 'id' });
        await db.tx(async (q) => {
          await q.query(`INSERT INTO partner_projects (source, external_id, name, developer, location, data, status, received_at, updated_at)
              VALUES ('valueaqar',$1,$2,$3,$4,$5,$6,$7,$7)
              ON CONFLICT (source, external_id) DO UPDATE SET name = EXCLUDED.name, developer = EXCLUDED.developer, location = EXCLUDED.location,
                data = EXCLUDED.data, updated_at = EXCLUDED.updated_at,
                status = CASE WHEN $6 = 'deleted' THEN 'deleted' WHEN partner_projects.status = 'deleted' THEN 'new' ELSE partner_projects.status END`,
            [extId, pick(rec, ['name', 'title', 'project_name', 'name_ar']).slice(0, 160), pick(rec, ['developer', 'developer_name', 'company', 'developer_title']).slice(0, 160),
             pick(rec, ['location', 'city', 'area', 'address', 'region']).slice(0, 160), JSON.stringify(rec), type === 'DELETE' ? 'deleted' : 'new', now]);
        });
        result = { project: extId };
      } else {
        return ok({ ok: true, skipped: `table ${table || '?'}` });
      }
      await db.query(`UPDATE integrations SET last_at = $1, last_error = '' WHERE source = 'valueaqar'`, [now]);
      return ok({ ok: true, ...result });
    } catch (e: any) {
      await noteError('valueaqar', e?.message ?? String(e));
      throw e;
    }
  });

  // ------------------------------------------------------------------ Meta lead ads
  /** Meta checks the webhook once: it sends the verify token and wants the challenge back */
  r.get('/public/hooks/meta', async (req) => {
    const it = await row('meta');
    const mode = req.query.get('hub.mode'), token = req.query.get('hub.verify_token'), ch = req.query.get('hub.challenge') ?? '';
    if (mode !== 'subscribe' || !it?.verify_token || token !== it.verify_token) throw forbidden('Wrong verify token');
    return { binary: Buffer.from(ch.replace(/[^\w-]/g, '')), contentType: 'text/plain' };
  });

  r.post('/public/hooks/meta', async (req) => {
    const it = await row('meta');
    if (!it?.active || !it.access_token) return ok({ ok: true, skipped: 'off' });
    const b = obj(req.body);
    const now = clock();
    let added = 0;
    for (const entry of Array.isArray(b.entry) ? b.entry : []) {
      for (const change of Array.isArray(entry?.changes) ? entry.changes : []) {
        if (change?.field !== 'leadgen') continue;
        const leadgen = String(change.value?.leadgen_id ?? '').replace(/\D/g, '');
        if (!leadgen) continue;
        try {
          // the lead itself is read back from Meta with the office's token (a forged id just fails here)
          const res = await fetch(`https://graph.facebook.com/v21.0/${leadgen}?fields=field_data,form_id,ad_name,campaign_name,created_time&access_token=${encodeURIComponent(it.access_token)}`);
          const g: any = await res.json();
          if (!res.ok) throw new Error(g?.error?.message ?? `Meta ${res.status}`);
          const f: Record<string, string> = {};
          for (const x of Array.isArray(g.field_data) ? g.field_data : []) f[String(x.name).toLowerCase()] = Array.isArray(x.values) ? String(x.values[0] ?? '') : '';
          const fullName = f.full_name || [f.first_name, f.last_name].filter(Boolean).join(' ') || 'عميل من فيسبوك';
          const phone = f.phone_number || f.phone || f.mobile || '';
          if (phoneNorm(phone).length < 7) throw new Error('lead without a phone');
          const extra = Object.entries(f).filter(([k]) => !['full_name', 'first_name', 'last_name', 'phone_number', 'phone', 'email'].includes(k))
            .map(([k, v]) => `${k}: ${v}`);
          const notes = [g.campaign_name ? `حملة: ${g.campaign_name}` : '', g.ad_name ? `إعلان: ${g.ad_name}` : '', ...extra].filter(Boolean).join(' — ').slice(0, 1900);
          const x = readLead({ fullName, phone, email: f.email ?? '', notes, kind: 'fresh' });
          const c = (g.form_id ? await one(db, `SELECT * FROM lead_campaigns WHERE meta_form_id = $1 AND active`, [String(g.form_id)]) : null)
            ?? await campaignOf(it.campaign_id);
          if (!c?.project_id) throw new Error('no campaign with a project for this form');
          const lead = await db.tx((q) => addLead(q, c, x, now, 'فيسبوك'));
          if (lead) added++;
        } catch (e: any) {
          await noteError('meta', e?.message ?? String(e));
        }
      }
    }
    await db.query(`UPDATE integrations SET last_at = $1 WHERE source = 'meta'`, [now]);
    return ok({ ok: true, added });
  });
};

