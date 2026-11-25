import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { harness, cast, regrantAppRole, asLead, PW, type Harness } from './helpers.ts';
import { migrate } from '../src/migrate-core.ts';
import { R2Client, R2Error, r2ConfigFromEnv, signV4, uriEncode, type R2Config } from '../src/lib/r2.ts';
import { setFileStorageForTests } from '../src/lib/files.ts';

/**
 * Every file workflow of the API with R2 storage on (091 installed): upload through the real route, verified + linked
 * record, no bytes in Postgres, download through the route intact, the route's permission kept, nothing stored for a
 * refused upload, the object cannot be overwritten, a storage failure answers 503 and leaves an orphan record (never a
 * half-written business row), replacement keeps the old file record, and R2 switched off again keeps working.
 *
 * Storage: an in-memory stand-in behind the real signed client by default. With R2_TEST_REAL=1 and the R2_* variables of
 * the least-privilege SMOKE token, the same tests run against the real private bucket: every object key is moved under
 * staging/smoke/wf-<run>/ (never prod/, never a real business key), synthetic bytes only, and every object written is
 * deleted and checked gone at the end.
 */
const REAL = process.env.R2_TEST_REAL === '1';
const RUN = `wf-${(process.env.GITHUB_RUN_ID ?? randomUUID().slice(0, 8)).replace(/[^a-z0-9]/gi, '').toLowerCase()}`;
const PREFIX = `staging/smoke/${RUN}/`;

/** every request of the real-bucket run goes under staging/smoke/<run>/ — refuses anything else */
class SmokeR2 extends R2Client {
  readonly written = new Set<string>();
  private map(key: string) {
    if (!key.startsWith('staging/')) throw new Error('smoke run: only staging keys');
    const k = PREFIX + key.slice('staging/'.length);
    if (!k.startsWith('staging/smoke/')) throw new Error('smoke run: key outside staging/smoke/');
    return k;
  }
  override async put(key: string, data: Uint8Array, contentType: string, sha256: string) {
    const r = await super.put(this.map(key), data, contentType, sha256); this.written.add(this.map(key)); return r;
  }
  override head(key: string) { return super.head(this.map(key)); }
  override get(key: string, expect?: string) { return super.get(this.map(key), expect); }
  override delete(key: string) { return super.delete(this.map(key)); }
  rawDelete(mapped: string) { assert.ok(mapped.startsWith('staging/smoke/')); return super.delete(mapped); }
  rawHead(mapped: string) { assert.ok(mapped.startsWith('staging/smoke/')); return super.head(mapped); }
}

/**
 * Test-only listing of staging/smoke/wf-* (the API's client has no list on purpose): finds objects a cancelled earlier
 * run could not delete, so every run leaves the smoke prefix empty.
 */
async function listSmoke(cfg: R2Config): Promise<string[]> {
  const host = `${cfg.accountId}.${cfg.jurisdiction ? cfg.jurisdiction + '.' : ''}r2.cloudflarestorage.com`;
  const keys: string[] = []; let token = '';
  for (let page = 0; page < 50; page++) {
    const query: Record<string, string> = { 'list-type': '2', prefix: 'staging/smoke/wf-', ...(token ? { 'continuation-token': token } : {}) };
    const amzDate = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
    const payloadHash = createHash('sha256').update('').digest('hex');
    const headers = { 'x-amz-content-sha256': payloadHash, 'x-amz-date': amzDate };
    const path = `/${uriEncode(cfg.bucket)}`;
    const { signature, signedHeaders, scope } = signV4({ method: 'GET', host, path, query, headers, payloadHash, amzDate,
      region: 'auto', accessKeyId: cfg.accessKeyId, secretAccessKey: cfg.secretAccessKey });
    const qs = Object.keys(query).sort().map((k) => `${uriEncode(k)}=${uriEncode(query[k])}`).join('&');
    const res = await fetch(`https://${host}${path}?${qs}`, { headers: { ...headers,
      authorization: `AWS4-HMAC-SHA256 Credential=${cfg.accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}` } });
    assert.equal(res.status, 200, 'list of the smoke prefix');
    const xml = await res.text();
    for (const m of xml.matchAll(/<Key>([^<]+)<\/Key>/g)) keys.push(m[1].replace(/&amp;/g, '&'));
    const next = /<NextContinuationToken>([^<]+)<\/NextContinuationToken>/.exec(xml)?.[1];
    if (!/<IsTruncated>true<\/IsTruncated>/.test(xml) || !next) break;
    token = next;
  }
  return keys;
}
let realCfg: R2Config | null = null;

// ------------------------------------------------------------------ the in-memory stand-in (default)
const objects = new Map<string, { data: Uint8Array; type: string; sha: string }>();
let failAll = false;
const fakeFetch = (async (url: string, init: RequestInit) => {
  const key = new URL(url).pathname;
  const h = init.headers as Record<string, string>;
  assert.match(h.authorization, /^AWS4-HMAC-SHA256 /);
  if (failAll) return new Response('<Error><Code>AccessDenied</Code></Error>', { status: 403 });
  if (init.method === 'PUT') {
    if (h['if-none-match'] === '*' && objects.has(key)) return new Response('<Error><Code>PreconditionFailed</Code></Error>', { status: 412 });
    objects.set(key, { data: new Uint8Array(init.body as Uint8Array), type: h['content-type'], sha: h['x-amz-meta-sha256'] });
    return new Response(null, { status: 200, headers: { etag: '"e"' } });
  }
  const o = objects.get(key);
  if (init.method === 'DELETE') { objects.delete(key); return new Response(null, { status: 204 }); }
  if (!o) return new Response(null, { status: 404 });
  if (init.method === 'HEAD') return new Response(null, { status: 200, headers: { 'content-length': String(o.data.length), 'content-type': o.type, 'x-amz-meta-sha256': o.sha } });
  if (init.method === 'GET') return new Response(o.data as unknown as BodyInit, { status: 200, headers: { 'content-type': o.type } });
  return new Response(null, { status: 405 });
}) as unknown as typeof fetch;

