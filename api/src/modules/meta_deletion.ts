import type { Db } from '../db.ts';
import { one } from '../db.ts';
import { audit } from '../auth/context.ts';
import { callbackPage, metaUserHash } from '../lib/meta-oauth.ts';

/**
 * Meta Data Deletion Requests (Phase A; migration 092 meta_data_deletion_requests).
 *
 * What this app holds from Facebook about the person who sends the request (identified by Meta only by an app-scoped
 * user id in the signed request):
 *   - if that person is the one who connected the office through Facebook Login: the saved user access token
 *     (integrations.access_token), the hash of their app-scoped id (integrations.meta_user_hash) and the page access
 *     tokens obtained through them with the pages' ids and names (meta_pages). All of it is deleted here.
 *   - nothing else is stored with a Facebook user id. Leads that people submitted through the company's Lead Ads forms
 *     are stored as the company's lead records (name, phone, form answers) without any Facebook user id, so a request
 *     carrying an app-scoped id cannot be matched to them; they are not deleted by this request, and the status page
 *     says so plainly.
 *
 * Every request is recorded first (status «pending») and only then processed, so a failure never loses it: the
 * scheduler (POST /integrations/meta/sync/run) retries pending requests.
 */

export type DeletionStatus = 'pending' | 'completed' | 'no_data_found';

/** record a verified request; returns its confirmation code */
export async function recordDeletionRequest(db: Db, userId: string, code: string, now: Date): Promise<void> {
  await db.query(`INSERT INTO meta_data_deletion_requests (code, received_at, status, user_hash) VALUES ($1, $2, 'pending', $3)`,
    [code, now, metaUserHash(userId)]);
}

/**
 * Process one pending request: if its person is the one whose token the office holds, delete that token, the hash and
 * every page token (meta_pages); otherwise nothing of theirs is held. Either way the request is closed with exactly
 * what was done, and the hash is cleared. Idempotent: a request that is no longer pending is left as it is.
 */
export async function processDeletionRequest(db: Db, code: string, now: Date): Promise<DeletionStatus | null> {
  return db.tx(async (q) => {
    const req = await one(q, `SELECT code, user_hash FROM meta_data_deletion_requests WHERE code = $1 AND status = 'pending' FOR UPDATE`, [code]);
    if (!req) return null;
    await q.query(`UPDATE meta_data_deletion_requests SET attempts = attempts + 1 WHERE code = $1`, [code]);
    const it = await one(q, `SELECT meta_user_hash FROM integrations WHERE source = 'meta' FOR UPDATE`);
    const matched = !!it?.meta_user_hash && it.meta_user_hash === req.user_hash;
    let pages = 0;
    if (matched) {
      await q.query(`UPDATE integrations SET access_token = NULL, meta_user_hash = NULL, last_error = $2, updated_at = $3 WHERE source = $1`,
        ['meta', 'فيسبوك: طلب حذف بيانات من الحساب اللي ربط المكتب — اتشال التوكن والصفحات؛ اعمل «إعادة الربط»', now]);
      pages = (await q.query(`DELETE FROM meta_pages`)).rowCount ?? 0;
    }
    const status: DeletionStatus = matched ? 'completed' : 'no_data_found';
    await q.query(`UPDATE meta_data_deletion_requests SET status = $2, user_hash = NULL, processed_at = $3, token_removed = $4, pages_removed = $5
        WHERE code = $1`, [code, status, now, matched, pages]);
    await audit(q, null, 'integration.meta_data_deletion', 'meta_data_deletion', code, undefined, { status, tokenRemoved: matched, pagesRemoved: pages });
    return status;
  });
}

/** the scheduler's retry of requests left pending by a failure (oldest first, a few per run) */
export async function processPendingDeletions(db: Db, now: Date, max = 20): Promise<{ processed: number; failed: number }> {
  const rows = (await db.query(`SELECT code FROM meta_data_deletion_requests WHERE status = 'pending' ORDER BY received_at LIMIT $1`, [max])).rows;
  let processed = 0; let failed = 0;
  for (const r of rows) {
    try { if (await processDeletionRequest(db, r.code, now)) processed++; } catch { failed++; }
  }
  return { processed, failed };
}

const LEADS_NOTE = 'الليدز اللي اتبعتت من خلال نماذج إعلانات الشركة (Lead Ads) متسجلة كسجلات عملاء عند الشركة من غير أي رقم تعريف لحساب فيسبوك، '
  + 'فالطلب ده مش بيقدر يحددها ومش بيمسحها. لو عايز تمسح بيانات بعتها في نموذج من نماذج الشركة، تواصل مع الشركة مباشرة.';

/** the human-readable status page Meta links the person to — states only what was actually done */
export async function deletionStatusPage(db: Db, code: string): Promise<{ status: number; html: string }> {
  const r = /^[0-9a-f]{24}$/.test(code)
    ? await one(db, `SELECT status, received_at, processed_at, token_removed, pages_removed FROM meta_data_deletion_requests WHERE code = $1`, [code])
    : null;
  if (!r) return { status: 404, html: callbackPage(false, 'الطلب غير موجود', 'راجع رمز التأكيد.', false) };
  const day = (d: Date) => new Date(d).toISOString().slice(0, 10);
  if (r.status === 'pending') {
    return { status: 200, html: callbackPage(false, 'طلب الحذف قيد التنفيذ',
      `استلمنا الطلب يوم ${day(r.received_at)} ولسه ما اتنفذش. هيتنفذ تلقائياً؛ ارجع للصفحة دي بعد شوية. ${LEADS_NOTE}`, false) };
  }
  if (r.status === 'completed') {
    return { status: 200, html: callbackPage(true, 'تم تنفيذ طلب الحذف',
      `يوم ${day(r.processed_at)}: اتمسح توكن الدخول اللي كان محفوظ لحسابك، واتمسح ${r.pages_removed} من توكنات الصفحات اللي اتاخدت من خلاله. ${LEADS_NOTE}`, false) };
  }
  return { status: 200, html: callbackPage(true, 'تم مراجعة طلب الحذف',
    `يوم ${day(r.processed_at)}: ما لقيناش أي بيانات دخول (توكن) محفوظة مرتبطة بحسابك، فما اتمسحش حاجة. ${LEADS_NOTE}`, false) };
}
