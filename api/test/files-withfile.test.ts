import test from 'node:test';
import assert from 'node:assert/strict';
import { withFile } from '../src/lib/files-sql.ts';

test('withFile: unchanged without a file id; bytes → NULL + <col>_file_id with one; upsert keeps both in step', () => {
  const sql = 'INSERT INTO ex_unit_files (unit_id, kind, data, by_id) VALUES ($1,$2,$3,$4) RETURNING id';
  assert.deepEqual(withFile(sql, [1, 2, 3, 4], 'data', null), [sql, [1, 2, 3, 4]]);
  const [s, p] = withFile(sql, [1, 2, 3, 4], 'data', 'F');
  assert.equal(s, 'INSERT INTO ex_unit_files (unit_id, kind, data, by_id, data_file_id) VALUES ($1, $2, $3, $4, $5) RETURNING id');
  assert.deepEqual(p, [1, 2, null, 4, 'F'], 'the bytes parameter is NULL, never left unreferenced');
  const up = `INSERT INTO company_assets (key, mime, data, updated_at, updated_by) VALUES ('logo',$1,$2,now(),$3)
      ON CONFLICT (key) DO UPDATE SET mime = EXCLUDED.mime, data = EXCLUDED.data, updated_at = now()`;
  const [u] = withFile(up, ['m', 'b', 'e'], 'data', 'F');
  assert.match(u, /\(key, mime, data, updated_at, updated_by, data_file_id\) VALUES \('logo', \$1, \$2, now\(\), \$3, \$4\)/);
  assert.match(u, /data = EXCLUDED\.data, data_file_id = EXCLUDED\.data_file_id/);
  assert.throws(() => withFile('UPDATE x SET data = $1', ['b'], 'data', 'F'));
  assert.throws(() => withFile(sql, [1], 'content', 'F'));
});

// regression (2026-11-25): with 091 installed and R2 switched off, replacing a file through an upsert left the old
// <col>_file_id next to the new bytes — the CHECK (num_nonnulls ≤ 1) then failed every replacement (500)
test('withFile: R2 off with 091 installed — an upsert also clears the earlier R2 reference; a plain insert is unchanged', () => {
  const up = `INSERT INTO company_assets (key, mime, data, updated_at, updated_by) VALUES ('logo',$1,$2,now(),$3)
      ON CONFLICT (key) DO UPDATE SET mime = EXCLUDED.mime, data = EXCLUDED.data, updated_at = now()`;
  const [u, p] = withFile(up, ['m', 'b', 'e'], 'data', null, true);
  assert.match(u, /data = EXCLUDED\.data, data_file_id = NULL, updated_at/);
  assert.deepEqual(p, ['m', 'b', 'e']);
  assert.equal(withFile(up, ['m', 'b', 'e'], 'data', null, false)[0], up, 'without 091 the statement is untouched');
  const ins = 'INSERT INTO lead_attachments (lead_id, data) VALUES ($1,$2) RETURNING id';
  assert.equal(withFile(ins, [1, 2], 'data', null, true)[0], ins);
  const att = `INSERT INTO cash_attachments (entity, entity_id, attachment, updated_by, updated_at) VALUES ($1,$2,$3,$4,$5)
      ON CONFLICT (entity, entity_id) DO UPDATE SET attachment = EXCLUDED.attachment, updated_by = EXCLUDED.updated_by`;
  assert.match(withFile(att, [1, 2, 3, 4, 5], 'attachment', null, true)[0], /attachment = EXCLUDED\.attachment, attachment_file_id = NULL, updated_by/);
});
