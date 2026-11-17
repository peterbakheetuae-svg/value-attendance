import { createHash, randomBytes } from 'node:crypto';
import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, forbidden, invalid, notFound } from '../http/errors.ts';
import { isUuid, obj, oneOf, str } from '../http/validate.ts';
import { audit, authenticate, has } from '../auth/context.ts';
import type { Req } from '../http/router.ts';
import { notify } from './notify.ts';
import { assignable, phoneNorm, readLead } from './leads.ts';
import { deliverLead, onlineAmong, ROUTE_MODES, valueAqarRoute, type RouteMode } from './lead_routing.ts';
import { canSetup, resolveDeveloper } from './exclusive.ts';
import { graph, pageToken, syncMeta, takeMetaLead } from './meta_sync.ts';

/**
 * الربط التلقائي (see db/migrations/062_integrations.sql):
 *  - POST /public/hooks/valueaqar  ← Value Aqar's Supabase database webhooks (header x-value-key):
 *      a new inquiry → a lead on the «فاليو عقار» channel (a direct channel, no campaign), given by the rule of its
 *      property / project / the default one (lead_routing.ts); a project / unit → «المشاريع الواردة» (+ the adopted ones' units)
 *  - GET/POST /public/hooks/meta    ← Meta lead ads (the page's lead forms) → a lead on the matching campaign (its salesmen / mode)
 *  - /integrations…                 ← the settings (leads.config): keys, the rules, the campaigns' distribution, the incoming projects
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
  const admin = async (req: Req, partnerToo = false) => {
    const a = await authenticate(db, req);
    if (a.partner && partnerToo) return a;   // a marketing company: looks at the Meta part, for its own campaigns
    if (!has(a, 'leads.config')) throw forbidden('الربط لمن عنده إعدادات الليدز');
    return a;
  };
  /** only salesmen the person setting it may distribute to */
  const checkPeople = async (a: any, ids: string[]) => {
    const allowed = new Set((await assignable(db, a)).map((e: any) => e.id));
    if (ids.some((id) => !allowed.has(id))) throw invalid('اختار سيلز من اللي ينفع توزّع عليهم', { field: 'assignees' });
  };
  const row = (source: string) => one(db, `SELECT * FROM integrations WHERE source = $1`, [source]);
  const ensure = async (source: string) => {
    await db.query(`INSERT INTO integrations (source) VALUES ($1) ON CONFLICT DO NOTHING`, [source]);
    return (await row(source))!;
  };
  const noteError = (source: string, e: string) =>
    db.query(`UPDATE integrations SET last_error = $2 WHERE source = $1`, [source, e.slice(0, 300)]).catch(() => undefined);

  const campaignOf = async (id: string | null) => (id ? one(db, `SELECT * FROM lead_campaigns WHERE id = $1 AND active`, [id]) : null);

  // ------------------------------------------------------------------ the settings
  r.get('/integrations', async (req) => {
    const a = await admin(req, true);
    if (a.partner) {
      // the company's view (read-only but for choosing its campaigns' Meta campaigns): no keys, tokens, salesmen or Value Aqar
      const meta = await ensure('meta');
      const mine = await db.query(`SELECT id, name, meta_campaign_ids FROM lead_campaigns WHERE active AND marketing_company_id = $1 ORDER BY created_at DESC`, [a.partner]);
      const seen = await db.query(`SELECT * FROM meta_seen_campaigns ORDER BY last_at DESC LIMIT 200`);
      return ok({
        partner: true,
        meta: { source: 'meta', active: meta.active, hasToken: !!meta.access_token, lastAt: iso(meta.last_at), lastError: null },
        valueaqar: null,
        campaigns: mine.rows.map((c) => ({ id: c.id, name: c.name, metaCampaignIds: c.meta_campaign_ids ?? [], companyId: a.partner, assignees: [], mode: null })),
        metaSeen: seen.rows.map((x) => ({ id: x.campaign_id, name: x.name, leads: x.leads, skipped: x.skipped, lastAt: iso(x.last_at) })),
        companies: [{ id: a.partner, name: a.fullName, active: true }],
        routes: [], properties: [], people: [], projects: [],
      });
    }
    const [va, meta] = [await ensure('valueaqar'), await ensure('meta')];
    const campaigns = await db.query(`SELECT id, name, meta_form_id, assign_mode, form_assignees, project_id, meta_campaign_ids, marketing_company_id
                                        FROM lead_campaigns WHERE active ORDER BY created_at DESC`);
    const seen = await db.query(`SELECT * FROM meta_seen_campaigns ORDER BY last_at DESC LIMIT 200`);
    const companies = await db.query(`SELECT id, name, status = 'active' AS active FROM marketing_companies ORDER BY status, name`);
    const routes = await db.query(`SELECT * FROM lead_routes WHERE source = 'valueaqar' ORDER BY target = 'default' DESC, label`);
    // Value Aqar's properties that are not inside one of its projects (a rule can be set per property)
    const properties = await db.query(`
      SELECT external_id, data FROM partner_units WHERE source = 'valueaqar' AND NOT deleted ORDER BY updated_at DESC LIMIT 500`);
    const people = await assignable(db, a);
    const online = new Set(await onlineAmong(db, people.map((e: any) => e.id), clock()));
    const projects = await db.query(`
      SELECT pp.*, p.name AS project_name, p.kind AS project_kind,
             (SELECT count(*) FROM partner_units u WHERE u.source = pp.source AND u.external_project_id = pp.external_id AND NOT u.deleted)::int AS units
        FROM partner_projects pp LEFT JOIN commission_projects p ON p.id = pp.project_id
       WHERE pp.status <> 'deleted' ORDER BY pp.status = 'new' DESC, pp.updated_at DESC LIMIT 300`);
    const shapeI = (x: any) => ({ source: x.source, active: x.active, campaignId: x.campaign_id, keyHint: x.key_hint, hasKey: !!x.key_hash,
      hasToken: !!x.access_token, verifyToken: x.source === 'meta' ? x.verify_token : undefined, lastAt: iso(x.last_at), lastError: x.last_error });
    return ok({
      valueaqar: shapeI(va), meta: shapeI(meta),
      metaPages: (await db.query(`SELECT page_id, name, subscribed, last_error, added_at FROM meta_pages ORDER BY added_at`)).rows
        .map((p) => ({ id: p.page_id, name: p.name, subscribed: p.subscribed, lastError: p.last_error, addedAt: iso(p.added_at) })),
      campaigns: campaigns.rows.map((c) => ({ id: c.id, name: c.name, metaFormId: c.meta_form_id, mode: c.assign_mode,
        assignees: c.form_assignees ?? [], hasProject: !!c.project_id, metaCampaignIds: c.meta_campaign_ids ?? [], companyId: c.marketing_company_id })),
      metaSeen: seen.rows.map((x) => ({ id: x.campaign_id, name: x.name, leads: x.leads, skipped: x.skipped, lastAt: iso(x.last_at) })),
      companies: companies.rows.map((x) => ({ id: x.id, name: x.name, active: x.active })),
      routes: routes.rows.map((x) => ({ id: x.id, target: x.target, externalId: x.external_id, label: x.label, mode: x.mode,
        assignees: x.assignees ?? [], updatedAt: iso(x.updated_at) })),
      properties: properties.rows.map((u) => ({ externalId: u.external_id,
        name: pick(u.data ?? {}, ['title', 'name', 'property_title', 'listing_title', 'unit_no', 'unit_number']) || `عقار ${u.external_id}`,
        project: `${(u.data ?? {}).project_id ?? ''}`, location: pick(u.data ?? {}, ['location', 'city', 'area', 'address', 'region']) })),
      people: people.map((e: any) => ({ id: e.id, name: e.full_name ?? e.name, online: online.has(e.id) })),
      projects: projects.rows.map((x) => ({ id: x.id, externalId: x.external_id, name: x.name, developer: x.developer, location: x.location,
        status: x.status, units: x.units, project: x.project_id ? { id: x.project_id, name: x.project_name, kind: x.project_kind } : null,
        receivedAt: iso(x.received_at), updatedAt: iso(x.updated_at) })),
    });
  });

  /** the Meta campaigns the saved token reaches (its ad accounts) — to pick which ones come in */
  r.get('/integrations/meta/campaigns', async (req) => {
    await admin(req, true);
    const it = await row('meta');
    if (!it?.access_token) return ok({ campaigns: [], error: 'حط توكن Meta الأول' });
    try {
      const res = await fetch(`https://graph.facebook.com/v21.0/me/adaccounts?fields=name,campaigns.limit(200){id,name,effective_status,objective}&limit=50&access_token=${encodeURIComponent(it.access_token)}`);
      const g: any = await res.json();
      if (!res.ok) throw new Error(g?.error?.message ?? `Meta ${res.status}`);
      const out: any[] = [];
      for (const acc of Array.isArray(g.data) ? g.data : []) {
        for (const c of Array.isArray(acc?.campaigns?.data) ? acc.campaigns.data : []) {
          if (/^[0-9]{3,30}$/.test(String(c.id))) out.push({ id: String(c.id), name: String(c.name ?? ''), status: String(c.effective_status ?? ''), account: String(acc.name ?? '') });
        }
      }
      return ok({ campaigns: out });
    } catch (e: any) {
      // a page token cannot list ad campaigns: the ones leads already came from are still offered (metaSeen)
      return ok({ campaigns: [], error: String(e?.message ?? e).slice(0, 300) });
    }
  });

  /**
   * a Facebook page (or all the pages of a user token): kept with its own page token and subscribed to «leadgen», so its
   * lead forms' leads reach the webhook. The token is never shown back.
   */
  r.post('/integrations/meta/pages', async (req) => {
    const a = await admin(req);
    const t = (str(obj(req.body), 'accessToken', { max: 2000 }) ?? '').trim();
    if (t.length < 20) throw invalid('الصق التوكن', { field: 'accessToken' });
    let found: { id: string; name: string; token: string }[] = [];
    const add = (list: any) => {
      for (const p of Array.isArray(list?.data) ? list.data : []) {
        if (/^[0-9]{3,30}$/.test(String(p.id)) && p.access_token && !found.some((f) => f.id === String(p.id))) {
          found.push({ id: String(p.id), name: String(p.name ?? ''), token: String(p.access_token) });
        }
      }
    };
    // a user token: the pages it manages itself, then the ones it reaches through a business portfolio
    try { add(await graph('me/accounts?fields=id,name,access_token&limit=100', t)); } catch { /* a page token has no «accounts» */ }
    if (!found.length) {
      try {
        const biz = await graph('me/businesses?fields=id&limit=50', t);
        for (const b of Array.isArray(biz.data) ? biz.data : []) {
          if (!/^[0-9]{3,30}$/.test(String(b.id))) continue;
          for (const edge of ['owned_pages', 'client_pages']) {
            try { add(await graph(`${b.id}/${edge}?fields=id,name,access_token&limit=100`, t)); } catch { /* not allowed on this portfolio */ }
          }
        }
      } catch { /* no business_management */ }
    }
    if (!found.length) {
      // a page token itself (a page has a category; a person does not — a user token is never kept as a «page»)
      let me: any;
      try { me = await graph('me?fields=id,name,category', t); } catch (e: any) {
        throw invalid(`Meta رفض التوكن: ${String(e?.message ?? e).slice(0, 200)}`, { field: 'accessToken' });
      }
      if (/^[0-9]{3,30}$/.test(String(me.id)) && me.category) found = [{ id: String(me.id), name: String(me.name ?? ''), token: t }];
      else throw invalid('التوكن ده بتاع حسابك ومش بيوصل لأي صفحة — اعمله بصلاحية business_management (أو pages_show_list) واختار الصفحة', { field: 'accessToken' });
    }
    if (!found.length) throw invalid('التوكن ده مش بيوصل لأي صفحة', { field: 'accessToken' });
    const out: any[] = [];
    for (const p of found) {
      let subscribed = false, err: string | null = null;
      try {
        await graph(`${p.id}/subscribed_apps?subscribed_fields=leadgen`, p.token, { method: 'POST' });
        subscribed = true;
      } catch (e: any) { err = String(e?.message ?? e).slice(0, 300); }
      await db.query(`INSERT INTO meta_pages (page_id, name, access_token, subscribed, last_error, added_by) VALUES ($1,$2,$3,$4,$5,$6)
                      ON CONFLICT (page_id) DO UPDATE SET name = EXCLUDED.name, access_token = EXCLUDED.access_token,
                        subscribed = EXCLUDED.subscribed, last_error = EXCLUDED.last_error`, [p.id, p.name, p.token, subscribed, err, a.id]);
      out.push({ id: p.id, name: p.name, subscribed, lastError: err });
    }
    await audit(db, a.id, 'integration.meta_pages', 'integration', null, undefined, { pages: out.map((p) => p.id) });
    // what the linked campaigns already have comes in now
    const pulled = await syncMeta(db, clock(), { deadlineMs: 8000 }).catch(() => ({ added: 0, errors: [] as string[] }));
    return ok({ pages: out, added: pulled.added });
  });

  r.post('/integrations/meta/pages/:id/remove', async (req) => {
    const a = await admin(req);
    const r2 = await db.query(`DELETE FROM meta_pages WHERE page_id = $1`, [req.params.id]);
    if (!r2.rowCount) throw notFound();
    await audit(db, a.id, 'integration.meta_page_remove', 'integration', null, undefined, { page: req.params.id });
    return ok({ ok: true });
  });

  /** «اسحب الليدز دلوقتي»: the linked Meta campaigns' leads, from Meta */
  r.post('/integrations/meta/sync', async (req) => {
    await admin(req);
    const r2 = await syncMeta(db, clock(), { deadlineMs: 20_000 });
    await db.query(`UPDATE integrations SET meta_sync_at = $1 WHERE source = 'meta'`, [clock()]);
    return ok({ added: r2.added, errors: [...new Set(r2.errors)].slice(0, 5) });
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
    if (b.campaignId !== undefined && source === 'meta') {
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

  const readRule = (b: Record<string, unknown>) => {
    const mode = oneOf(b, 'mode', ROUTE_MODES)!;
    const raw = Array.isArray(b.assignees) ? b.assignees : [];
    const ids = [...new Set(raw.filter((x): x is string => typeof x === 'string' && isUuid(x)))];
    if (!ids.length) throw invalid('اختار السيلز اللي هيستقبلوا الليدز', { field: 'assignees' });
    if (mode === 'one' && ids.length !== 1) throw invalid('في «سيلز واحد» اختار واحد بس', { field: 'assignees' });
    return { mode, ids };
  };

  /** a rule of Value Aqar: the default one, a project's or a property's (who gets its leads and how) */
  r.put('/integrations/routes', async (req) => {
    const a = await admin(req);
    const b = obj(req.body);
    const target = oneOf(b, 'target', ['default', 'project', 'property'] as const)!;
    const ext = target === 'default' ? '' : (str(b, 'externalId', { max: 80 }) ?? '').trim();
    if (target !== 'default' && !ext) throw invalid('اختار المشروع / العقار', { field: 'externalId' });
    const { mode, ids } = readRule(b);
    await checkPeople(a, ids);
    let label = (str(b, 'label', { optional: true, max: 200 }) ?? '').trim();
    let projectId: string | null = null;
    if (target === 'project') {
      const pp = await one(db, `SELECT name, project_id FROM partner_projects WHERE source = 'valueaqar' AND external_id = $1`, [ext]);
      if (!pp) throw notFound('المشروع ده مش واصل من فاليو عقار');
      label ||= pp.name; projectId = pp.project_id;
    } else if (target === 'property') {
      const u = await one(db, `SELECT data FROM partner_units WHERE source = 'valueaqar' AND external_id = $1`, [ext]);
      if (!u) throw notFound('العقار ده مش واصل من فاليو عقار');
      label ||= pick(u.data ?? {}, ['title', 'name', 'property_title', 'listing_title', 'unit_no']) || `عقار ${ext}`;
    } else label ||= 'كل الاستفسارات';
    const x = await one(db, `
      INSERT INTO lead_routes (source, target, external_id, label, mode, assignees, project_id, updated_by, updated_at)
      VALUES ('valueaqar',$1,$2,$3,$4,$5,$6,$7,$8)
      ON CONFLICT (source, target, external_id) DO UPDATE SET label = EXCLUDED.label, mode = EXCLUDED.mode, assignees = EXCLUDED.assignees,
        project_id = COALESCE(EXCLUDED.project_id, lead_routes.project_id), updated_by = EXCLUDED.updated_by, updated_at = EXCLUDED.updated_at
      RETURNING id`, [target, ext, label.slice(0, 200), mode, ids, projectId, a.id, clock()]);
    await audit(db, a.id, 'integration.route', 'lead_route', x.id, undefined, { target, ext, mode, assignees: ids.length });
    return ok({ id: x.id });
  });

  r.post('/integrations/routes/:id/remove', async (req) => {
    const a = await admin(req);
    if (!isUuid(req.params.id)) throw notFound();
    const x = await one(db, `DELETE FROM lead_routes WHERE id = $1 RETURNING target, external_id`, [req.params.id]);
    if (!x) throw notFound();
    await audit(db, a.id, 'integration.route_removed', 'lead_route', req.params.id, { target: x.target, ext: x.external_id }, undefined);
    return ok({ ok: true });
  });

  /** a campaign's distribution (its Meta form / public form leads): which salesmen and how */
  r.patch('/integrations/campaigns/:id', async (req) => {
    const a = await admin(req);
    if (!isUuid(req.params.id) || !await campaignOf(req.params.id)) throw notFound();
    const { mode, ids } = readRule(obj(req.body));
    await checkPeople(a, ids);
    await db.query(`UPDATE lead_campaigns SET assign_mode = $2, form_assignees = $3 WHERE id = $1`, [req.params.id, mode, ids]);
    await audit(db, a.id, 'integration.campaign_route', 'lead_campaign', req.params.id, undefined, { mode, assignees: ids.length });
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
        // a direct channel: «فاليو عقار» (no campaign); the project: the adopted one it came from, else the rule's
        const fromProject = pick(rec, ['project_id', 'compound_id', 'listing_project_id']).slice(0, 80);
        const fromProperty = pick(rec, ['property_id', 'unit_id', 'listing_id', 'ad_id']).slice(0, 80);
        const adopted = fromProject ? await one(db, `SELECT project_id FROM partner_projects WHERE source = 'valueaqar' AND external_id = $1 AND status = 'adopted'`, [fromProject]) : null;
        if (adopted?.project_id) x.projectId = adopted.project_id;
        const ch = await one(db, `SELECT id FROM lead_channels WHERE name = 'فاليو عقار' AND active`);
        if (ch && !x.channelId) x.channelId = ch.id;
        const rule = await valueAqarRoute(db, fromProperty, fromProject);
        if (!x.projectId && rule?.project_id && await one(db, `SELECT 1 FROM commission_projects WHERE id = $1`, [rule.project_id])) x.projectId = rule.project_id;
        const lead = await db.tx(async (q) => {
          // the same number twice on the same day from Value Aqar: once
          if (await one(q, `SELECT 1 FROM leads WHERE channel_id IS NOT DISTINCT FROM $1 AND phone_norm = $2 AND created_at > $3::timestamptz - interval '1 day'`,
            [x.channelId, phoneNorm(x.phone), now])) return null;
          return deliverLead(q, x, (rule?.mode ?? 'online') as RouteMode, rule?.assignees ?? [], now, 'فاليو عقار', pname || rule?.label || '');
        });
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
    if (!it?.active || (!it.access_token && !(await one(db, `SELECT 1 FROM meta_pages LIMIT 1`)))) return ok({ ok: true, skipped: 'off' });
    const b = obj(req.body);
    const now = clock();
    let added = 0;
    for (const entry of Array.isArray(b.entry) ? b.entry : []) {
      // the page the lead came on: read back with that page's token (several pages, 081), else the office's
      const token = await pageToken(db, /^[0-9]{3,30}$/.test(String(entry?.id ?? '')) ? String(entry.id) : null);
      for (const change of Array.isArray(entry?.changes) ? entry.changes : []) {
        if (change?.field !== 'leadgen') continue;
        const leadgen = String(change.value?.leadgen_id ?? '').replace(/\D/g, '');
        if (!leadgen) continue;
        try {
          if (!token) throw new Error('no token for this page');
          // the lead itself is read back from Meta (a forged id just fails here); only the chosen Meta campaigns come in
          const g = await graph(`${leadgen}?fields=id,field_data,form_id,ad_name,campaign_id,campaign_name,created_time`, token);
          if (await takeMetaLead(db, g, now) === 'added') added++;
        } catch (e: any) {
          await noteError('meta', e?.message ?? String(e));
        }
      }
    }
    await db.query(`UPDATE integrations SET last_at = $1 WHERE source = 'meta'`, [now]);
    return ok({ ok: true, added });
  });
};