let good: R2Client; let broken: R2Client;
function storages() {
  if (REAL) {
    const cfg = r2ConfigFromEnv();
    assert.ok(cfg, 'R2_TEST_REAL=1 needs the R2_* variables of the smoke token');
    assert.equal(cfg!.bucket, 'valunivo-files');
    realCfg = cfg;
    good = new SmokeR2(cfg!);
    // the same bucket with a wrong secret: every request is refused by R2 itself (a real storage failure)
    broken = new SmokeR2({ ...cfg!, secretAccessKey: 'x'.repeat(40) } as R2Config);
  } else {
    const cfg = { accountId: 'a'.repeat(32), accessKeyId: 'AKID', secretAccessKey: 'SECRET', bucket: 'valunivo-files', jurisdiction: 'eu' };
    good = new R2Client(cfg, fakeFetch);
    broken = new R2Client(cfg, (async (u: string, i: RequestInit) => { failAll = true; try { return await fakeFetch(u, i); } finally { failAll = false; } }) as unknown as typeof fetch);
  }
}

let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let tGm = ''; let pid = ''; let cpid = '';
before(async () => {
  storages();
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await migrate(h.db); await regrantAppRole(h);   // 066, 083-089 and 091 (the template leaves the releases out)
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [c.ids.acc]);
  const gm = await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  assert.equal(gm.status, 201, JSON.stringify(gm.body));
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE id = $1`, [gm.body.id]);
  tGm = await h.login('GM1', PW);
  pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'مشروع الملفات', ownerName: 'أ. سامي', ownerPhone: '0100' })).body.project.id;
  const pr = await h.call(c.t.owner, 'POST', '/commissions/projects', { name: 'مشروع الوحدات', totalPct: 2, salesPct: 0.3, managerPct: 0.2, companyPct: 1.5 });
  assert.equal(pr.status, 201, JSON.stringify(pr.body));
  cpid = pr.body.project.id;
  setFileStorageForTests(good);
});
after(async () => {
  try {
    // clean-up: every object this run wrote is deleted and checked gone (real bucket: under staging/smoke/<run>/ only)
    if (REAL) {
      const g = good as SmokeR2;
      // this run's objects, plus any a cancelled earlier run left under staging/smoke/wf-*
      const left = (await listSmoke(realCfg!)).filter((k) => k.startsWith('staging/smoke/wf-'));
      const all = new Set([...g.written, ...left]);
      for (const k of all) await g.rawDelete(k);
      for (const k of all) assert.equal(await g.rawHead(k), null, 'smoke object deleted');
      assert.deepEqual(await listSmoke(realCfg!), [], 'staging/smoke/wf-* is empty');
      console.log(`real bucket: ${g.written.size} synthetic objects written under ${PREFIX}; ${all.size - g.written.size} left by an earlier cancelled run; all deleted, prefix verified empty`);
    }
  } finally { setFileStorageForTests(undefined); await h.close(); }
});

// ------------------------------------------------------------------ synthetic content (never a real file)
let seq = 0;
const tail = () => Buffer.from(`synthetic-${RUN}-${++seq}-${randomUUID()}`);
const pdf = () => Buffer.concat([Buffer.from('%PDF-1.4\n'), tail(), Buffer.alloc(64, 7)]);
const png = () => Buffer.concat([Buffer.from('\x89PNG\r\n\x1a\n', 'latin1'), tail(), Buffer.alloc(64, 3)]);
const jpg = () => Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), tail(), Buffer.alloc(400, 5), Buffer.from([0xff, 0xd9])]);
const b64 = (b: Buffer) => b.toString('base64');
const sha = (b: Buffer | Uint8Array) => createHash('sha256').update(b).digest('hex');
const fromDataUrl = (s: string) => Buffer.from(String(s).replace(/^data:[^,]*,/, ''), 'base64');

const fileCount = async () => Number((await h.db.query(`SELECT count(*) FROM file_objects`)).rows[0].count);
const orphans = async (cat: string) => Number((await h.db.query(`SELECT count(*) FROM file_objects WHERE category = $1 AND status = 'orphan'`, [cat])).rows[0].count);
const fileRow = async (id: string) => (await h.db.query(`SELECT * FROM file_objects WHERE id = $1`, [id])).rows[0];

/** the record is verified and linked, the object is the bytes, and it cannot be overwritten */
async function stored(fileId: string | null | undefined, bytes: Buffer, category: string, cls?: string) {
  assert.ok(fileId, `${category}: the row points at a file record`);
  const f = await fileRow(fileId!);
  assert.equal(f.status, 'verified', category);
  assert.equal(f.ref_count, 1, `${category}: linked`);
  if (cls) assert.equal(f.retention_class, cls, `${category}: retention class`);
  assert.equal(f.sha256, sha(bytes));
  assert.equal(f.size_bytes, bytes.length);
  assert.match(f.object_key, new RegExp(`^staging/${category}/\\d{4}/\\d{2}/[0-9a-f-]{36}$`));
  const got = await good.get(f.object_key, f.sha256);
  assert.ok(got, `${category}: object present`);
  assert.deepEqual(Buffer.from(got!.data), bytes, `${category}: object intact`);
  await assert.rejects(good.put(f.object_key, Buffer.from('overwrite attempt'), f.mime, sha(Buffer.from('overwrite attempt'))),
    (e: unknown) => e instanceof R2Error && e.status === 412, `${category}: no overwrite`);
  assert.deepEqual(Buffer.from((await good.get(f.object_key, f.sha256))!.data), bytes, `${category}: unchanged after the refused overwrite`);
  return f;
}

/** a storage failure: 503, one more orphan record, and nothing linked */
async function failsCleanly(category: string, upload: () => Promise<{ status: number; body: any }>) {
  const o = await orphans(category);
  const linked = Number((await h.db.query(`SELECT count(*) FROM file_objects WHERE category = $1 AND ref_count = 1`, [category])).rows[0].count);
  setFileStorageForTests(broken);
  let r: { status: number; body: any };
  try { r = await upload(); } finally { setFileStorageForTests(good); }
  assert.equal(r.status, 503, `${category}: storage down → 503 (${JSON.stringify(r.body)})`);
  assert.equal(r.body?.error?.details?.reason, 'storage_unavailable');
  assert.equal(await orphans(category), o + 1, `${category}: the failed write is recorded as an orphan`);
  assert.equal(Number((await h.db.query(`SELECT count(*) FROM file_objects WHERE category = $1 AND ref_count = 1`, [category])).rows[0].count), linked);
}

/** a refused upload stores nothing */
async function refusedStoresNothing(expect: number[], upload: () => Promise<{ status: number }>) {
  const n = await fileCount();
  const r = await upload();
  assert.ok(expect.includes(r.status), `refused (${r.status})`);
  assert.equal(await fileCount(), n, 'nothing stored for a refused upload');
}

// ================================================================== the workflows
test('unit files (reservation form / contract): R2, client-details permission, no overwrite, failure, limit refused before storage', { timeout: 120_000 }, async () => {
  const a = await h.call(c.t.e1, 'POST', '/exclusive/units', await asLead(h, c.ids.e1, { projectId: cpid, unitNo: 'F-1', clientName: 'عميل ملفات', clientPhone: '01077700091',
    unitPrice: 2_000_000, expectedContractDate: '2026-12-20' }));
  assert.equal(a.status, 201, JSON.stringify(a.body));
  const u = a.body.unit.id;
  const doc = pdf();
  const up = await h.call(c.t.e1, 'POST', `/exclusive/units/${u}/files`, { kind: 'reservation_form', fileName: 'استمارة.pdf', data: b64(doc) });
  assert.equal(up.status, 201, JSON.stringify(up.body));
  const row = (await h.db.query(`SELECT data, data_file_id FROM ex_unit_files WHERE id = $1`, [up.body.file.id])).rows[0];
  assert.equal(row.data, null);
  await stored(row.data_file_id, doc, 'unit_file', 'protected');
  const dl = await h.call(c.t.e1, 'GET', `/exclusive/units/${u}/files/${up.body.file.id}`);
  assert.equal(dl.status, 200);
  assert.deepEqual(Buffer.from(dl.body.data, 'base64'), doc);
  assert.equal((await h.call(c.t.e3, 'GET', `/exclusive/units/${u}/files/${up.body.file.id}`)).status, 404, 'another salesman');
  await refusedStoresNothing([404], () => h.call(c.t.e3, 'POST', `/exclusive/units/${u}/files`, { kind: 'reservation_form', fileName: 'x.pdf', data: b64(pdf()) }));
  await failsCleanly('unit_file', () => h.call(c.t.e1, 'POST', `/exclusive/units/${u}/files`, { kind: 'contract', fileName: 'عقد.pdf', data: b64(pdf()) }));
  assert.equal(Number((await h.db.query(`SELECT count(*) FROM ex_unit_files WHERE unit_id = $1`, [u])).rows[0].count), 1, 'no row for the failed upload');
});

test('project image + developer images: R2, setup permission, replacement keeps the old record (released), failure', { timeout: 120_000 }, async () => {
  const p1 = png();
  assert.equal((await h.call(c.t.owner, 'PUT', `/exclusive/projects/${pid}/image`, { mime: 'image/png', image: b64(p1) })).status, 200);
  let x = (await h.db.query(`SELECT data, data_file_id FROM project_images WHERE project_id = $1`, [pid])).rows[0];
  assert.equal(x.data, null);
  const f1 = await stored(x.data_file_id, p1, 'project_image', 'image');
  assert.deepEqual(fromDataUrl((await h.call(c.t.e1, 'GET', `/exclusive/projects/${pid}/image`)).body.image), p1);
  await refusedStoresNothing([403], () => h.call(c.t.e1, 'PUT', `/exclusive/projects/${pid}/image`, { mime: 'image/png', image: b64(png()) }));
  const p2 = png();
  assert.equal((await h.call(c.t.owner, 'PUT', `/exclusive/projects/${pid}/image`, { mime: 'image/png', image: b64(p2) })).status, 200);
  x = (await h.db.query(`SELECT data_file_id FROM project_images WHERE project_id = $1`, [pid])).rows[0];
  await stored(x.data_file_id, p2, 'project_image');
  const old = await fileRow(f1.id);
  assert.deepEqual([old.status, old.ref_count, old.release_reason], ['verified', 0, 'unlinked'], 'the replaced image is kept');
  assert.deepEqual(fromDataUrl((await h.call(c.t.e1, 'GET', `/exclusive/projects/${pid}/image`)).body.image), p2);
  await failsCleanly('project_image', () => h.call(c.t.owner, 'PUT', `/exclusive/projects/${pid}/image`, { mime: 'image/png', image: b64(png()) }));
  assert.equal((await h.db.query(`SELECT data_file_id FROM project_images WHERE project_id = $1`, [pid])).rows[0].data_file_id, x.data_file_id, 'the failure left the image as it was');

  const d = await h.call(c.t.owner, 'POST', '/exclusive/developers', { name: 'مطور الملفات' });
  assert.equal(d.status, 201, JSON.stringify(d.body));
  const did = d.body.developer.id;
  const logo = png();
  assert.equal((await h.call(c.t.owner, 'PUT', `/exclusive/developers/${did}/image/logo`, { mime: 'image/png', image: b64(logo) })).status, 200);
  const dv = (await h.db.query(`SELECT data, data_file_id FROM developer_images WHERE developer_id = $1 AND kind = 'logo'`, [did])).rows[0];
  assert.equal(dv.data, null);
  await stored(dv.data_file_id, logo, 'developer_image', 'image');
  assert.deepEqual(fromDataUrl((await h.call(c.t.e1, 'GET', `/exclusive/developers/${did}/image/logo`)).body.image), logo);
  await refusedStoresNothing([403], () => h.call(c.t.e1, 'PUT', `/exclusive/developers/${did}/image/photo`, { mime: 'image/png', image: b64(png()) }));
  await failsCleanly('developer_image', () => h.call(c.t.owner, 'PUT', `/exclusive/developers/${did}/image/photo`, { mime: 'image/png', image: b64(png()) }));
});

test('marketing-company documents + the company\'s own logo: R2, office / partner permissions, delete releases the file, failure', { timeout: 120_000 }, async () => {
  const mk = await h.call(c.t.owner, 'POST', '/marketing-companies', { name: 'شركة ملفات R2', kind: 'fixed', monthlyFee: 5000 });
  assert.equal(mk.status, 201, JSON.stringify(mk.body));
  const id = mk.body.company.id;
  const doc = pdf();
  assert.equal((await h.call(c.t.owner, 'PUT', `/marketing-companies/${id}/files/contract`, { fileName: 'contract.pdf', mime: 'application/pdf', data: b64(doc) })).status, 200);
  const r = (await h.db.query(`SELECT data, data_file_id FROM marketing_company_files WHERE company_id = $1 AND kind = 'contract'`, [id])).rows[0];
  assert.equal(r.data, null);
  const f = await stored(r.data_file_id, doc, 'marketing_company_file', 'protected');
  assert.deepEqual(Buffer.from((await h.call(c.t.owner, 'GET', `/marketing-companies/${id}/files/contract`)).body.data, 'base64'), doc);
  assert.equal((await h.call(c.t.e1, 'GET', `/marketing-companies/${id}/files/contract`)).status, 403);
  await refusedStoresNothing([403], () => h.call(c.t.e1, 'PUT', `/marketing-companies/${id}/files/financial_plan`, { fileName: 'p.pdf', mime: 'application/pdf', data: b64(pdf()) }));
  await failsCleanly('marketing_company_file', () => h.call(c.t.owner, 'PUT', `/marketing-companies/${id}/files/financial_plan`, { fileName: 'p.pdf', mime: 'application/pdf', data: b64(pdf()) }));
  // the office removes the document: the row goes, the file record stays (protected — never purged)
  assert.equal((await h.call(c.t.owner, 'DELETE', `/marketing-companies/${id}/files/contract`)).status, 200);
  const gone = await fileRow(f.id);
  assert.equal(gone.ref_count, 0);
  assert.equal(gone.retention_class, 'protected');
  assert.ok(await good.get(gone.object_key, gone.sha256), 'the object itself is kept');

  // the company signs in and changes its own logo
  assert.equal((await h.call(c.t.acc, 'PATCH', `/leads/partners/${id}/login`, { email: 'files@r2.test', phone: '01234500091', password: 'Start#2026x' })).status, 200);
  let pt = (await h.call(null, 'POST', '/auth/login', { identifier: 'files@r2.test', password: 'Start#2026x', deviceId: 'device-main-0000000000000' })).body.token;
  assert.equal((await h.call(pt, 'POST', '/auth/change-password', { currentPassword: 'Start#2026x', newPassword: 'Mine#2026yy' })).status, 200);
  pt = (await h.call(null, 'POST', '/auth/login', { identifier: 'files@r2.test', password: 'Mine#2026yy', deviceId: 'device-main-0000000000000' })).body.token;
  const lg = png();
  const up = await h.call(pt, 'PUT', '/partner/files/logo', { fileName: 'logo.png', mime: 'image/png', data: b64(lg) });
  assert.equal(up.status, 200, JSON.stringify(up.body));
  const lr = (await h.db.query(`SELECT data, data_file_id FROM marketing_company_files WHERE company_id = $1 AND kind = 'logo'`, [id])).rows[0];
  assert.equal(lr.data, null);
  await stored(lr.data_file_id, lg, 'marketing_company_file');
  assert.deepEqual(Buffer.from((await h.call(pt, 'GET', '/partner/files/logo')).body.data, 'base64'), lg);
  await failsCleanly('marketing_company_file', () => h.call(pt, 'PUT', '/partner/files/logo', { fileName: 'logo.png', mime: 'image/png', data: b64(png()) }));
});

test('HR: a staged required document (before the employee exists) on R2, protected, HR-only download', { timeout: 120_000 }, async () => {
  const id = jpg();
  const st = await h.call(c.t.hr, 'POST', '/documents/staged', { kind: 'national_id', mime: 'image/jpeg', fileName: 'id.jpg', data: b64(id) });
  assert.equal(st.status, 201, JSON.stringify(st.body));
  const r = (await h.db.query(`SELECT content, content_file_id FROM employee_documents WHERE id = $1`, [st.body.id])).rows[0];
  assert.equal(r.content, null);
  await stored(r.content_file_id, id, 'employee_document', 'protected');
  const dl = await h.call(c.t.hr, 'GET', `/documents/${st.body.id}`);
  assert.equal(dl.status, 200);
  assert.deepEqual(dl.raw, id);
  await refusedStoresNothing([403], () => h.call(c.t.e1, 'POST', '/documents/staged', { kind: 'national_id', mime: 'image/jpeg', fileName: 'id.jpg', data: b64(jpg()) }));
  await failsCleanly('employee_document', () => h.call(c.t.hr, 'POST', '/documents/staged', { kind: 'national_id', mime: 'image/jpeg', fileName: 'id.jpg', data: b64(jpg()) }));
});

// regression (2026-11-25): the selfie used to be stored INSIDE the check-in transaction, which holds the employee row
// FOR UPDATE — the file record's foreign key to that employee waited for it forever (every R2 check-in hung)
test('attendance selfie: R2 at check-in, own / HR read, signed media link, retention removes the row and releases the file, failure', { timeout: 120_000 }, async () => {
  const s1 = jpg();
  const ok = await h.call(c.t.e1, 'POST', '/attendance/check-in', { selfie: b64(s1), selfieMime: 'image/jpeg' });
  assert.equal(ok.status, 201, JSON.stringify(ok.body));
  const att = ok.body.attendance.id;
  const r = (await h.db.query(`SELECT image, image_file_id FROM attendance_selfies WHERE attendance_id = $1`, [att])).rows[0];
  assert.equal(r.image, null);
  const f = await stored(r.image_file_id, s1, 'attendance_selfie', 'selfie');
  assert.deepEqual((await h.call(c.t.e1, 'GET', `/attendance/${att}/selfie`)).raw, s1);
  assert.equal((await h.call(c.t.hr, 'GET', `/attendance/${att}/selfie`)).status, 200);
  assert.equal((await h.call(c.t.e3, 'GET', `/attendance/${att}/selfie`)).status, 404, 'another team');
  const link = (await h.call(c.t.hr, 'POST', '/media/links', { selfies: [att] })).body.links[`selfie:${att}`];
  assert.ok(link, 'a signed link');
  assert.deepEqual((await h.call(null, 'GET', link)).raw, s1, 'the signed link serves the R2 selfie');
  // storage down at check-in: 503, no attendance recorded, an orphan record
  await failsCleanly('attendance_selfie', () => h.call(c.t.e2, 'POST', '/attendance/check-in', { selfie: b64(jpg()), selfieMime: 'image/jpeg' }));
  assert.equal(Number((await h.db.query(`SELECT count(*) FROM attendance WHERE employee_id = $1`, [c.ids.e2])).rows[0].count), 0, 'no half check-in');
  // retention (normal use, a later check-in): the old selfie row goes, its file record is released (selfie class)
  await h.call(c.t.owner, 'PATCH', '/settings', { selfieRetentionDays: 1 });
  h.now.value = new Date('2026-03-12T08:00:00Z');
  assert.equal((await h.call(c.t.e2, 'POST', '/attendance/check-in', { selfie: b64(jpg()), selfieMime: 'image/jpeg' })).status, 201);
  assert.equal(Number((await h.db.query(`SELECT count(*) FROM attendance_selfies WHERE attendance_id = $1`, [att])).rows[0].count), 0);
  const rel = await fileRow(f.id);
  assert.equal(rel.ref_count, 0);
  assert.equal(rel.retention_class, 'selfie');
  h.now.value = new Date('2026-03-10T08:00:00Z');
});

test('employee photo through the signed media link (R2)', { timeout: 120_000 }, async () => {
  const p = jpg();
  assert.equal((await h.call(c.t.e2, 'PUT', `/employees/${c.ids.e2}/photo`, { mime: 'image/jpeg', data: b64(p) })).status, 200);
  const e = (await h.db.query(`SELECT photo, photo_file_id FROM employees WHERE id = $1`, [c.ids.e2])).rows[0];
  assert.equal(e.photo, null);
  await stored(e.photo_file_id, p, 'employee_photo', 'protected');
  const link = (await h.call(c.t.sm1, 'POST', '/media/links', { photos: [c.ids.e2] })).body.links[`photo:${c.ids.e2}`];
  assert.ok(link);
  assert.deepEqual((await h.call(null, 'GET', link)).raw, p);
  await refusedStoresNothing([403], () => h.call(c.t.e1, 'PUT', `/employees/${c.ids.e2}/photo`, { mime: 'image/jpeg', data: b64(jpg()) }));
  await failsCleanly('employee_photo', () => h.call(c.t.e2, 'PUT', `/employees/${c.ids.e2}/photo`, { mime: 'image/jpeg', data: b64(jpg()) }));
  assert.equal((await h.db.query(`SELECT photo_file_id FROM employees WHERE id = $1`, [c.ids.e2])).rows[0].photo_file_id, e.photo_file_id, 'unchanged after the failure');
});

test('brokerage listing photos: R2, editor permission before storage, viewer download, limit / failure', { timeout: 120_000 }, async () => {
  const l = await h.call(c.t.e1, 'POST', '/brokerage/listings', { kind: 'resale', title: 'شقة R2', address: 'التجمع', area: 120, price: 1_500_000,
    finishing: 'super_lux', description: '', ownerName: 'المالك', ownerPhone: '01000000091' });
  assert.equal(l.status, 201, JSON.stringify(l.body));
  const lid = l.body.listing.id;
  const p = jpg();
  const up = await h.call(c.t.e1, 'POST', `/brokerage/listings/${lid}/photos`, { mime: 'image/jpeg', image: b64(p) });
  assert.equal(up.status, 201, JSON.stringify(up.body));
  const r = (await h.db.query(`SELECT data, data_file_id FROM brokerage_listing_photos WHERE id = $1`, [up.body.photoId])).rows[0];
  assert.equal(r.data, null);
  await stored(r.data_file_id, p, 'listing_photo', 'image');
  assert.deepEqual(fromDataUrl((await h.call(c.t.e2, 'GET', `/brokerage/listings/${lid}/photos/${up.body.photoId}`)).body.image), p);
  await refusedStoresNothing([403, 404], () => h.call(c.t.e3, 'POST', `/brokerage/listings/${lid}/photos`, { mime: 'image/jpeg', image: b64(jpg()) }));
  await failsCleanly('listing_photo', () => h.call(c.t.e1, 'POST', `/brokerage/listings/${lid}/photos`, { mime: 'image/jpeg', image: b64(jpg()) }));
  // removing a photo hides it; the row (and its file) stay
  assert.equal((await h.call(c.t.e1, 'POST', `/brokerage/listings/${lid}/photos/${up.body.photoId}/remove`, {})).status, 200);
  assert.equal((await fileRow(r.data_file_id)).ref_count, 1);
});

test('cash: expense photo (at creation and later), receipt photo, transfer photo (upsert) — R2, cashbox permissions, retry stores nothing, failure', { timeout: 120_000 }, async () => {
  assert.equal((await h.call(tGm, 'POST', '/cash/adjustments', { cashbox: 'hr', kind: 'opening', amount: 100_000, reason: 'رصيد افتتاحي' })).status, 201);
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/adjustments', { cashbox: 'office', kind: 'opening', amount: 100_000, reason: 'رصيد افتتاحي' })).status, 201);
  // expense with its photo
  const e1 = jpg();
  const ref = randomUUID();
  const ex = await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 300, category: 'ضيافة', reason: 'بوفيه', beneficiary: 'محل', clientRef: ref, attachment: b64(e1) });
  assert.equal(ex.status, 201, JSON.stringify(ex.body));
  const xid = ex.body.expense.id;
  let r = (await h.db.query(`SELECT attachment, attachment_file_id FROM cash_expenses WHERE id = $1`, [xid])).rows[0];
  assert.equal(r.attachment, null);
  const fe = await stored(r.attachment_file_id, e1, 'expense_attachment', 'protected');
  assert.deepEqual(Buffer.from((await h.call(c.t.hr, 'GET', `/cash/attachment/expense/${xid}`)).body.attachment, 'base64'), e1);
  assert.equal((await h.call(c.t.e1, 'GET', `/cash/attachment/expense/${xid}`)).status, 403);
  assert.equal((await h.call(c.t.hr, 'GET', '/cash/expenses?cashbox=hr')).body.expenses.find((x: any) => x.id === xid).hasAttachment, true);
  // the same form sent again (retry): the first row back, nothing new stored
  const n = await fileCount();
  const again = await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 300, category: 'ضيافة', reason: 'بوفيه', beneficiary: 'محل', clientRef: ref, attachment: b64(jpg()) });
  assert.ok([200, 201].includes(again.status), JSON.stringify(again.body));
  assert.equal(await fileCount(), n, 'a retry stores nothing');
  await refusedStoresNothing([403], () => h.call(c.t.e1, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 10, category: 'ضيافة', reason: 'xx', beneficiary: 'xx', attachment: b64(jpg()) }));
  await failsCleanly('expense_attachment', () => h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 20, category: 'ضيافة', reason: 'بوفيه', beneficiary: 'محل', attachment: b64(jpg()) }));
  // the photo added later replaces it: the old record is kept (protected)
  const e2 = jpg();
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/expenses/${xid}/attachment`, { attachment: b64(e2) })).status, 200);
  r = (await h.db.query(`SELECT attachment_file_id FROM cash_expenses WHERE id = $1`, [xid])).rows[0];
  await stored(r.attachment_file_id, e2, 'expense_attachment');
  assert.deepEqual([(await fileRow(fe.id)).ref_count, (await fileRow(fe.id)).retention_class], [0, 'protected']);
  await failsCleanly('expense_attachment', () => h.call(c.t.hr, 'POST', `/cash/expenses/${xid}/attachment`, { attachment: b64(jpg()) }));

  // receipt with its photo
  const rc = jpg();
  const rec = await h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'reservation', amount: 5000, payerName: 'عميل اختبار', purpose: 'حجز', clientRef: randomUUID(), attachment: b64(rc) });
  assert.equal(rec.status, 201, JSON.stringify(rec.body));
  const rid = rec.body.receipt.id;
  const rr = (await h.db.query(`SELECT attachment, attachment_file_id FROM cash_receipts WHERE id = $1`, [rid])).rows[0];
  assert.equal(rr.attachment, null);
  await stored(rr.attachment_file_id, rc, 'receipt_attachment', 'protected');
  assert.equal(rec.body.receipt.hasAttachment, true);
  assert.deepEqual(Buffer.from((await h.call(c.t.hr, 'GET', `/cash/attachment/receipt/${rid}`)).body.attachment, 'base64'), rc);
  assert.equal((await h.call(c.t.e1, 'GET', `/cash/attachment/receipt/${rid}`)).status, 403);
  await failsCleanly('receipt_attachment', () => h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'reservation', amount: 10, payerName: 'عميل', purpose: 'حجز', clientRef: randomUUID(), attachment: b64(jpg()) }));

  // transfer photo (upsert): replace, permission, failure
  const t = await h.call(c.t.hr, 'POST', '/cash/transfers', { direction: 'office_to_hr', amount: 1000, reason: 'تغطية' });
  assert.equal(t.status, 201, JSON.stringify(t.body));
  const tid = t.body.transfer.id;
  const a1 = jpg();
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/attachments/transfer/${tid}`, { attachment: b64(a1) })).status, 200);
  let ca = (await h.db.query(`SELECT attachment, attachment_file_id FROM cash_attachments WHERE entity = 'transfer' AND entity_id = $1`, [tid])).rows[0];
  assert.equal(ca.attachment, null);
  const fa = await stored(ca.attachment_file_id, a1, 'cash_attachment', 'protected');
  assert.deepEqual(Buffer.from((await h.call(tGm, 'GET', `/cash/attachments/transfer/${tid}`)).body.attachment, 'base64'), a1);
  await refusedStoresNothing([403], () => h.call(c.t.e1, 'POST', `/cash/attachments/transfer/${tid}`, { attachment: b64(jpg()) }));
  const a2 = jpg();
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/attachments/transfer/${tid}`, { attachment: b64(a2) })).status, 200);
  ca = (await h.db.query(`SELECT attachment_file_id FROM cash_attachments WHERE entity = 'transfer' AND entity_id = $1`, [tid])).rows[0];
  await stored(ca.attachment_file_id, a2, 'cash_attachment');
  assert.equal((await fileRow(fa.id)).ref_count, 0, 'replaced, kept');
  await failsCleanly('cash_attachment', () => h.call(c.t.hr, 'POST', `/cash/attachments/transfer/${tid}`, { attachment: b64(jpg()) }));
});

