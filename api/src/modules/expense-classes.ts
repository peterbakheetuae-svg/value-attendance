import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { isUuid, obj, str } from '../http/validate.ts';
import { audit, authenticate, can, type Actor } from '../auth/context.ts';
import { canHrView, canOffice, hrDesk } from './cash.ts';

/**
 * Expense groups (level 1) and expense categories (level 2) — CLASSIFICATION METADATA ONLY (proposed migration 086).
 *
 *  - A category is one row reused by any number of groups (never copied per group). Archive / reactivate, never delete.
 *  - An expense carries at most one group and one category (both optional; old expenses stay «غير مصنف»).
 *  - Classifying / re-classifying changes those two references only: never the amount, the cashbox, a balance, the
 *    approval or payment status, a settlement or a commission (the database's cash_doc_guard keeps the money fixed too).
 *    Every change is in the audit log (before → after). Allowed in a closed fiscal year: it touches no figure of it.
 *  - Totals: posted expenses only (a reversed one nets to zero in the cashbox and is left out), dated as the cashbox
 *    dates them (COALESCE(approved_at, occurred_at), Cairo days), counted ONCE each — a category's total never goes
 *    through the group links. Only the boxes this person may see. Money of others (exclusive projects' trust, unit
 *    refunds, owners' withdrawals) is not an office expense and is neither classified nor counted here.
 *
 * Permissions (fine keys the permissions registry may add later; until then the broad one, as elsewhere):
 *  manage groups / categories → expense.classification_manage (else cash.office)
 *  re-classify a recorded expense → expense.reclassify (else cash.office); the accountant his own cashbox's ones too.
 */

const r2 = (n: number) => Math.round(n * 100) / 100;
const N = (v: unknown) => Number(v ?? 0);
const OWN = `x.ex_kind IS NULL AND x.sale_id IS NULL AND x.owner_draw_id IS NULL`;
const DATE = `COALESCE(x.approved_at, x.occurred_at)`;
const STATUSES = ['posted', 'pending_approval', 'awaiting_otp', 'rejected', 'reversed'] as const;

export async function classificationInstalled(q: Q) {
  return !!(await one(q, `SELECT to_regclass('public.expense_groups') IS NOT NULL AS ok`))?.ok;
}
async function needInstalled(q: Q) {
  if (!(await classificationInstalled(q))) {
    throw new AppError('conflict', 'تصنيف المصروفات محتاج تحديث قاعدة البيانات (086) — مستني موافقة المالك', { reason: 'classification_not_installed' });
  }
}

export const canManageClasses = (a: Actor) => can(a, 'expense.classification_manage', 'cash.office');
export const canReclassify = (a: Actor, box: string) => can(a, 'expense.reclassify', 'cash.office') || (box === 'hr' && hrDesk(a));
const boxesOf = (a: Actor) => [...(canOffice(a) ? ['office'] : []), ...(canHrView(a) ? ['hr'] : [])];

/**
 * Checks a group / category pair for a NEW assignment: each must exist and be active, and the category must be one of the
 * group's. Returns null when nothing is given. (An archived one already on an expense stays there untouched.)
 */
export async function checkClassification(q: Q, groupId: unknown, categoryId: unknown) {
  const g = groupId === undefined || groupId === null || groupId === '' ? null : String(groupId);
  const c = categoryId === undefined || categoryId === null || categoryId === '' ? null : String(categoryId);
  if (!g && !c) return { groupId: null, categoryId: null };
  if (g && !isUuid(g)) throw invalid('groupId is invalid', { field: 'groupId' });
  if (c && !isUuid(c)) throw invalid('categoryId is invalid', { field: 'categoryId' });
  if (g && !(await one(q, `SELECT 1 FROM expense_groups WHERE id = $1 AND is_active`, [g]))) throw invalid('المجموعة دي مش موجودة أو متأرشفة', { field: 'groupId' });
  if (c && !(await one(q, `SELECT 1 FROM expense_categories WHERE id = $1 AND is_active`, [c]))) throw invalid('التصنيف ده مش موجود أو متأرشف', { field: 'categoryId' });
  if (g && c && !(await one(q, `SELECT 1 FROM expense_group_categories WHERE group_id = $1 AND category_id = $2`, [g, c]))) {
    throw invalid('التصنيف ده مش ضمن المجموعة دي', { field: 'categoryId', reason: 'category_not_in_group' });
  }
  return { groupId: g, categoryId: c };
}

