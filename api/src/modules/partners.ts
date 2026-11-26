import { ok, type Module } from '../ctx.ts';
import { one, type Db, type Q } from '../db.ts';
import { AppError, conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { emailChangeMail, mailEnabled, sendMail } from '../lib/mail.ts';
import { createHash, randomInt } from 'node:crypto';
import { date, isUuid, obj, str } from '../http/validate.ts';
import { adminOfficerSql, audit, authenticate, has } from '../auth/context.ts';
import { authenticatePartner, type Partner } from '../auth/partner.ts';
import { hashPassword, passwordPolicyError } from '../auth/password.ts';
import { clearAccount } from '../auth/throttle.ts';
import type { Req } from '../http/router.ts';
import { duplicateWatchers, insertLead, phoneNorm, readLead, refuseExisting, stageShape, stagesOf } from './leads.ts';
import { notify } from './notify.ts';
import { deliverLead, type RouteMode } from './lead_routing.ts';
import { canOffice } from './cash.ts';
import { readFileBytes, storeFile, withFile } from '../lib/files.ts';

/**
 * شركات التسويق (db/migrations/075_marketing_partners.sql).
 *  - /marketing-companies…  (leads.config): the companies, their sign-in, which of our campaigns each runs, and which Meta
 *    campaigns feed each of our campaigns.
 *  - /partner/…             (the company's own sign-in): its dashboard, the leads of its campaigns (read-only: stage, the
 *    salesman, the comments, closed or not) and adding a lead to one of its campaigns — no action, no distribution.
 * A company sees a lead when the lead's campaign is linked to it, or when it added the lead itself.
 */
const iso = (d: unknown) => (d ? new Date(d as string).toISOString() : null);
const META_ID = /^[0-9]{3,30}$/;
const sha = (s: string) => createHash('sha256').update(s).digest('hex');

/** SQL (aliases l = leads, cp = lead_campaigns) for the leads company $n sees */
const SEES = (n: number) => `(cp.marketing_company_id = $${n} OR l.partner_company_id = $${n})`;

export const partnersModule: Module = (r, { db, clock }) => {
  // the company's file is kept by whoever manages the marketing companies (المالك / المدير العام — cash.office) or the leads settings
  const admin = async (req: Req) => {
    const a = await authenticate(db, req);
    if (!has(a, 'leads.config') && !canOffice(a)) throw forbidden('شركات التسويق للمالك / المدير العام / إعدادات الليدز');
    return a;
  };

  // ================================================================== the office's side
  // the companies themselves (name, kind, fee / %) are managed where they always were (exclusive.ts «شركات التسويق»);
  // here: their sign-in, and which of our campaigns each runs
  const companyShape = (c: any) => ({
    id: c.id, name: c.name, kind: c.kind, status: c.status, active: c.status === 'active',
    loginEmail: c.login_email, loginPhone: c.login_phone, hasLogin: !!c.password_hash, mustChangePassword: c.must_change_password,
    campaigns: (c.campaigns ?? []).filter((x: any) => x && x.id), leads: Number(c.leads ?? 0),
  });

  r.get('/leads/partners', async (req) => {
    await admin(req);
    const rows = await db.query(`
      SELECT c.*,
             COALESCE((SELECT json_agg(json_build_object('id', cp.id, 'name', cp.name) ORDER BY cp.created_at DESC)
                         FROM lead_campaigns cp WHERE cp.marketing_company_id = c.id), '[]') AS campaigns,
             (SELECT count(*) FROM leads l LEFT JOIN lead_campaigns cp ON cp.id = l.campaign_id
               WHERE cp.marketing_company_id = c.id OR l.partner_company_id = c.id) AS leads
        FROM marketing_companies c ORDER BY c.status, c.name`);
    return ok({ companies: rows.rows.map(companyShape) });
  });

  /** e-mail / mobile used by an employee or another company → refused (a sign-in must lead to one account only) */
  async function loginFree(q: Q, email: string | null, norm: string | null, self: string) {
    if (email && await one(q, `SELECT 1 FROM employees WHERE lower(email) = $1`, [email])) throw conflict('الإيميل ده بتاع موظف');
    if (norm && await one(q, `SELECT 1 FROM employees WHERE length(regexp_replace(coalesce(phone, ''), '\D', '', 'g')) >= 10
                                 AND right(regexp_replace(coalesce(phone, ''), '\D', '', 'g'), 10) = right($1, 10)`, [norm])) {
      throw conflict('الموبايل ده بتاع موظف');
    }
    if (email && await one(q, `SELECT 1 FROM marketing_companies WHERE lower(login_email) = $1 AND id <> $2`, [email, self])) throw conflict('الإيميل ده مستخدم لشركة تانية');
    if (norm && await one(q, `SELECT 1 FROM marketing_companies WHERE right(login_phone_norm, 10) = right($1, 10) AND id <> $2`, [norm, self])) {
      throw conflict('الموبايل ده مستخدم لشركة تانية');
    }
  }

  /** the company's sign-in: e-mail and / or mobile + a first password (it changes it on the first sign-in); off = no sign-in */
  r.patch('/leads/partners/:id/login', async (req) => {
    const a = await admin(req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const off = b.off === true;
    const email = off ? null : ((str(b, 'email', { optional: true, max: 160 }) ?? '').trim().toLowerCase() || null);
    if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw invalid('الإيميل مش صحيح', { field: 'email' });
    const phone = off ? null : ((str(b, 'phone', { optional: true, max: 30 }) ?? '').trim() || null);
    const norm = phone ? phoneNorm(phone) : null;
    if (phone && norm!.length < 10) throw invalid('رقم الموبايل مش صحيح', { field: 'phone' });
    if (!off && !email && !phone) throw invalid('اكتب إيميل أو موبايل للدخول', { field: 'email' });
    let hash: string | undefined;
    if (!off && b.password !== undefined && b.password !== null && b.password !== '') {
      const err = passwordPolicyError(b.password);
      if (err) throw invalid(err, { field: 'password' });
      hash = await hashPassword(String(b.password));
    }
    const c = await db.tx(async (q) => {
      const before = await one(q, `SELECT * FROM marketing_companies WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!before) throw notFound();
      if (!off && !hash && !before.password_hash) throw invalid('اكتب كلمة مرور أول مرة', { field: 'password' });
      await loginFree(q, email, norm, before.id);
      const row = off
        ? await one(q, `UPDATE marketing_companies SET login_email = NULL, login_phone = NULL, login_phone_norm = NULL, password_hash = NULL WHERE id = $1 RETURNING *`, [before.id])
        : await one(q, `UPDATE marketing_companies SET login_email = $2, login_phone = $3, login_phone_norm = $4,
                          password_hash = COALESCE($5, password_hash), must_change_password = (must_change_password OR $5 IS NOT NULL),
                          failed_logins = CASE WHEN $5 IS NULL THEN failed_logins ELSE 0 END,
                          locked_until = CASE WHEN $5 IS NULL THEN locked_until ELSE NULL END
                         WHERE id = $1 RETURNING *`, [before.id, email, phone, norm, hash ?? null]);
      // turned off or a new password: every device is signed out
      if (off || hash) await q.query(`UPDATE partner_sessions SET revoked_at = now() WHERE company_id = $1 AND revoked_at IS NULL`, [before.id]);
      if (hash) await clearAccount(q, `c:${before.id}`);
      await audit(q, a.id, 'marketing_company.login', 'marketing_company', before.id,
        { email: before.login_email, phone: before.login_phone, hasLogin: !!before.password_hash },
        { email: row.login_email, phone: row.login_phone, hasLogin: !!row.password_hash, passwordReset: !!hash });
      return row;
    });
    return ok({ company: companyShape(c) });
  });

  /** which company runs one of our campaigns, and which Meta campaigns feed it */
  r.patch('/leads/campaigns/:id/partner', async (req) => {
    // a marketing company (from «الربط») chooses only which Meta campaigns feed its own campaign
    const a = await authenticate(db, req);
    if (!a.partner && !has(a, 'leads.config') && !canOffice(a)) throw forbidden('شركات التسويق للمالك / المدير العام / إعدادات الليدز');
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    if (a.partner && b.companyId !== undefined) throw forbidden('مش مسموح تغيّر الشركة');
    const set: Record<string, unknown> = {};
    if (b.companyId !== undefined) {
      const id = b.companyId === null || b.companyId === '' ? null : String(b.companyId);
      if (id && (!isUuid(id) || !(await one(db, `SELECT 1 FROM marketing_companies WHERE id = $1`, [id])))) throw invalid('شركة التسويق مش موجودة', { field: 'companyId' });
      set.marketing_company_id = id;
    }
    if (b.metaCampaignIds !== undefined) {
      if (!Array.isArray(b.metaCampaignIds) || b.metaCampaignIds.length > 50) throw invalid('حملات Meta مش صحيحة', { field: 'metaCampaignIds' });
      const ids = [...new Set(b.metaCampaignIds.map((x) => String(x).trim()))];
      if (ids.some((x) => !META_ID.test(x))) throw invalid('رقم حملة Meta لازم يكون أرقام بس', { field: 'metaCampaignIds' });
      set.meta_campaign_ids = ids;
    }
    const keys = Object.keys(set);
    if (!keys.length) throw invalid('مفيش تغيير');
    const row = await db.tx(async (q) => {
      const before = await one(q, `SELECT id, name, marketing_company_id, meta_campaign_ids FROM lead_campaigns WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!before || (a.partner && before.marketing_company_id !== a.partner)) throw notFound();
      // a campaign runs with ONE company: moving it from one company to another is refused — free it first (companyId: null)
      if (set.marketing_company_id && before.marketing_company_id && set.marketing_company_id !== before.marketing_company_id) {
        throw new AppError('conflict', 'الحملة دي شغالة مع شركة تانية — شيلها من الشركة دي الأول', { reason: 'campaign_taken', field: 'companyId' });
      }
      // a Meta campaign feeds one of our campaigns only (a company cannot take one another campaign already has)
      if (set.meta_campaign_ids && a.partner && await one(q, `SELECT 1 FROM lead_campaigns WHERE id <> $1 AND meta_campaign_ids && $2::text[]`, [before.id, set.meta_campaign_ids])) {
        throw conflict('حملة Meta دي مربوطة بحملة تانية');
      }
      if (set.meta_campaign_ids) {
        await q.query(`UPDATE lead_campaigns SET meta_campaign_ids = ARRAY(SELECT x FROM unnest(meta_campaign_ids) x WHERE NOT x = ANY($2::text[]))
                        WHERE id <> $1 AND meta_campaign_ids && $2::text[]`, [before.id, set.meta_campaign_ids]);
      }
      // a Meta campaign newly linked: pulled again from its last 90 days
      if (set.meta_campaign_ids && !(set.meta_campaign_ids as string[]).every((x) => (before.meta_campaign_ids ?? []).includes(x))) {
        await q.query(`UPDATE lead_campaigns SET meta_synced_at = NULL WHERE id = $1`, [before.id]);
      }
      const after = await one(q, `UPDATE lead_campaigns SET ${keys.map((k, i) => `${k} = $${i + 2}`).join(', ')} WHERE id = $1
                                   RETURNING id, name, marketing_company_id, meta_campaign_ids`, [before.id, ...keys.map((k) => set[k])]);
      await audit(q, a.partner ? null : a.id, 'lead_campaign.partner_link', 'lead_campaign', before.id,
        { companyId: before.marketing_company_id, meta: before.meta_campaign_ids }, { companyId: after.marketing_company_id, meta: after.meta_campaign_ids });
      return after;
    });
    if ((row.meta_campaign_ids ?? []).length) {
      const { syncMeta } = await import('./meta_sync.ts');
      await syncMeta(db, clock(), { campaignId: row.id, deadlineMs: 8000 }).catch(() => undefined);
    }
    return ok({ campaign: { id: row.id, name: row.name, companyId: row.marketing_company_id, metaCampaignIds: row.meta_campaign_ids } });
  });

  // ------------------------------------------------------------------ the company's file (076)
  const FILE_KINDS = ['contract', 'financial_plan', 'execution_vision', 'logo'] as const;
  const FILE_MIMES = ['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];

/** an uploaded company file: its name, type and bytes — an image for the logo, a PDF for the documents, at most 3 MB,
 *  and the content must be what it says (a PDF starts with %PDF, an image with its own signature) */
function readCompanyFile(body: unknown, kind: string): { name: string; mime: string; data: Buffer } {
  const b = obj(body);
  const name = str(b, 'fileName', { min: 1, max: 200 })!.trim();
  const mime = String(b.mime ?? '');
  if (!FILE_MIMES.includes(mime) || (kind === 'logo' ? mime === 'application/pdf' : mime !== 'application/pdf')) {
    throw invalid(kind === 'logo' ? 'اللوجو لازم يكون صورة' : 'المستند لازم يكون ملف PDF', { field: 'mime' });
  }
  const data = Buffer.from(String(b.data ?? ''), 'base64');
  if (!data.length || data.length > 3 * 1024 * 1024) throw invalid('الملف فاضي أو أكبر من 3 ميجا', { field: 'data' });
  const magic = data.subarray(0, 12).toString('latin1');
  const okMagic = mime === 'application/pdf' ? magic.startsWith('%PDF') : mime === 'image/png' ? magic.startsWith('\x89PNG')
    : mime === 'image/jpeg' ? data[0] === 0xff && data[1] === 0xd8 : magic.startsWith('RIFF') && magic.slice(8, 12) === 'WEBP';
  if (!okMagic) throw invalid('محتوى الملف مش مطابق لنوعه', { field: 'data' });
  return { name, mime, data };
}

  /** the choices of a company's file: المدير العام (a general manager / the owner), المدير المباشر (an «مسؤول إداري»), the campaigns */
  async function companyOptions() {
    const campaigns = await db.query(`SELECT id, name, active, marketing_company_id FROM lead_campaigns ORDER BY active DESC, created_at DESC`);
    const people = await db.query(`SELECT e.id, e.full_name, e.role_key, e.position_key, ${adminOfficerSql('e')} AS admin_officer FROM employees e
                                    WHERE e.status = 'active' AND (e.legacy_fields->>'status') IS DISTINCT FROM 'تم التصفيه' ORDER BY e.full_name`);
    return {
      generalManagers: people.rows.filter((e) => ['manager', 'owner'].includes(e.role_key)).map((e) => ({ id: e.id, name: e.full_name })),
      managers: people.rows.filter((e) => e.admin_officer === true).map((e) => ({ id: e.id, name: e.full_name })),
      campaigns: campaigns.rows.map((x) => ({ id: x.id, name: x.name, active: x.active, companyId: x.marketing_company_id })),
    };
  }

  r.get('/marketing-companies/options', async (req) => {
    await admin(req);
    return ok({ options: await companyOptions() });
  });

  r.get('/marketing-companies/:id', async (req) => {
    await admin(req);
    if (!isUuid(req.params.id)) throw notFound();
    const c = await one(db, `
      SELECT c.*, g.full_name AS gm_name, m.full_name AS manager_name
        FROM marketing_companies c LEFT JOIN employees g ON g.id = c.general_manager_id LEFT JOIN employees m ON m.id = c.manager_id
       WHERE c.id = $1`, [req.params.id]);
    if (!c) throw notFound();
    const files = await db.query(`SELECT kind, file_name, mime, uploaded_at, octet_length(data) AS bytes FROM marketing_company_files WHERE company_id = $1`, [c.id]);
    const options = await companyOptions();
    return ok({
      company: {
        id: c.id, name: c.name, kind: c.kind, defaultPct: Number(c.default_pct), monthlyFee: Number(c.monthly_fee), phone: c.phone, status: c.status,
        loginEmail: c.login_email, loginPhone: c.login_phone, hasLogin: !!c.password_hash, mustChangePassword: c.must_change_password,
        generalManager: c.general_manager_id ? { id: c.general_manager_id, name: c.gm_name } : null,
        manager: c.manager_id ? { id: c.manager_id, name: c.manager_name } : null,
        contractDate: c.contract_date ? new Date(c.contract_date).toISOString().slice(0, 10) : null,
        deviceLock: c.device_lock, deviceLabel: c.device_id ? (c.device_label ?? 'جهاز') : null, loginActive: c.login_active,
        campaignIds: options.campaigns.filter((x) => x.companyId === c.id).map((x) => x.id),
        files: Object.fromEntries(files.rows.map((f) => [f.kind, { fileName: f.file_name, mime: f.mime, bytes: Number(f.bytes), uploadedAt: iso(f.uploaded_at) }])),
      },
      options,
    });
  });

  /** المدير العام / المدير المباشر / تاريخ التعاقد / its campaigns */
  r.patch('/marketing-companies/:id/profile', async (req) => {
    const a = await admin(req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const person = async (k: string, ok: (e: any) => boolean, msg: string) => {
      if (b[k] === undefined) return undefined;
      if (b[k] === null || b[k] === '') return null;
      const id = String(b[k]);
      const e = isUuid(id) ? await one(db, `SELECT e.id, e.role_key, e.position_key, ${adminOfficerSql('e')} AS admin_officer FROM employees e
                                             WHERE e.id = $1 AND e.status = 'active'`, [id]) : null;
      if (!e || !ok(e)) throw invalid(msg, { field: k });
      return id;
    };
    const gm = await person('generalManagerId', (e) => ['manager', 'owner'].includes(e.role_key), 'المدير العام لازم يكون مدير عام أو المالك');
    const mgr = await person('managerId', (e) => e.admin_officer === true, 'المدير المباشر لازم يكون مسؤول إداري');
    const contract = b.contractDate === null || b.contractDate === '' ? null : date(b, 'contractDate', true);
    let campaigns: string[] | undefined;
    if (b.campaignIds !== undefined) {
      if (!Array.isArray(b.campaignIds) || b.campaignIds.length > 200 || b.campaignIds.some((x) => !isUuid(String(x)))) throw invalid('الحملات مش صحيحة', { field: 'campaignIds' });
      campaigns = [...new Set(b.campaignIds.map(String))];
    }
    await db.tx(async (q) => {
      const before = await one(q, `SELECT * FROM marketing_companies WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!before) throw notFound();
      const set: Record<string, unknown> = {};
      if (gm !== undefined) set.general_manager_id = gm;
      if (mgr !== undefined) set.manager_id = mgr;
      if (b.contractDate !== undefined) set.contract_date = contract ?? null;
      if (typeof b.deviceLock === 'boolean') set.device_lock = b.deviceLock;
      if (b.resetDevice === true || b.deviceLock === false) { set.device_id = null; set.device_label = null; }
      if (typeof b.loginActive === 'boolean') set.login_active = b.loginActive;
      const keys = Object.keys(set);
      if (keys.length) await q.query(`UPDATE marketing_companies SET ${keys.map((k, i) => `${k} = $${i + 2}`).join(', ')} WHERE id = $1`, [before.id, ...keys.map((k) => set[k])]);
      // login turned off / its device freed: every device signs out
      if (set.login_active === false || set.device_id === null && before.device_id) {
        await q.query(`UPDATE partner_sessions SET revoked_at = now() WHERE company_id = $1 AND revoked_at IS NULL`, [before.id]);
      }
      if (campaigns) {
        // its campaigns = exactly these. A campaign runs with ONE company only: one that another company runs is refused
        // (it is never moved silently) — free it from that company's file first. Locked so two saves cannot both take it.
        const taken = campaigns.length ? (await q.query(
          `SELECT cp.name, mc.name AS company FROM lead_campaigns cp JOIN marketing_companies mc ON mc.id = cp.marketing_company_id
            WHERE cp.id = ANY($1::uuid[]) AND cp.marketing_company_id <> $2 ORDER BY cp.name FOR UPDATE OF cp`, [campaigns, before.id])).rows : [];
        if (taken.length) {
          throw new AppError('conflict', `الحملة دي شغالة مع شركة تانية: ${taken.map((t) => `${t.name} (${t.company})`).join('، ')}`,
            { reason: 'campaign_taken', field: 'campaignIds' });
        }
        await q.query(`UPDATE lead_campaigns SET marketing_company_id = NULL WHERE marketing_company_id = $1 AND NOT id = ANY($2::uuid[])`, [before.id, campaigns]);
        await q.query(`UPDATE lead_campaigns SET marketing_company_id = $1 WHERE id = ANY($2::uuid[]) AND marketing_company_id IS NULL`, [before.id, campaigns]);
      }
      await audit(q, a.id, 'marketing_company.profile', 'marketing_company', before.id,
        { gm: before.general_manager_id, manager: before.manager_id, contract: before.contract_date }, { ...set, campaigns });
    });
    return ok({ ok: true });
  });

  r.put('/marketing-companies/:id/files/:kind', async (req) => {
    const a = await admin(req);
    const kind = req.params.kind as (typeof FILE_KINDS)[number];
    if (!isUuid(req.params.id) || !FILE_KINDS.includes(kind)) throw notFound();
    const { name, mime, data } = readCompanyFile(req.body, kind);
    if (!(await one(db, `SELECT 1 FROM marketing_companies WHERE id = $1`, [req.params.id]))) throw notFound();
    const fileId = await storeFile(db, { category: 'marketing_company_file', bytes: data, mime, name, createdBy: a.id });
    await db.tx(async (q) => {
      if (!(await one(q, `SELECT 1 FROM marketing_companies WHERE id = $1`, [req.params.id]))) throw notFound();
      await q.query(...withFile(`INSERT INTO marketing_company_files (company_id, kind, file_name, mime, data, uploaded_by) VALUES ($1,$2,$3,$4,$5,$6)
                     ON CONFLICT (company_id, kind) DO UPDATE SET file_name = EXCLUDED.file_name, mime = EXCLUDED.mime, data = EXCLUDED.data,
                       uploaded_by = EXCLUDED.uploaded_by, uploaded_at = now()`, [req.params.id, kind, name, mime, data, a.id], 'data', fileId));
      await audit(q, a.id, 'marketing_company.file', 'marketing_company', req.params.id, undefined, { kind, name, bytes: data.length });
    });
    return ok({ ok: true });
  });

  r.get('/marketing-companies/:id/files/:kind', async (req) => {
    await admin(req);
    if (!isUuid(req.params.id) || !FILE_KINDS.includes(req.params.kind as any)) throw notFound();
    const f = await one(db, `SELECT * FROM marketing_company_files WHERE company_id = $1 AND kind = $2`, [req.params.id, req.params.kind]);
    if (!f) throw notFound('مفيش ملف');
    return ok({ fileName: f.file_name, mime: f.mime, data: (await readFileBytes(db, f.data, f.data_file_id)).toString('base64') });
  });

  r.delete('/marketing-companies/:id/files/:kind', async (req) => {
    const a = await admin(req);
    if (!isUuid(req.params.id) || !FILE_KINDS.includes(req.params.kind as any)) throw notFound();
    await db.query(`DELETE FROM marketing_company_files WHERE company_id = $1 AND kind = $2`, [req.params.id, req.params.kind]);
    await audit(db, a.id, 'marketing_company.file_delete', 'marketing_company', req.params.id, undefined, { kind: req.params.kind });
    return ok({ ok: true });
  });

  // ================================================================== the company's own pages
  const partner = (req: Req) => authenticatePartner(db, req);

  /** its campaigns (linked to it) */
  const campaignsOf = async (p: Partner) => (await db.query(`
      SELECT cp.id, cp.name, cp.active, pr.name AS project_name
        FROM lead_campaigns cp LEFT JOIN commission_projects pr ON pr.id = cp.project_id
       WHERE cp.marketing_company_id = $1 ORDER BY cp.active DESC, cp.created_at DESC`, [p.companyId])).rows;

  // ------------------------------------------------------------------ its profile (like an employee's «الملف الشخصي»)
  r.get('/partner/profile', async (req) => {
    const p = await partner(req);
    const c = await one(db, `
      SELECT c.*, g.full_name AS gm_name, m.full_name AS manager_name
        FROM marketing_companies c LEFT JOIN employees g ON g.id = c.general_manager_id LEFT JOIN employees m ON m.id = c.manager_id
       WHERE c.id = $1`, [p.companyId]);
    const files = await db.query(`SELECT kind, file_name, uploaded_at FROM marketing_company_files WHERE company_id = $1`, [p.companyId]);
    return ok({
      profile: {
        name: c.name, email: c.login_email, phone: c.login_phone ?? c.phone, kind: c.kind,
        defaultPct: Number(c.default_pct), monthlyFee: Number(c.monthly_fee), status: c.status,
        contractDate: c.contract_date ? new Date(c.contract_date).toISOString().slice(0, 10) : null,
        manager: c.manager_name ?? null, generalManager: c.gm_name ?? null,
        campaigns: (await campaignsOf(p)).map((x) => ({ id: x.id, name: x.name, active: x.active })),
        files: Object.fromEntries(files.rows.map((f) => [f.kind, { fileName: f.file_name, uploadedAt: iso(f.uploaded_at) }])),
      },
    });
  });

  /** its own logo / documents (read-only) */
  r.get('/partner/files/:kind', async (req) => {
    const p = await partner(req);
    if (!['contract', 'financial_plan', 'execution_vision', 'logo'].includes(req.params.kind)) throw notFound();
    const f = await one(db, `SELECT * FROM marketing_company_files WHERE company_id = $1 AND kind = $2`, [p.companyId, req.params.kind]);
    if (!f) throw notFound('مفيش ملف');
    return ok({ fileName: f.file_name, mime: f.mime, data: (await readFileBytes(db, f.data, f.data_file_id)).toString('base64') });
  });

  /** «تعديل الحساب» → its photo: the company changes its own logo (the documents stay the office's to upload) */
  r.put('/partner/files/logo', async (req) => {
    const p = await partner(req);
    const { name, mime, data } = readCompanyFile(req.body, 'logo');
    const fileId = await storeFile(db, { category: 'marketing_company_file', bytes: data, mime, name, createdBy: null });
    await db.tx(async (q) => {
      await q.query(...withFile(`INSERT INTO marketing_company_files (company_id, kind, file_name, mime, data, uploaded_by) VALUES ($1,'logo',$2,$3,$4,NULL)
                     ON CONFLICT (company_id, kind) DO UPDATE SET file_name = EXCLUDED.file_name, mime = EXCLUDED.mime, data = EXCLUDED.data,
                       uploaded_by = NULL, uploaded_at = now()`, [p.companyId, name, mime, data], 'data', fileId));
      await audit(q, null, 'partner.logo', 'marketing_company', p.companyId, undefined, { name, bytes: data.length });
    });
    return ok({ ok: true });
  });

  // ------------------------------------------------------------------ «تعديل الحساب»: its name, mobile, e-mail (by a code)
  r.patch('/partner/account', async (req) => {
    const p = await partner(req);
    const b = obj(req.body);
    const name = b.name === undefined ? undefined : (str(b, 'name', { max: 120 }) ?? '').trim();
    if (name !== undefined && name.length < 2) throw invalid('اكتب اسم الشركة', { field: 'name' });
    const phone = b.phone === undefined ? undefined : ((str(b, 'phone', { optional: true, max: 30 }) ?? '').trim() || null);
    const norm = phone ? phoneNorm(phone) : null;
    if (phone && norm!.length < 10) throw invalid('رقم الموبايل مش صحيح', { field: 'phone' });
    const c = await db.tx(async (q) => {
      const before = await one(q, `SELECT * FROM marketing_companies WHERE id = $1 FOR UPDATE`, [p.companyId]);
      if (phone === null && !before.login_email) throw invalid('لازم يفضل إيميل أو موبايل للدخول', { field: 'phone' });
      if (phone !== undefined) await loginFree(q, null, norm, before.id);
      const row = await one(q, `UPDATE marketing_companies SET name = COALESCE($2, name),
                                  login_phone = CASE WHEN $3 THEN $4 ELSE login_phone END, login_phone_norm = CASE WHEN $3 THEN $5 ELSE login_phone_norm END
                                 WHERE id = $1 RETURNING *`, [before.id, name ?? null, phone !== undefined, phone ?? null, norm]);
      await audit(q, null, 'partner.account_edit', 'marketing_company', before.id, { name: before.name, phone: before.login_phone },
        { name: row.name, phone: row.login_phone });
      return row;
    });
    return ok({ account: { name: c.name, phone: c.login_phone, email: c.login_email } });
  });

  /** a new e-mail: a 4-digit code goes to it; it is kept only once the code is entered (POST …/email/verify) */
  r.post('/partner/account/email', async (req) => {
    const p = await partner(req);
    const email = (str(obj(req.body), 'email', { max: 160 }) ?? '').trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw invalid('الإيميل مش صحيح', { field: 'email' });
    await loginFree(db, email, null, p.companyId);
    if (!mailEnabled()) throw new AppError('unprocessable', 'الإيميل مش متظبط لسه — كلّم الإدارة', { reason: 'mail_off' });
    const recent = await one(db, `SELECT count(*)::int AS n FROM partner_email_otps WHERE company_id = $1 AND created_at > now() - interval '15 minutes'`, [p.companyId]);
    if (recent.n >= 3) throw new AppError('conflict', 'طلبت أكواد كتير — استنى ربع ساعة', { reason: 'otp_rate_limited' });
    const code = String(randomInt(0, 10_000)).padStart(4, '0');
    await db.query(`UPDATE partner_email_otps SET expires_at = now() WHERE company_id = $1 AND verified_at IS NULL AND expires_at > now()`, [p.companyId]);
    await db.query(`INSERT INTO partner_email_otps (company_id, new_email, code_hash, expires_at) VALUES ($1,$2,$3, now() + interval '10 minutes')`,
      [p.companyId, email, sha(`${p.companyId}:${email}:${code}`)]);
    const st = await one(db, `SELECT company_name_ar FROM company_settings`);
    const sent = await sendMail({ to: email, toName: p.name, ...emailChangeMail({ name: p.name, code, company: st?.company_name_ar ?? 'VALUNIVO' }) });
    if (!sent) throw new AppError('unprocessable', 'مقدرناش نبعت الكود دلوقتي — جرّب تاني', { reason: 'mail_failed' });
    return ok({ ok: true, sentTo: email.replace(/^(.).*?(@.*)$/, '$1***$2') });
  });

  r.post('/partner/account/email/verify', async (req) => {
    const p = await partner(req);
    const code = String(obj(req.body).code ?? '');
    const bad = () => new AppError('validation_failed', 'الكود غلط أو خلص وقته', { reason: 'otp_invalid', field: 'code' });
    if (!/^\d{4}$/.test(code)) throw bad();
    const email = await db.tx(async (q) => {
      const o = await one(q, `SELECT * FROM partner_email_otps WHERE company_id = $1 AND verified_at IS NULL AND expires_at > now()
                                ORDER BY created_at DESC LIMIT 1 FOR UPDATE`, [p.companyId]);
      if (!o || o.attempts >= 5) return null;
      if (o.code_hash !== sha(`${p.companyId}:${o.new_email}:${code}`)) {
        await q.query(`UPDATE partner_email_otps SET attempts = attempts + 1 WHERE id = $1`, [o.id]);
        return null;
      }
      await loginFree(q, o.new_email, null, p.companyId);
      await q.query(`UPDATE partner_email_otps SET verified_at = now() WHERE id = $1`, [o.id]);
      const before = await one(q, `SELECT login_email FROM marketing_companies WHERE id = $1`, [p.companyId]);
      await q.query(`UPDATE marketing_companies SET login_email = $2 WHERE id = $1`, [p.companyId, o.new_email]);
      await audit(q, null, 'partner.email_changed', 'marketing_company', p.companyId, { email: before.login_email }, { email: o.new_email });
      return o.new_email as string;
    });
    if (!email) throw bad();
    return ok({ email });
  });

  // ------------------------------------------------------------------ its bell: what happened on its campaigns' leads
  r.get('/partner/notifications', async (req) => {
    const p = await partner(req);
    const now = clock();
    const seen = (await one(db, `SELECT notifications_seen_at FROM marketing_companies WHERE id = $1`, [p.companyId]))?.notifications_seen_at ?? null;
    const rows = await db.query(`
      SELECT * FROM (
        SELECT 'lead' AS kind, l.id AS lead_id, l.full_name AS lead_name, cp.name AS campaign, NULL::text AS stage_name, NULL::text AS comment,
               NULL::text AS by_name, l.created_at AS at
          FROM leads l LEFT JOIN lead_campaigns cp ON cp.id = l.campaign_id
         WHERE ${SEES(1)} AND l.created_at > $2::timestamptz - interval '30 days'
        UNION ALL
        SELECT 'action', l.id, l.full_name, cp.name, st.name_ar, a.comment, e.full_name, a.created_at
          FROM lead_actions a JOIN leads l ON l.id = a.lead_id LEFT JOIN lead_campaigns cp ON cp.id = l.campaign_id
          LEFT JOIN lead_stages st ON st.key = a.stage LEFT JOIN employees e ON e.id = a.by_id
         WHERE ${SEES(1)} AND a.parent_id IS NULL AND a.created_at > $2::timestamptz - interval '30 days'
      ) z ORDER BY at DESC LIMIT 60`, [p.companyId, now]);
    const items = rows.rows.map((x) => ({
      kind: x.kind, leadId: x.lead_id, at: iso(x.at), unread: !seen || new Date(x.at) > new Date(seen),
      title: x.kind === 'lead' ? `ليد جديد: ${x.lead_name}` : `${x.lead_name}: ${x.stage_name ?? 'متابعة'}`,
      body: x.kind === 'lead' ? (x.campaign ?? '') : [x.by_name, x.comment].filter(Boolean).join(' — '),
    }));
    return ok({ items, unread: items.filter((i) => i.unread).length });
  });

  r.post('/partner/notifications/seen', async (req) => {
    const p = await partner(req);
    await db.query(`UPDATE marketing_companies SET notifications_seen_at = $2 WHERE id = $1`, [p.companyId, clock()]);
    return ok({ ok: true });
  });

  r.get('/partner/meta', async (req) => {
    const p = await partner(req);
    return ok({
      company: { id: p.companyId, name: p.name },
      campaigns: (await campaignsOf(p)).map((c) => ({ id: c.id, name: c.name, active: c.active, project: c.project_name })),
      stages: (await stagesOf(db)).map(stageShape),
    });
  });

  r.get('/partner/dashboard', async (req) => {
    const p = await partner(req);
    const now = clock();
    const campaign = req.query.get('campaignId');
    const P: unknown[] = [p.companyId, now];
    let only = '';
    if (campaign && isUuid(campaign)) { P.push(campaign); only = ` AND l.campaign_id = $${P.length}`; }
    const base = `FROM leads l LEFT JOIN lead_campaigns cp ON cp.id = l.campaign_id WHERE ${SEES(1)}${only} AND $2::timestamptz IS NOT NULL`;
    // «النهارده / الأسبوع / الشهر» in Cairo time
    const DAY = `date_trunc('day', $2::timestamptz AT TIME ZONE 'Africa/Cairo')`;
    const counts = await one(db, `
      SELECT count(*) FILTER (WHERE l.created_at AT TIME ZONE 'Africa/Cairo' >= ${DAY})::int AS today,
             count(*) FILTER (WHERE l.created_at AT TIME ZONE 'Africa/Cairo' >= ${DAY} - interval '6 days')::int AS week,
             count(*) FILTER (WHERE l.created_at AT TIME ZONE 'Africa/Cairo' >= date_trunc('month', $2::timestamptz AT TIME ZONE 'Africa/Cairo'))::int AS month,
             count(*)::int AS total,
             count(*) FILTER (WHERE st.kind IN ('reserve', 'won') OR EXISTS (SELECT 1 FROM deals d WHERE d.lead_id = l.id AND d.stage = 'won'))::int AS closed
        FROM leads l LEFT JOIN lead_campaigns cp ON cp.id = l.campaign_id LEFT JOIN lead_stages st ON st.key = l.stage
       WHERE ${SEES(1)}${only}`, P);
    const days = await db.query(`
      SELECT to_char(d, 'YYYY-MM-DD') AS day,
             (SELECT count(*) ${base} AND (l.created_at AT TIME ZONE 'Africa/Cairo')::date = d)::int AS leads
        FROM generate_series((${DAY} - interval '6 days')::date, ${DAY}::date, interval '1 day') d ORDER BY d`, P);
    const pipe = await db.query(`SELECT l.stage, count(*)::int AS n ${base} GROUP BY l.stage`, P);
    const stages = (await stagesOf(db)).map(stageShape);
    const byStage = new Map(pipe.rows.map((x) => [x.stage, x.n]));
    const perCampaign = await db.query(`
      SELECT cp.id, cp.name, count(l.id)::int AS leads,
             count(l.id) FILTER (WHERE l.created_at AT TIME ZONE 'Africa/Cairo' >= date_trunc('month', $2::timestamptz AT TIME ZONE 'Africa/Cairo'))::int AS month,
             count(l.id) FILTER (WHERE st.kind IN ('reserve', 'won') OR EXISTS (SELECT 1 FROM deals d WHERE d.lead_id = l.id AND d.stage = 'won'))::int AS closed,
             count(l.id) FILTER (WHERE st.kind = 'lost')::int AS lost
        FROM lead_campaigns cp LEFT JOIN leads l ON l.campaign_id = cp.id LEFT JOIN lead_stages st ON st.key = l.stage
       WHERE cp.marketing_company_id = $1 GROUP BY cp.id, cp.name, cp.created_at ORDER BY leads DESC, cp.created_at DESC`, [p.companyId, now]);
    const latest = await db.query(`SELECT l.*, cp.name AS campaign_name, e.full_name AS assigned_name, st.name_ar AS stage_name, st.color AS stage_color, st.kind AS stage_kind
        FROM leads l LEFT JOIN lead_campaigns cp ON cp.id = l.campaign_id LEFT JOIN employees e ON e.id = l.assigned_to
        LEFT JOIN lead_stages st ON st.key = l.stage WHERE ${SEES(1)}${only} AND $2::timestamptz IS NOT NULL ORDER BY l.created_at DESC LIMIT 10`, P);
    return ok({
      counts,
      created7: days.rows,
      pipeline: stages.filter((s) => s.active || byStage.has(s.key)).map((s) => ({ key: s.key, name: s.name, color: s.color, kind: s.kind, count: byStage.get(s.key) ?? 0 })),
      campaigns: perCampaign.rows,
      latest: latest.rows.map(leadShape),
    });
  });

  const leadShape = (l: any) => ({
    id: l.id, refNo: Number(l.ref_no), fullName: l.full_name, phone: l.phone, email: l.email, notes: l.notes,
    campaign: l.campaign_id ? { id: l.campaign_id, name: l.campaign_name } : null,
    stage: { key: l.stage, name: l.stage_name ?? l.stage, color: l.stage_color, kind: l.stage_kind },
    salesman: l.assigned_name ?? null,
    closed: l.stage_kind === 'reserve' || l.stage_kind === 'won' || !!l.deal_won,
    addedByUs: !!l.partner_company_id, createdAt: iso(l.created_at), lastActionAt: iso(l.last_action_at),
  });

  r.get('/partner/leads', async (req) => {
    const p = await partner(req);
    const P: unknown[] = [p.companyId];
    const where = [SEES(1)];
    const qtext = (req.query.get('q') ?? '').trim().slice(0, 60);
    if (qtext) {
      P.push(`%${qtext.replace(/[%_\\]/g, (c) => '\\' + c)}%`, phoneNorm(qtext));
      where.push(`(l.full_name ILIKE $${P.length - 1} OR (length($${P.length}) >= 4 AND l.phone_norm LIKE '%' || $${P.length} || '%'))`);
    }
    const campaign = req.query.get('campaignId');
    if (campaign && isUuid(campaign)) { P.push(campaign); where.push(`l.campaign_id = $${P.length}`); }
    const stage = req.query.get('stage');
    if (stage && /^[a-z0-9_]{1,40}$/.test(stage)) { P.push(stage); where.push(`l.stage = $${P.length}`); }
    const page = Math.max(1, Math.min(500, Number(req.query.get('page') ?? 1) || 1));
    const size = 30;
    const W = where.map((w) => `(${w})`).join(' AND ');
    const total = await one(db, `SELECT count(*)::int AS n FROM leads l LEFT JOIN lead_campaigns cp ON cp.id = l.campaign_id WHERE ${W}`, P);
    const rows = await db.query(`
      SELECT l.*, cp.name AS campaign_name, e.full_name AS assigned_name, st.name_ar AS stage_name, st.color AS stage_color, st.kind AS stage_kind,
             EXISTS (SELECT 1 FROM deals d WHERE d.lead_id = l.id AND d.stage = 'won') AS deal_won
        FROM leads l LEFT JOIN lead_campaigns cp ON cp.id = l.campaign_id LEFT JOIN employees e ON e.id = l.assigned_to
        LEFT JOIN lead_stages st ON st.key = l.stage
       WHERE ${W} ORDER BY l.created_at DESC, l.id LIMIT ${size} OFFSET ${(page - 1) * size}`, P);
    return ok({ leads: rows.rows.map(leadShape), total: total.n, page, pages: Math.max(1, Math.ceil(total.n / size)) });
  });

  r.get('/partner/leads/:id', async (req) => {
    const p = await partner(req);
    if (!isUuid(req.params.id)) throw notFound();
    const l = await one(db, `
      SELECT l.*, cp.name AS campaign_name, e.full_name AS assigned_name, st.name_ar AS stage_name, st.color AS stage_color, st.kind AS stage_kind,
             EXISTS (SELECT 1 FROM deals d WHERE d.lead_id = l.id AND d.stage = 'won') AS deal_won
        FROM leads l LEFT JOIN lead_campaigns cp ON cp.id = l.campaign_id LEFT JOIN employees e ON e.id = l.assigned_to
        LEFT JOIN lead_stages st ON st.key = l.stage
       WHERE l.id = $2 AND ${SEES(1)}`, [p.companyId, req.params.id]);
    if (!l) throw notFound('Lead not found');   // 404 for others' leads: ids cannot be probed
    // the follow-ups and comments (who, when, the stage it moved to) — read-only
    const acts = await db.query(`
      SELECT a.id, a.parent_id, a.stage, a.comment, a.next_at, a.auto, a.created_at, e.full_name AS by_name, st.name_ar AS stage_name, st.color AS stage_color
        FROM lead_actions a LEFT JOIN employees e ON e.id = a.by_id LEFT JOIN lead_stages st ON st.key = a.stage
       WHERE a.lead_id = $1 ORDER BY a.created_at DESC LIMIT 200`, [l.id]);
    const deals = await db.query(`SELECT ref_no, title, stage, created_at, closed_at FROM deals WHERE lead_id = $1 ORDER BY created_at DESC`, [l.id]);
    const reserved = await one(db, `SELECT count(*)::int AS n FROM ex_units WHERE lead_id = $1 AND status NOT IN ('cancelled')`, [l.id]);
    return ok({
      lead: { ...leadShape(l), closed: leadShape(l).closed || reserved.n > 0 },
      actions: acts.rows.map((a) => ({ id: a.id, parentId: a.parent_id, comment: a.comment, by: a.by_name ?? 'النظام', at: iso(a.created_at),
        nextAt: iso(a.next_at), auto: a.auto, stage: a.stage ? { key: a.stage, name: a.stage_name ?? a.stage, color: a.stage_color } : null })),
      deals: deals.rows.map((d) => ({ refNo: Number(d.ref_no), title: d.title, stage: d.stage, createdAt: iso(d.created_at), closedAt: iso(d.closed_at) })),
      reserved: reserved.n > 0,
    });
  });

  /** a lead the company adds to one of its campaigns: distributed as that campaign says (one / online / turn) */
  r.post('/partner/leads', async (req) => {
    const p = await partner(req);
    return partnerAddLead(db, p, obj(req.body), clock());
  });
};

/** a lead the marketing company adds on one of its campaigns (its own page or the sales dashboard's «إنشاء عميل محتمل») */
export async function partnerAddLead(db: Db, p: { companyId: string; name: string }, b: Record<string, unknown>, now: Date) {
    const campaignId = String(b.campaignId ?? '');
    if (!isUuid(campaignId)) throw invalid('اختار الحملة', { field: 'campaignId' });
    const c = await one(db, `SELECT * FROM lead_campaigns WHERE id = $1 AND marketing_company_id = $2 AND active`, [campaignId, p.companyId]);
    if (!c) throw invalid('اختار حملة من حملاتك', { field: 'campaignId' });
    const x = readLead({ fullName: b.fullName, phone: b.phone, email: b.email, notes: b.notes, kind: 'fresh' });
    x.campaignId = c.id; x.projectId = c.project_id ?? null; x.channelId = c.channel_id ?? null;
    const lead = await db.tx(async (q) => {
      if (await one(q, `SELECT 1 FROM leads WHERE campaign_id = $1 AND phone_norm = $2 AND created_at > $3::timestamptz - interval '1 day'`, [c.id, phoneNorm(x.phone), now])) {
        throw conflict('الرقم ده اتضاف على الحملة دي النهارده');
      }
      // «الليد ده موجود» (never whose) — «إضافة» adds it as a repeat that is NOT distributed: the watchers are told
      const dup = await refuseExisting(q, null, [x.phone, ...x.extraPhones], b.confirmDuplicate === true);
      let l: any;
      if (dup) {
        l = (await insertLead(q, null, x, null, now, 'form', [], { confirmedRepeat: true })).lead;
        for (const to of await duplicateWatchers(q)) {
          await notify(q, { to, type: 'lead_duplicate_partner', title: `شركة التسويق ${p.name} ضافت ليد وكان موجود`,
            body: `${x.fullName} (${x.phone}) — حملة ${c.name}. مش متوزع؛ قرّر تعمل فيه إيه`, entity: 'lead', entityId: l.id, dedupeKey: `lead:${l.id}:partner_dup` });
        }
      } else {
        l = await deliverLead(q, x, (c.assign_mode ?? 'turn') as RouteMode, c.form_assignees ?? [], now, p.name, c.name);
      }
      await q.query(`UPDATE leads SET partner_company_id = $2 WHERE id = $1`, [l.id, p.companyId]);
      await audit(q, null, 'partner.lead_create', 'lead', l.id, undefined, { company: p.companyId, campaign: c.id });
      return l;
    });
    return ok({ lead: { id: lead.id, refNo: Number(lead.ref_no) } }, 201);
  }

/**
 * The company's notifications (the same page as everyone's): what happened on its campaigns' leads in the last 30 days
 * (a new lead, a salesman's follow-up) is kept as rows it reads / deletes like an employee's; once deleted, never back.
 */
export async function syncPartnerNotifications(q: Q, companyId: string, now: Date) {
  await q.query(`
    INSERT INTO partner_notifications (company_id, key, type, title, body, entity, entity_id, created_at, read_at)
    SELECT $1, z.key, z.type, z.title, z.body, 'lead', z.lead_id::text, z.at,
           CASE WHEN mc.notifications_seen_at IS NOT NULL AND z.at <= mc.notifications_seen_at THEN mc.notifications_seen_at END
      FROM (
        SELECT 'lead:' || l.id AS key, 'lead_partner_new' AS type, 'ليد جديد: ' || l.full_name AS title, COALESCE(cp.name, '') AS body,
               l.id AS lead_id, l.created_at AS at
          FROM leads l LEFT JOIN lead_campaigns cp ON cp.id = l.campaign_id
         WHERE ${SEES(1)} AND l.created_at > $2::timestamptz - interval '30 days'
        UNION ALL
        SELECT 'action:' || a.id, 'lead_partner_action', l.full_name || ': ' || COALESCE(st.name_ar, 'متابعة'),
               concat_ws(' — ', e.full_name, NULLIF(a.comment, '')), l.id, a.created_at
          FROM lead_actions a JOIN leads l ON l.id = a.lead_id LEFT JOIN lead_campaigns cp ON cp.id = l.campaign_id
          LEFT JOIN lead_stages st ON st.key = a.stage LEFT JOIN employees e ON e.id = a.by_id
         WHERE ${SEES(1)} AND a.parent_id IS NULL AND NOT a.auto AND a.created_at > $2::timestamptz - interval '30 days'
      ) z CROSS JOIN marketing_companies mc
     WHERE mc.id = $1
    ON CONFLICT (company_id, key) DO NOTHING`, [companyId, now]);
}

/** Meta campaign a lead came from: counted (and whether it was taken) so the settings can offer to link it */
export async function seeMetaCampaign(q: Q, id: string, name: string, skipped: boolean) {
  if (!META_ID.test(id)) return;
  await q.query(`INSERT INTO meta_seen_campaigns (campaign_id, name, leads, skipped, last_at) VALUES ($1,$2,1,$3,now())
                 ON CONFLICT (campaign_id) DO UPDATE SET name = CASE WHEN EXCLUDED.name <> '' THEN EXCLUDED.name ELSE meta_seen_campaigns.name END,
                   leads = meta_seen_campaigns.leads + 1, skipped = meta_seen_campaigns.skipped + EXCLUDED.skipped, last_at = now()`,
    [id, name.slice(0, 200), skipped ? 1 : 0]);
}