test('advance and salary-adjustment photos: R2, own / finance read, failure', { timeout: 120_000 }, async () => {
  const p = jpg();
  const ad = await h.call(c.t.e2, 'POST', '/advances', { kind: 'advance', amount: 1500, period: '2026-03-01', note: 'سلفة', attachment: b64(p) });
  assert.equal(ad.status, 201, JSON.stringify(ad.body));
  const aid = (ad.body.advance ?? ad.body).id;
  const r = (await h.db.query(`SELECT attachment, attachment_file_id FROM advance_requests WHERE id = $1`, [aid])).rows[0];
  assert.equal(r.attachment, null);
  await stored(r.attachment_file_id, p, 'advance_attachment', 'protected');
  assert.deepEqual((await h.call(c.t.e2, 'GET', `/advances/${aid}/attachment`)).raw, p);
  assert.equal((await h.call(c.t.e3, 'GET', `/advances/${aid}/attachment`)).status, 404);
  await failsCleanly('advance_attachment', () => h.call(c.t.e2, 'POST', '/advances', { kind: 'advance', amount: 100, period: '2026-03-01', note: 'سلفة', attachment: b64(jpg()) }));

  const q = jpg();
  const sa = await h.call(c.t.acc, 'POST', '/finance/adjustments', { employeeId: c.ids.e1, month: '2026-03', kind: 'deduction', amountEgp: 250, reason: 'غياب بدون إذن', attachment: b64(q) });
  assert.equal(sa.status, 201, JSON.stringify(sa.body));
  const sid = (sa.body.adjustment ?? sa.body).id;
  const s = (await h.db.query(`SELECT attachment, attachment_file_id FROM salary_adjustments WHERE id = $1`, [sid])).rows[0];
  assert.equal(s.attachment, null);
  await stored(s.attachment_file_id, q, 'adjustment_attachment', 'protected');
  assert.deepEqual((await h.call(c.t.acc, 'GET', `/finance/adjustments/${sid}/attachment`)).raw, q);
  assert.equal((await h.call(c.t.e3, 'GET', `/finance/adjustments/${sid}/attachment`)).status === 200, false);
  assert.equal((await h.call(c.t.acc, 'GET', '/finance/adjustments?month=2026-03')).body.adjustments.find((x: any) => x.id === sid).has_attachment, true);
  await refusedStoresNothing([403], () => h.call(c.t.e1, 'POST', '/finance/adjustments', { employeeId: c.ids.e2, month: '2026-03', kind: 'bonus', amountEgp: 1, reason: 'مكافأة', attachment: b64(jpg()) }));
  await failsCleanly('adjustment_attachment', () => h.call(c.t.acc, 'POST', '/finance/adjustments', { employeeId: c.ids.e1, month: '2026-03', kind: 'bonus', amountEgp: 50, reason: 'مكافأة', attachment: b64(jpg()) }));
});