/** from / to (Cairo days) + status filter → SQL conditions on cash_expenses x (vals is appended to) */
function filters(req: { query: URLSearchParams }, vals: unknown[]) {
  const where: string[] = [];
  const day = (k: string) => { const v = req.query.get(k); return v && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null; };
  const from = day('from'), to = day('to');
  if (from) { vals.push(from); where.push(`${DATE} >= ($${vals.length}::date AT TIME ZONE 'Africa/Cairo')`); }
  if (to) { vals.push(to); where.push(`${DATE} < (($${vals.length}::date + 1) AT TIME ZONE 'Africa/Cairo')`); }
  const st = req.query.get('status') ?? 'posted';
  if (st !== 'all') {
    if (!(STATUSES as readonly string[]).includes(st)) throw invalid('status is invalid', { field: 'status' });
    vals.push(st); where.push(`x.status = $${vals.length}`);
  }
  return { where, from, to, status: st };
}

function nameOf(b: Record<string, unknown>, optional: boolean) {
  const v = str(b, 'name', { optional, min: 2, max: 80 });
  return v === undefined ? undefined : v.trim().replace(/\s+/g, ' ');
}

function ids(v: unknown, field: string): string[] | undefined {
  if (v === undefined) return undefined;
  if (!Array.isArray(v) || v.some((x) => typeof x !== 'string' || !isUuid(x)) || v.length > 500) throw invalid(`${field} must be a list of ids`, { field });
  return [...new Set(v as string[])];
}

const duplicateName = (e: any) => e?.code === '23505'
  ? new AppError('conflict', 'الاسم ده موجود بالفعل (نشط)', { reason: 'duplicate_name', field: 'name' }) : e;

