import { ok, type Module } from '../ctx.ts';
import { one } from '../db.ts';
import { forbidden } from '../http/errors.ts';
import { obj, str } from '../http/validate.ts';
import { audit, authenticate, has, type Actor } from '../auth/context.ts';

const PHONE = /^\+?[0-9]{8,15}$/;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
export const canEditCompany = (a: Actor) => has(a, 'settings.manage') || has(a, 'attendance.config');

/** Company information & office location page (offices = work_locations, used by geofencing). */
export const companyModule: Module = (r, { db }) => {
  r.get('/company', async (req) => {
    const a = await authenticate(db, req);
    const s = await one(db, `SELECT c.*, e.full_name AS updated_by_name FROM company_settings c LEFT JOIN employees e ON e.id = c.updated_by`);
    const offices = (await db.query(`SELECT * FROM work_locations ORDER BY active DESC, name`)).rows;
    return ok({
      company: {
        nameAr: s.company_name_ar, nameEn: s.company_name_en, description: s.description, address: s.address,
        phone: s.contact_phone, email: s.contact_email, currency: s.currency, timezone: s.timezone,
        updatedAt: s.updated_at, updatedByName: s.updated_by_name,
      },
      offices, canEdit: canEditCompany(a), trackingEnabled: s.tracking_enabled, awayMarginM: s.away_margin_m,
    });
  });

  r.put('/company', async (req) => {
    const a = await authenticate(db, req);
    if (!canEditCompany(a)) throw forbidden();
    const b = obj(req.body);
    const before = await one(db, `SELECT company_name_ar, company_name_en, description, address, contact_phone, contact_email FROM company_settings`);
    const s = await one(db, `UPDATE company_settings SET company_name_ar = $1, company_name_en = $2, description = $3, address = $4,
        contact_phone = $5, contact_email = $6, updated_by = $7, updated_at = now() RETURNING *`, [
      str(b, 'nameAr', { optional: true, min: 2, max: 120 }) ?? before.company_name_ar,
      str(b, 'nameEn', { optional: true, min: 2, max: 120 }) ?? before.company_name_en,
      str(b, 'description', { optional: true, max: 2000 }) ?? before.description,
      str(b, 'address', { optional: true, max: 500 }) ?? before.address,
      str(b, 'phone', { optional: true, pattern: PHONE }) ?? before.contact_phone,
      str(b, 'email', { optional: true, pattern: EMAIL, max: 160 })?.toLowerCase() ?? before.contact_email,
      a.id]);
    await audit(db, a.id, 'company.update', 'settings', null, before, {
      company_name_ar: s.company_name_ar, company_name_en: s.company_name_en, description: s.description,
      address: s.address, contact_phone: s.contact_phone, contact_email: s.contact_email });
    return ok({ ok: true });
  });
};
