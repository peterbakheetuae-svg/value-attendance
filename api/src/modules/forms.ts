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
/** استمارة استلام عهدة: موبايل (the pilot) | كمبيوتر محمول — each its own template, title and numbering. */
const DEVICES = {
  mobile: { template: CUSTODY_TEMPLATE, version: CUSTODY_TEMPLATE_VERSION, prefix: FILE_PREFIX, title: 'استمارة استلام عهدة', assetType: 'mobile' },
  laptop: { template: 'laptop_receipt', version: 1, prefix: 'laptop-receipt-', title: 'استمارة استلام عهدة كمبيوتر محمول', assetType: 'laptop' },
} as const;
type Device = keyof typeof DEVICES;
const deviceOf = (v: unknown): Device => (v === 'laptop' ? 'laptop' : 'mobile');
const ANY_PREFIX = `(d.file_name LIKE '${FILE_PREFIX}%' OR d.file_name LIKE 'laptop-receipt-%')`;

const canManage = (a: Actor) => has(a, 'documents.manage') || has(a, 'employee.manage');
const canReadAll = (a: Actor) => canManage(a) || has(a, 'documents.read') || has(a, 'employee.read_all');

const CONDITIONS = ['new', 'used_good', 'other'] as const;
const ACCESSORIES = ['charger', 'cable', 'case', 'headset', 'other'] as const;
const LAPTOP_ACCESSORIES = ['charger', 'cable', 'other'] as const;

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
function parseLaptop(b: Record<string, unknown>) {
  const condition = String(b.condition ?? '');
  if (!(CONDITIONS as readonly string[]).includes(condition)) throw invalid('Choose the device condition', { field: 'condition' });
  const acc = Array.isArray(b.accessories) ? b.accessories.map(String) : [];
  if (acc.some((x) => !(LAPTOP_ACCESSORIES as readonly string[]).includes(x))) throw invalid('Unknown accessory', { field: 'accessories' });
  const data = {
    employeeName: text(b, 'employeeName', 80, true),
    employeeCode: text(b, 'employeeCode', 20),
    jobTitle: text(b, 'jobTitle', 60),
    department: text(b, 'department', 60),
    directManager: text(b, 'directManager', 60),
    receiptDate: isoDate(b, 'receiptDate'),
    // ثانيًا: بيانات كمبيوتر محمول
    brand: text(b, 'brand', 60, true),
    serialNo: text(b, 'serialNo', 60, true),
    condition,
    conditionOther: text(b, 'conditionOther', 40),
    accessories: [...new Set(acc)],
    accessoriesOther: text(b, 'accessoriesOther', 60),
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
    device: body.template === 'laptop_receipt' ? 'laptop' : 'mobile',
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
    const dev = DEVICES[deviceOf(req.query.get('device'))];
    // the employee's custody of this kind (handed from Settings → العهدة) — picked to fill the device part
    const items = await db.query(`
      SELECT c.id, c.asset_name AS name, c.serial_no, c.assigned_on, x.line_number, x.condition, x.accessories, x.specs
        FROM custody_items c LEFT JOIN custody_assets x ON x.id = c.asset_id
       WHERE c.employee_id = $1 AND c.status = 'assigned' AND c.asset_type = $2 ORDER BY c.assigned_on DESC`,
      [req.params.employeeId, dev.assetType]);
    return ok({ prefill: p, template: dev.template, templateVersion: dev.version,
      items: items.rows.map((x) => ({ id: x.id, name: x.name, serialNo: x.serial_no ?? '', lineNumber: x.line_number ?? '',
        condition: x.condition ?? null, accessories: x.accessories ?? [], specs: x.specs ?? '',
        assignedOn: x.assigned_on instanceof Date ? x.assigned_on.toISOString().slice(0, 10) : String(x.assigned_on ?? '').slice(0, 10) })) });
  });

  /** Save a completed receipt as a new, permanent record (never overwrites an earlier one). */
  r.post('/forms/custody-receipts', async (req) => {
    const a = await authenticate(db, req);
    if (!canManage(a)) throw forbidden();
    const b = obj(req.body);
    const employeeId = typeof b.employeeId === 'string' ? b.employeeId : '';
    if (!isUuid(employeeId)) throw invalid('Choose the employee', { field: 'employeeId' });
    const device = deviceOf(b.device);
    const dev = DEVICES[device];
    const data = device === 'laptop' ? parseLaptop(obj(b.data)) : parseData(obj(b.data));
    const row = await db.tx(async (q) => {
      const emp = await one(q, `SELECT id FROM employees WHERE id = $1`, [employeeId]);
      if (!emp) throw invalid('Choose the employee', { field: 'employeeId' });
      // one numbering for all custody receipts; the lock keeps two saves from taking the same number
      await q.query(`SELECT pg_advisory_xact_lock(hashtext($1))`, [`forms:${dev.template}`]);
      const n = await one(q, `SELECT count(*)::int AS n FROM employee_documents WHERE kind = 'other' AND file_name LIKE $1`, [`${dev.prefix}%`]);
      const number = Number(n.n) + 1;
      const body = { template: dev.template, templateVersion: dev.version, number, data,
        createdBy: a.id, createdAt: new Date().toISOString() };
      const buf = Buffer.from(JSON.stringify(body), 'utf8');
      const d = await one(q, `
        INSERT INTO employee_documents (employee_id, kind, title, file_name, mime, size_bytes, content, uploaded_by)
        VALUES ($1, 'other', $2, $3, 'application/json', $4, $5, $6)
        RETURNING id, employee_id, title, content, created_at`,
        [employeeId, `${dev.title} رقم ${number}`, `${dev.prefix}${number}.json`, buf.length, buf, a.id]);
      await audit(q, a.id, `forms.${dev.template}.create`, 'employee_document', d.id, undefined,
        { employeeId, number, templateVersion: dev.version });
      return { ...d, created_by_name: a.fullName };
    });
    return ok({ receipt: shapeRecord(row) }, 201);
  });

  /** Earlier receipts (newest first). HR / the management see all; an employee sees his own. */
  r.get('/forms/custody-receipts', async (req) => {
    const a = await authenticate(db, req);
    const dq = req.query.get('device');
    const vals: unknown[] = [dq === 'laptop' ? 'laptop-receipt-%' : `${FILE_PREFIX}%`];
    let where = `d.kind = 'other' AND ${dq ? 'd.file_name LIKE $1' : `(${ANY_PREFIX} OR $1 = '')`} AND d.employee_id IS NOT NULL`;
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
    if (!row || !(String(row.file_name).startsWith(FILE_PREFIX) || String(row.file_name).startsWith('laptop-receipt-'))) throw notFound();
    if (!canReadAll(a) && row.employee_id !== a.id) throw notFound();
    return ok({ receipt: shapeRecord(row) });
  });

  // ------------------------------------------------------------------ استمارات عملاء ← استمارة تعارف
  /**
   * Any employee fills it for a client he met. The sales person on it is the employee who filled it (his own name,
   * filled automatically); HR / the management may file it for a sales person they pick. Saved like the custody
   * receipts: one permanent JSON record (employee_documents, under the sales person), numbered, never overwritten.
   */
  const CLIENT_PREFIX = 'client-intro-';
  const CLIENT_TYPES = ['residential', 'commercial', 'residential_2', 'administrative', 'medical', 'operational', 'other'] as const;
  const phone = (b: Record<string, unknown>, k: string, required = false) => {
    const v = text(b, k, 20).replace(/\s+/g, '');
    if (required && !v) throw invalid('Enter the phone number', { field: k });
    if (v && !/^\+?\d{7,15}$/.test(v)) throw invalid('Enter a valid phone number', { field: k });
    return v;
  };

  r.post('/forms/client-intros', async (req) => {
    const a = await authenticate(db, req);
    const b = obj(req.body);
    const d = obj(b.data);
    let salesId = a.id;
    if (canManage(a) && typeof b.salesEmployeeId === 'string' && b.salesEmployeeId) {
      if (!isUuid(b.salesEmployeeId)) throw invalid('Choose the sales person', { field: 'salesEmployeeId' });
      salesId = b.salesEmployeeId;
    }
    const types = Array.isArray(d.propertyTypes) ? [...new Set(d.propertyTypes.map(String))] : [];
    if (types.some((x) => !(CLIENT_TYPES as readonly string[]).includes(x))) throw invalid('Unknown property type', { field: 'propertyTypes' });
    const data = {
      date: isoDate(d, 'date'),
      clientName: text(d, 'clientName', 80, true),
      phone: phone(d, 'phone', true),
      whatsapp: phone(d, 'whatsapp'),
      job: text(d, 'job', 80),
      residence: text(d, 'residence', 80),
      propertyTypes: types,
      propertyOther: text(d, 'propertyOther', 80),
      salesName: '',
    };
    if (types.includes('other') && !data.propertyOther) throw invalid('Write the other type', { field: 'propertyOther' });
    const row = await db.tx(async (q) => {
      const emp = await one(q, `SELECT id, full_name FROM employees WHERE id = $1 AND status = 'active'`, [salesId]);
      if (!emp) throw invalid('Choose the sales person', { field: 'salesEmployeeId' });
      data.salesName = emp.full_name; // always the sales person's name from the system
      await q.query(`SELECT pg_advisory_xact_lock(hashtext('forms:client_intro'))`);
      const n = await one(q, `SELECT count(*)::int AS n FROM employee_documents WHERE kind = 'other' AND file_name LIKE $1`, [`${CLIENT_PREFIX}%`]);
      const number = Number(n.n) + 1;
      const body = { template: 'client_intro', templateVersion: 1, number, data, createdBy: a.id, createdAt: new Date().toISOString() };
      const buf = Buffer.from(JSON.stringify(body), 'utf8');
      const x = await one(q, `
        INSERT INTO employee_documents (employee_id, kind, title, file_name, mime, size_bytes, content, uploaded_by)
        VALUES ($1, 'other', $2, $3, 'application/json', $4, $5, $6)
        RETURNING id, employee_id, title, content, created_at`,
        [salesId, `استمارة تعارف رقم ${number} — ${data.clientName}`, `${CLIENT_PREFIX}${number}.json`, buf.length, buf, a.id]);
      await audit(q, a.id, 'forms.client_intro.create', 'employee_document', x.id, undefined, { number, salesId });
      return { ...x, created_by_name: a.fullName };
    });
    return ok({ form: shapeRecord(row) }, 201);
  });

  /** Earlier forms, newest first: the employee sees the ones he is the sales person on; HR / the management all. */
  r.get('/forms/client-intros', async (req) => {
    const a = await authenticate(db, req);
    const vals: unknown[] = [`${CLIENT_PREFIX}%`];
    let where = `d.kind = 'other' AND d.file_name LIKE $1`;
    if (!canReadAll(a)) { vals.push(a.id); where += ` AND (d.employee_id = $2 OR d.uploaded_by = $2)`; }
    const rows = await db.query(`
      SELECT d.id, d.employee_id, d.title, d.content, d.created_at, u.full_name AS created_by_name
        FROM employee_documents d JOIN employees u ON u.id = d.uploaded_by
       WHERE ${where} ORDER BY d.created_at DESC LIMIT 500`, vals);
    return ok({ forms: rows.rows.map(shapeRecord), canPickSales: canManage(a) });
  });
};
