import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { forbidden, invalid, notFound } from '../http/errors.ts';
import { obj, str, isUuid } from '../http/validate.ts';
import { audit, authenticate, has, type Actor } from '../auth/context.ts';

/**
 * استمارات — pilot: استمارة استلام عهدة (mobile phone custody receipt).
 *
 * No new tables: every completed receipt is saved as its own record in the existing, immutable
 * `employee_documents` table (kind 'other', a JSON file). That table already refuses deletes and edits, so a
 * receipt can never be overwritten. Each record keeps the template id + version it was made with; the app keeps
 * every template version, so an old receipt always prints exactly as it was made.
 */

export const CUSTODY_TEMPLATE = 'custody_receipt';
export const CUSTODY_TEMPLATE_VERSION = 1;
const FILE_PREFIX = 'custody-receipt-';

const canManage = (a: Actor) => has(a, 'documents.manage') || has(a, 'employee.manage');
const canReadAll = (a: Actor) => canManage(a) || has(a, 'documents.read') || has(a, 'employee.read_all');

const CONDITIONS = ['new', 'used_good', 'other'] as const;
const ACCESSORIES = ['charger', 'cable', 'case', 'headset', 'other'] as const;

const isoDate = (b: Record<string, unknown>, k: string) => {
  const v = typeof b[k] === 'string' ? (b[k] as string).trim() : '';
  if (!/^\d{4}-\d{2}-\d{2}$/.test(v) || Number.isNaN(Date.parse(v))) throw invalid('Enter a valid date', { field: k });
  return v;
};
const text = (b: Record<string, unknown>, k: string, max: number, required = false) => {
  const v = (str(b, k, { optional: true, max }) ?? '').trim();
  if (required && v.length < 1) throw invalid('This field is required', { field: k });
  return v;
};

/** Exactly the fields of the original paper form — nothing invented. */
function parseData(b: Record<string, unknown>) {
  const condition = String(b.condition ?? '');
  if (!(CONDITIONS as readonly string[]).includes(condition)) throw invalid('Choose the device condition', { field: 'condition' });
  const acc = Array.isArray(b.accessories) ? b.accessories.map(String) : [];
  if (acc.some((x) => !(ACCESSORIES as readonly string[]).includes(x))) throw invalid('Unknown accessory', { field: 'accessories' });
  const data = {
    // أولًا: بيانات الموظف
    employeeName: text(b, 'employeeName', 80, true),
    employeeCode: text(b, 'employeeCode', 20),
    jobTitle: text(b, 'jobTitle', 60),
    department: text(b, 'department', 60),
    directManager: text(b, 'directManager', 60),
    receiptDate: isoDate(b, 'receiptDate'),
    // ثانيًا: بيانات الهاتف المحمول
    phoneBrand: text(b, 'phoneBrand', 60, true),
    imei: text(b, 'imei', 40, true),
    lineNumber: text(b, 'lineNumber', 20),
    condition,
    conditionOther: text(b, 'conditionOther', 40),
    accessories: [...new Set(acc)],
    accessoriesOther: text(b, 'accessoriesOther', 60),
    // سادسًا: الإقرار والتوقيعات (signatures themselves are signed by hand on the paper)
    signEmployeeName: text(b, 'signEmployeeName', 80),
    signDate: isoDate(b, 'signDate'),
    custodianName: text(b, 'custodianName', 60),
    hrName: text(b, 'hrName', 60),
  };
  if (condition === 'other' && !data.conditionOther) throw invalid('Describe the device condition', { field: 'conditionOther' });
  if (data.accessories.includes('other') && !data.accessoriesOther) throw invalid('Name the other accessory', { field: 'accessoriesOther' });
  if (!data.signEmployeeName) data.signEmployeeName = data.employeeName;
  return data;
}

async function prefill(q: Q, employeeId: string) {
  return one(q, `
    SELECT e.full_name AS "employeeName", e.code AS "employeeCode", e.job_title AS "jobTitle",
           COALESCE(d.name_ar, '') AS "department",
           COALESCE(
             (SELECT m.full_name FROM employees m WHERE m.id = e.sales_manager_id AND m.status = 'active' AND m.id <> e.id),
             (SELECT m.full_name FROM teams t JOIN employees m ON m.id = t.manager_id
               WHERE t.id = e.team_id AND t.active AND m.status = 'active' AND m.id <> e.id),
             (SELECT g.full_name FROM employees g WHERE g.id = e.general_manager_id AND g.status = 'active' AND g.id <> e.id),
             '') AS "directManager"
      FROM employees e LEFT JOIN departments d ON d.id = e.department_id
     WHERE e.id = $1`, [employeeId]);
}