test('company logo: R2, edit permission before storage, replacement, failure', { timeout: 120_000 }, async () => {
  const l1 = png();
  assert.equal((await h.call(c.t.owner, 'PUT', '/company/logo', { mime: 'image/png', image: b64(l1) })).status, 200);
  let x = (await h.db.query(`SELECT data, data_file_id FROM company_assets WHERE key = 'logo'`)).rows[0];
  assert.equal(x.data, null);
  const f1 = await stored(x.data_file_id, l1, 'company_logo');
  assert.deepEqual(fromDataUrl((await h.call(c.t.e1, 'GET', '/company/logo')).body.image), l1);
  await refusedStoresNothing([403], () => h.call(c.t.e1, 'PUT', '/company/logo', { mime: 'image/png', image: b64(png()) }));
  const l2 = png();
  assert.equal((await h.call(c.t.owner, 'PUT', '/company/logo', { mime: 'image/png', image: b64(l2) })).status, 200);
  x = (await h.db.query(`SELECT data_file_id FROM company_assets WHERE key = 'logo'`)).rows[0];
  await stored(x.data_file_id, l2, 'company_logo');
  assert.equal((await fileRow(f1.id)).ref_count, 0);
  await failsCleanly('company_logo', () => h.call(c.t.owner, 'PUT', '/company/logo', { mime: 'image/png', image: b64(png()) }));
});

