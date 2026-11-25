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