function shapeRecord(row: any) {
  let body: any = {};
  try { body = JSON.parse(Buffer.from(row.content).toString('utf8')); } catch { /* keep empty */ }
  return {
    id: row.id, employeeId: row.employee_id, number: body.number ?? null, title: row.title,
    template: body.template, templateVersion: body.templateVersion, data: body.data ?? {},
    createdAt: row.created_at, createdByName: row.created_by_name ?? null,
  };
}

export const formsModule: Module = (r, { db }) => {
  /** Employee information already in the system, to fill the form (all of it stays editable). */
  r.get('/forms/custody-receipt/prefill/:employeeId', async (req) => {
    const a = await authenticate(db, req);
    if (!canManage(a)) throw forbidden();
    if (!isUuid(req.params.employeeId)) throw notFound();
    const p = await prefill(db, req.params.employeeId);
    if (!p) throw notFound();
    return ok({ prefill: p, template: CUSTODY_TEMPLATE, templateVersion: CUSTODY_TEMPLATE_VERSION });
  });

  /** Save a completed receipt as a new, permanent record (never overwrites an earlier one). */
  r.post('/forms/custody-receipts', async (req) => {
    const a = await authenticate(db, req);
    if (!canManage(a)) throw forbidden();
    const b = obj(req.body);
    const employeeId = typeof b.employeeId === 'string' ? b.employeeId : '';
    if (!isUuid(employeeId)) throw invalid('Choose the employee', { field: 'employeeId' });
    const data = parseData(obj(b.data));
    const row = await db.tx(async (q) => {
      const emp = await one(q, `SELECT id FROM employees WHERE id = $1`, [employeeId]);
      if (!emp) throw invalid('Choose the employee', { field: 'employeeId' });
      // one numbering for all custody receipts; the lock keeps two saves from taking the same number
      await q.query(`SELECT pg_advisory_xact_lock(hashtext('forms:custody_receipt'))`);
      const n = await one(q, `SELECT count(*)::int AS n FROM employee_documents WHERE kind = 'other' AND file_name LIKE $1`, [`${FILE_PREFIX}%`]);
      const number = Number(n.n) + 1;
      const body = { template: CUSTODY_TEMPLATE, templateVersion: CUSTODY_TEMPLATE_VERSION, number, data,
        createdBy: a.id, createdAt: new Date().toISOString() };
      const buf = Buffer.from(JSON.stringify(body), 'utf8');
      const d = await one(q, `
        INSERT INTO employee_documents (employee_id, kind, title, file_name, mime, size_bytes, content, uploaded_by)
        VALUES ($1, 'other', $2, $3, 'application/json', $4, $5, $6)
        RETURNING id, employee_id, title, content, created_at`,
        [employeeId, `استمارة استلام عهدة رقم ${number}`, `${FILE_PREFIX}${number}.json`, buf.length, buf, a.id]);
      await audit(q, a.id, 'forms.custody_receipt.create', 'employee_document', d.id, undefined,
        { employeeId, number, templateVersion: CUSTODY_TEMPLATE_VERSION });
      return { ...d, created_by_name: a.fullName };
    });
    return ok({ receipt: shapeRecord(row) }, 201);
  });

  /** Earlier receipts (newest first). HR / the management see all; an employee sees his own. */
  r.get('/forms/custody-receipts', async (req) => {
    const a = await authenticate(db, req);
    const vals: unknown[] = [`${FILE_PREFIX}%`];
    let where = `d.kind = 'other' AND d.file_name LIKE $1 AND d.employee_id IS NOT NULL`;
    const emp = req.query.get('employeeId');
    if (!canReadAll(a)) { vals.push(a.id); where += ` AND d.employee_id = $${vals.length}`; }
    else if (emp) { if (!isUuid(emp)) throw notFound(); vals.push(emp); where += ` AND d.employee_id = $${vals.length}`; }
    const rows = await db.query(`
      SELECT d.id, d.employee_id, d.title, d.content, d.created_at, u.full_name AS created_by_name, e.full_name AS employee_name
        FROM employee_documents d JOIN employees u ON u.id = d.uploaded_by JOIN employees e ON e.id = d.employee_id
       WHERE ${where} ORDER BY d.created_at DESC LIMIT 500`, vals);
    return ok({ receipts: rows.rows.map((x) => ({ ...shapeRecord(x), employeeName: x.employee_name })) });
  });

  r.get('/forms/custody-receipts/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const row = await one(db, `
      SELECT d.id, d.employee_id, d.title, d.content, d.created_at, d.file_name, u.full_name AS created_by_name
        FROM employee_documents d JOIN employees u ON u.id = d.uploaded_by WHERE d.id = $1`, [req.params.id]);
    if (!row || !String(row.file_name).startsWith(FILE_PREFIX)) throw notFound();
    if (!canReadAll(a) && row.employee_id !== a.id) throw notFound();
    return ok({ receipt: shapeRecord(row) });
  });
};