export const expenseClassesModule: Module = (r, { db, clock }) => {
  type Kind = 'group' | 'category';
  const T = { group: 'expense_groups', category: 'expense_categories' } as const;

  /** groups + categories (with their links and totals in the viewer's boxes), search and status filter */
  r.get('/cash/expense-classes', async (req) => {
    const a = await authenticate(db, req);
    if (!boxesOf(a).length) throw forbidden();
    if (!(await classificationInstalled(db))) return ok({ installed: false, groups: [], categories: [], can: { manage: false } });
    const show = req.query.get('active') ?? 'active'; // active | archived | all
    const q = (req.query.get('q') ?? '').trim().toLowerCase();
    const vals: unknown[] = [boxesOf(a)];
    const f = filters(req, vals);
    const cond = ['x.cashbox = ANY($1::text[])', OWN, ...f.where].join(' AND ');
    const list = async (k: Kind) => {
      const col = k === 'group' ? 'expense_group_id' : 'expense_category_id';
      const rows = (await db.query(`
        SELECT t.*, COALESCE(s.total, 0) AS total, COALESCE(s.n, 0)::int AS n
          FROM ${T[k]} t
          LEFT JOIN (SELECT x.${col} AS id, sum(x.amount_egp) AS total, count(*) AS n FROM cash_expenses x WHERE ${cond} GROUP BY 1) s ON s.id = t.id
         ORDER BY t.is_active DESC, lower(t.name)`, vals)).rows;
      return rows.filter((x) => (show === 'all' || (show === 'archived' ? !x.is_active : x.is_active)) && (!q || String(x.name).toLowerCase().includes(q)
        || String(x.description).toLowerCase().includes(q)));
    };
    const links = (await db.query(`SELECT group_id, category_id FROM expense_group_categories`)).rows;
    const shape = (k: Kind) => (x: any) => ({ id: x.id, name: x.name, description: x.description, isActive: x.is_active,
      total: r2(N(x.total)), count: N(x.n), createdAt: x.created_at, updatedAt: x.updated_at,
      ...(k === 'group' ? { categoryIds: links.filter((l) => l.group_id === x.id).map((l) => l.category_id) }
        : { groupIds: links.filter((l) => l.category_id === x.id).map((l) => l.group_id) }) });
    return ok({ installed: true, currency: 'EGP', from: f.from, to: f.to, status: f.status,
      groups: (await list('group')).map(shape('group')), categories: (await list('category')).map(shape('category')),
      can: { manage: canManageClasses(a) } });
  });

  async function setLinks(q: Q, a: Actor, k: Kind, id: string, other: string[]) {
    const otherT = k === 'group' ? 'expense_categories' : 'expense_groups';
    if (other.length) {
      const found = (await q.query(`SELECT id FROM ${otherT} WHERE id = ANY($1::uuid[])`, [other])).rows.length;
      if (found !== other.length) throw invalid(k === 'group' ? 'في تصنيف مش موجود' : 'في مجموعة مش موجودة', { field: k === 'group' ? 'categoryIds' : 'groupIds' });
    }
    const [mine, theirs] = k === 'group' ? ['group_id', 'category_id'] : ['category_id', 'group_id'];
    const before = (await q.query(`SELECT ${theirs} AS x FROM expense_group_categories WHERE ${mine} = $1`, [id])).rows.map((x) => x.x as string);
    // a link is only metadata about which categories a group offers: removing one never touches a classified expense
    await q.query(`DELETE FROM expense_group_categories WHERE ${mine} = $1 AND NOT (${theirs} = ANY($2::uuid[]))`, [id, other]);
    for (const o of other) {
      await q.query(`INSERT INTO expense_group_categories (${mine}, ${theirs}, created_by) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`, [id, o, a.id]);
    }
    return before;
  }

  for (const k of ['group', 'category'] as const) {
    const path = k === 'group' ? 'groups' : 'categories';
    const linkField = k === 'group' ? 'categoryIds' : 'groupIds';

    r.post(`/cash/expense-classes/${path}`, async (req) => {
      const a = await authenticate(db, req);
      if (!canManageClasses(a)) throw forbidden();
      await needInstalled(db);
      const b = obj(req.body);
      const name = nameOf(b, false)!;
      const description = (str(b, 'description', { optional: true, max: 500 }) ?? '').trim();
      const links = ids(b[linkField], linkField) ?? [];
      const row = await db.tx(async (q) => {
        const x = await one(q, `INSERT INTO ${T[k]} (name, description, created_by, updated_by, created_at, updated_at) VALUES ($1,$2,$3,$3,$4,$4) RETURNING *`,
          [name, description, a.id, clock()]).catch((e) => { throw duplicateName(e); });
        await setLinks(q, a, k, x.id, links);
        await audit(q, a.id, `expense.${k}.create`, T[k], x.id, undefined, { name, description, [linkField]: links });
        return x;
      });
      return ok({ [k]: { id: row.id, name: row.name, description: row.description, isActive: row.is_active, [linkField]: links } }, 201);
    });

    /** edit / archive (isActive false) / reactivate (isActive true) / its links — never deleted */
    r.patch(`/cash/expense-classes/${path}/:id`, async (req) => {
      const a = await authenticate(db, req);
      if (!canManageClasses(a)) throw forbidden();
      await needInstalled(db);
      if (!isUuid(req.params.id)) throw notFound();
      const b = obj(req.body);
      const name = nameOf(b, true);
      const description = str(b, 'description', { optional: true, max: 500 });
      const active = typeof b.isActive === 'boolean' ? b.isActive : undefined;
      const links = ids(b[linkField], linkField);
      const row = await db.tx(async (q) => {
        const o = await one(q, `SELECT * FROM ${T[k]} WHERE id = $1 FOR UPDATE`, [req.params.id]);
        if (!o) throw notFound();
        const x = await one(q, `UPDATE ${T[k]} SET name = $2, description = $3, is_active = $4, updated_by = $5, updated_at = $6 WHERE id = $1 RETURNING *`,
          [o.id, name ?? o.name, description === undefined ? o.description : description.trim(), active ?? o.is_active, a.id, clock()])
          .catch((e) => { throw duplicateName(e); });
        const before = links === undefined ? undefined : await setLinks(q, a, k, o.id, links);
        await audit(q, a.id, `expense.${k}.update`, T[k], o.id,
          { name: o.name, description: o.description, isActive: o.is_active, ...(before ? { [linkField]: before } : {}) },
          { name: x.name, description: x.description, isActive: x.is_active, ...(links ? { [linkField]: links } : {}) });
        return x;
      });
      return ok({ [k]: { id: row.id, name: row.name, description: row.description, isActive: row.is_active } });
    });

    /** one group / category: its total, count, linked ones and its expenses (filters: from, to, status; newest first) */
    r.get(`/cash/expense-classes/${path}/:id`, async (req) => {
      const a = await authenticate(db, req);
      if (!boxesOf(a).length) throw forbidden();
      await needInstalled(db);
      if (!isUuid(req.params.id)) throw notFound();
      const x = await one(db, `SELECT * FROM ${T[k]} WHERE id = $1`, [req.params.id]);
      if (!x) throw notFound();
      const col = k === 'group' ? 'expense_group_id' : 'expense_category_id';
      const vals: unknown[] = [boxesOf(a), x.id];
      const f = filters(req, vals);
      const cond = ['x.cashbox = ANY($1::text[])', `x.${col} = $2`, OWN, ...f.where].join(' AND ');
      const tot = await one(db, `SELECT COALESCE(sum(x.amount_egp), 0) AS s, count(*)::int AS n FROM cash_expenses x WHERE ${cond}`, vals);
      const limit = Math.min(500, Math.max(1, Number(req.query.get('limit') ?? 200) || 200));
      const rows = (await db.query(`
        SELECT x.id, x.ref_no, x.cashbox, x.amount_egp, x.category, x.reason, x.beneficiary, x.status, ${DATE} AS at,
               x.expense_group_id, x.expense_category_id, g.name AS group_name, c.name AS category_name
          FROM cash_expenses x LEFT JOIN expense_groups g ON g.id = x.expense_group_id LEFT JOIN expense_categories c ON c.id = x.expense_category_id
         WHERE ${cond} ORDER BY ${DATE} DESC, x.ref_no DESC LIMIT ${limit}`, vals)).rows;
      // the split the other way: a group's categories / a category's groups (each expense once)
      const other = k === 'group' ? 'expense_category_id' : 'expense_group_id';
      const otherT = k === 'group' ? 'expense_categories' : 'expense_groups';
      const split = (await db.query(`SELECT x.${other} AS id, o.name, sum(x.amount_egp) AS s, count(*)::int AS n FROM cash_expenses x
          LEFT JOIN ${otherT} o ON o.id = x.${other} WHERE ${cond} GROUP BY 1, 2 ORDER BY 3 DESC`, vals)).rows;
      const linked = (await db.query(`SELECT o.id, o.name, o.is_active FROM expense_group_categories l JOIN ${otherT} o
          ON o.id = l.${k === 'group' ? 'category_id' : 'group_id'} WHERE l.${k === 'group' ? 'group_id' : 'category_id'} = $1 ORDER BY lower(o.name)`, [x.id])).rows;
      return ok({ currency: 'EGP', from: f.from, to: f.to, status: f.status,
        [k]: { id: x.id, name: x.name, description: x.description, isActive: x.is_active },
        total: r2(N(tot.s)), count: N(tot.n),
        linked: linked.map((o) => ({ id: o.id, name: o.name, isActive: o.is_active })),
        breakdown: split.map((s) => ({ id: s.id, name: s.name ?? (k === 'group' ? 'بدون تصنيف' : 'بدون مجموعة'), total: r2(N(s.s)), count: s.n })),
        expenses: rows.map((e) => ({ id: e.id, refNo: Number(e.ref_no), cashbox: e.cashbox, amount: N(e.amount_egp), category: e.category, reason: e.reason,
          beneficiary: e.beneficiary, status: e.status, at: e.at, groupId: e.expense_group_id, groupName: e.group_name,
          categoryId: e.expense_category_id, categoryName: e.category_name })),
        more: N(tot.n) > rows.length });
    });
  }

  /**
   * Spending report, aggregated on the server: by=group | category | group_category | unclassified,
   * every=day | month | year | none (none = one total per line for the whole range). Each expense counted once.
   */
  r.get('/cash/expense-classes/report', async (req) => {
    const a = await authenticate(db, req);
    if (!boxesOf(a).length) throw forbidden();
    await needInstalled(db);
    const by = req.query.get('by') ?? 'group';
    if (!['group', 'category', 'group_category', 'unclassified'].includes(by)) throw invalid('by is invalid', { field: 'by' });
    const every = req.query.get('every') ?? 'none';
    if (!['day', 'month', 'year', 'none'].includes(every)) throw invalid('every is invalid', { field: 'every' });
    const vals: unknown[] = [boxesOf(a)];
    const f = filters(req, vals);
    const cond = ['x.cashbox = ANY($1::text[])', OWN, ...f.where, ...(by === 'unclassified' ? ['x.expense_category_id IS NULL AND x.expense_group_id IS NULL'] : [])].join(' AND ');
    const bucket = every === 'none' ? `NULL::text` : `to_char(date_trunc('${every}', ${DATE} AT TIME ZONE 'Africa/Cairo'), 'YYYY-MM-DD')`;
    const keys = by === 'group' ? ['x.expense_group_id', 'g.name'] : by === 'category' ? ['x.expense_category_id', 'c.name']
      : by === 'group_category' ? ['x.expense_group_id', 'g.name', 'x.expense_category_id', 'c.name'] : ['x.category'];
    const rows = (await db.query(`
      SELECT ${bucket} AS period, ${keys.map((k, i) => `${k} AS k${i}`).join(', ')}, sum(x.amount_egp) AS s, count(*)::int AS n
        FROM cash_expenses x LEFT JOIN expense_groups g ON g.id = x.expense_group_id LEFT JOIN expense_categories c ON c.id = x.expense_category_id
       WHERE ${cond} GROUP BY ${['1', ...keys.map((_, i) => String(i + 2))].join(', ')} ORDER BY 1 NULLS FIRST, ${keys.length + 2} DESC`, vals)).rows;
    const tot = await one(db, `SELECT COALESCE(sum(x.amount_egp), 0) AS s, count(*)::int AS n,
        COALESCE(sum(x.amount_egp) FILTER (WHERE x.expense_category_id IS NULL AND x.expense_group_id IS NULL), 0) AS u,
        count(*) FILTER (WHERE x.expense_category_id IS NULL AND x.expense_group_id IS NULL)::int AS un
        FROM cash_expenses x WHERE ${cond}`, vals);
    return ok({ currency: 'EGP', by, every, from: f.from, to: f.to, status: f.status,
      total: r2(N(tot.s)), count: N(tot.n), unclassified: { total: r2(N(tot.u)), count: N(tot.un) },
      lines: rows.map((x) => by === 'group' ? { period: x.period, groupId: x.k0, groupName: x.k1 ?? 'بدون مجموعة', total: r2(N(x.s)), count: x.n }
        : by === 'category' ? { period: x.period, categoryId: x.k0, categoryName: x.k1 ?? 'بدون تصنيف', total: r2(N(x.s)), count: x.n }
          : by === 'group_category' ? { period: x.period, groupId: x.k0, groupName: x.k1 ?? 'بدون مجموعة', categoryId: x.k2, categoryName: x.k3 ?? 'بدون تصنيف', total: r2(N(x.s)), count: x.n }
            : { period: x.period, item: x.k0, total: r2(N(x.s)), count: x.n }) });
  });

  /** (re)classify one recorded expense — metadata only, audited; works in a closed year (it changes no figure) */
  r.patch('/cash/expenses/:id/classification', async (req) => {
    const a = await authenticate(db, req);
    await needInstalled(db);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const out = await db.tx(async (q) => {
      const x = await one(q, `SELECT id, cashbox, status, ex_kind, sale_id, owner_draw_id, expense_group_id, expense_category_id
                                FROM cash_expenses WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!x) throw notFound();
      if (!boxesOf(a).includes(x.cashbox)) throw notFound();
      if (!canReclassify(a, x.cashbox)) throw forbidden();
      if (x.ex_kind || x.sale_id || x.owner_draw_id) throw conflict('ده مش مصروف للمكتب (فلوس مالك / استرداد / سحب) — مالوش تصنيف');
      const keepG = b.groupId !== undefined && b.groupId === x.expense_group_id;
      const keepC = b.categoryId !== undefined && b.categoryId === x.expense_category_id;
      // unchanged references may stay even if archived since; any NEW one must be active and consistent
      const next = await checkClassification(q, keepG ? null : b.groupId, keepC ? null : b.categoryId);
      const g = keepG ? x.expense_group_id : next.groupId, c = keepC ? x.expense_category_id : next.categoryId;
      if (keepG !== keepC && g && c && !(await one(q, `SELECT 1 FROM expense_group_categories WHERE group_id = $1 AND category_id = $2`, [g, c]))) {
        throw invalid('التصنيف ده مش ضمن المجموعة دي', { field: 'categoryId', reason: 'category_not_in_group' });
      }
      if (g === x.expense_group_id && c === x.expense_category_id) return { changed: false, g, c };
      await q.query(`UPDATE cash_expenses SET expense_group_id = $2, expense_category_id = $3 WHERE id = $1`, [x.id, g, c]);
      await audit(q, a.id, 'cash.expense.reclassify', 'cash_expense', x.id,
        { groupId: x.expense_group_id, categoryId: x.expense_category_id }, { groupId: g, categoryId: c });
      return { changed: true, g, c };
    });
    return ok({ ok: true, changed: out.changed, groupId: out.g, categoryId: out.c });
  });
};
