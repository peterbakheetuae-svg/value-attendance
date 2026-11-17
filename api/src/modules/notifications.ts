import { ok, type Module } from '../ctx.ts';
import { sweep } from './tracking.ts';
import { notFound } from '../http/errors.ts';
import { isUuid } from '../http/validate.ts';
import { authenticate } from '../auth/context.ts';
import { syncPartnerNotifications } from './partners.ts';

export const notificationsModule: Module = (r, { db, clock }) => {
  r.get('/notifications', async (req) => {
    const a = await authenticate(db, req);
    const unreadOnly = req.query.get('unread') === '1';
    if (a.partner) {
      // a marketing company: its own kept rows (filled from its campaigns' leads)
      await syncPartnerNotifications(db, a.partner, clock());
      const rows = await db.query(`SELECT id, type, title, body, entity, entity_id, read_at, created_at FROM partner_notifications
        WHERE company_id = $1 AND NOT deleted ${unreadOnly ? 'AND read_at IS NULL' : ''} ORDER BY created_at DESC LIMIT 100`, [a.partner]);
      const unread = await db.query(`SELECT count(*)::int AS n FROM partner_notifications WHERE company_id = $1 AND NOT deleted AND read_at IS NULL`, [a.partner]);
      return ok({ notifications: rows.rows, unread: unread.rows[0].n });
    }
    await sweep(db, clock()).catch(() => { /* reminders must never break the page */ });
    const rows = await db.query(`SELECT id, type, title, body, entity, entity_id, read_at, created_at FROM notifications
      WHERE recipient_id = $1 ${unreadOnly ? 'AND read_at IS NULL' : ''} ORDER BY created_at DESC LIMIT 100`, [a.id]);
    const unread = await db.query(`SELECT count(*)::int AS n FROM notifications WHERE recipient_id = $1 AND read_at IS NULL`, [a.id]);
    return ok({ notifications: rows.rows, unread: unread.rows[0].n });
  });
  r.post('/notifications/:id/read', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const r2 = a.partner
      ? await db.query(`UPDATE partner_notifications SET read_at = COALESCE(read_at, now()) WHERE id = $1 AND company_id = $2 AND NOT deleted`, [req.params.id, a.partner])
      : await db.query(`UPDATE notifications SET read_at = COALESCE(read_at, now()) WHERE id = $1 AND recipient_id = $2`, [req.params.id, a.id]);
    if (!r2.rowCount) throw notFound();
    return ok({ ok: true });
  });
  r.post('/notifications/read-all', async (req) => {
    const a = await authenticate(db, req);
    if (a.partner) await db.query(`UPDATE partner_notifications SET read_at = now() WHERE company_id = $1 AND read_at IS NULL`, [a.partner]);
    else await db.query(`UPDATE notifications SET read_at = now() WHERE recipient_id = $1 AND read_at IS NULL`, [a.id]);
    return ok({ ok: true });
  });
};