// regression (2026-11-25): R2 switched off again (the documented rollback) while 091 stays installed — replacing a file
// that is in R2 left the old <col>_file_id next to the new bytes, and the CHECK refused every replacement (500)
test('R2 switched off with 091 installed: replacements go to Postgres and clear the R2 reference (no 500); R2 files answer 503, not lost', { timeout: 120_000 }, async () => {
  setFileStorageForTests(null);
  try {
    const l = png();
    const r1 = await h.call(c.t.owner, 'PUT', '/company/logo', { mime: 'image/png', image: b64(l) });
    assert.equal(r1.status, 200, JSON.stringify(r1.body));
    const x = (await h.db.query(`SELECT data, data_file_id FROM company_assets WHERE key = 'logo'`)).rows[0];
    assert.ok(x.data);
    assert.equal(x.data_file_id, null);
    assert.deepEqual(fromDataUrl((await h.call(c.t.e1, 'GET', '/company/logo')).body.image), l);
    assert.equal((await h.call(c.t.owner, 'PUT', `/exclusive/projects/${pid}/image`, { mime: 'image/png', image: b64(png()) })).status, 200);
    const tid = (await h.db.query(`SELECT entity_id FROM cash_attachments WHERE entity = 'transfer' LIMIT 1`)).rows[0].entity_id;
    assert.equal((await h.call(c.t.hr, 'POST', `/cash/attachments/transfer/${tid}`, { attachment: b64(jpg()) })).status, 200);
    assert.equal((await h.call(c.t.e2, 'PUT', `/employees/${c.ids.e2}/photo`, { mime: 'image/jpeg', data: b64(jpg()) })).status, 200);
    assert.equal((await h.db.query(`SELECT photo_file_id FROM employees WHERE id = $1`, [c.ids.e2])).rows[0].photo_file_id, null);
    const xid = (await h.db.query(`SELECT id FROM cash_expenses WHERE attachment_file_id IS NOT NULL LIMIT 1`)).rows[0].id;
    assert.equal((await h.call(c.t.hr, 'POST', `/cash/expenses/${xid}/attachment`, { attachment: b64(jpg()) })).status, 200);
    assert.equal((await h.db.query(`SELECT attachment_file_id FROM cash_expenses WHERE id = $1`, [xid])).rows[0].attachment_file_id, null);
    // a file that IS in R2 cannot be read without the storage: a clear 503, the record untouched
    const rid = (await h.db.query(`SELECT id FROM cash_receipts WHERE attachment_file_id IS NOT NULL LIMIT 1`)).rows[0].id;
    const r = await h.call(c.t.hr, 'GET', `/cash/attachment/receipt/${rid}`);
    assert.equal(r.status, 503);
    assert.equal(r.body.error.details.reason, 'storage_not_configured');
  } finally { setFileStorageForTests(good); }
});

