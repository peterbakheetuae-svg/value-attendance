import { ok, type Module } from '../ctx.ts';
import { notFound } from '../http/errors.ts';
import { isUuid } from '../http/validate.ts';
import { authenticate } from '../auth/context.ts';

export const notificationsModule: Module = (r, { db }) => {
  r.get('/notifications', async (req) => {
    const a = await authenticate(db, req);
    const unreadOnly = req.query.get('unread') === '1';
    const rows = await db.query(`SELECT id, type, title, body, entity, entity_id, read_at, created_at FROM notifications
      WHERE recipient_id = $1 ${unreadOnly ? 'AND read_at IS NULL' : ''} ORDER BY created_at DESC LIMIT 100`, [a.id]);
    const unread = await db.query(`SELECT count(*)::int AS n FROM notifications WHERE recipient_id = $1 AND read_at IS NULL`, [a.id]);
    return ok({ notifications: rows.rows, unread: unread.rows[0].n });
  });
  r.post('/notifications/:id/read', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const r2 = await db.query(`UPDATE notifications SET read_at = COALESCE(read_at, now()) WHERE id = $1 AND recipient_id = $2`, [req.params.id, a.id]);
    if (!r2.rowCount) throw notFound();
    return ok({ ok: true });
  });
  r.post('/notifications/read-all', async (req) => {
    const a = await authenticate(db, req);
    await db.query(`UPDATE notifications SET read_at = now() WHERE recipient_id = $1 AND read_at IS NULL`, [a.id]);
    return ok({ ok: true });
  });
};