test('storage health: read-only counts for the owner / the scheduler, alert on orphans, never a key or a name', { timeout: 120_000 }, async () => {
  const before = (await h.call(c.t.owner, 'GET', '/admin/files/health')).body;
  assert.equal(before.installed, true);
  assert.equal(before.alert, true, 'the failures above left orphan records');
  assert.ok(before.counts.orphan >= 10, JSON.stringify(before.counts));
  assert.ok(before.problemsByCategory.unit_file >= 1);
  assert.ok(before.counts.linked > 0 && before.counts.released > 0);
  const text = JSON.stringify(before);
  assert.ok(!text.includes('staging/') && !text.includes('smoke') && !text.includes('.pdf'), 'no key / name');
  assert.equal((await h.call(c.t.e1, 'GET', '/admin/files/health')).status, 403);
  assert.equal((await h.call(c.t.hr, 'GET', '/admin/files/health')).status, 403);
  assert.equal((await h.call(null, 'GET', '/admin/files/health')).status, 401);
  process.env.BACKUP_TOKEN = 'b'.repeat(32);
  try {
    const s = await h.call(null, 'GET', '/admin/files/health', undefined, { 'x-backup-token': 'b'.repeat(32) });
    assert.equal(s.status, 200, JSON.stringify(s.body));
    assert.equal(s.body.alert, true);
    assert.equal((await h.call(null, 'GET', '/admin/files/health', undefined, { 'x-backup-token': 'c'.repeat(32) })).status, 401);
  } finally { delete process.env.BACKUP_TOKEN; }
  assert.equal(typeof before.counts.neverLinked, 'number');
  assert.equal(typeof before.counts.stuckUpload, 'number');
});
