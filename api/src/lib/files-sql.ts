// Pure SQL helper of the file service (no database import: unit-testable on its own).

/** text inside the parenthesis that opens at s[open] (balanced), and the index just after its closing ')' */
function group(s: string, open: number): [string, number] {
  let depth = 0;
  for (let i = open; i < s.length; i++) {
    if (s[i] === '(') depth++;
    else if (s[i] === ')' && --depth === 0) return [s.slice(open + 1, i), i + 1];
  }
  throw new Error('withFile: unbalanced statement');
}
/** split on top-level commas */
function items(s: string): string[] {
  const out: string[] = []; let depth = 0; let cur = '';
  for (const ch of s) {
    if (ch === '(') depth++;
    if (ch === ')') depth--;
    if (ch === ',' && depth === 0) { out.push(cur.trim()); cur = ''; } else cur += ch;
  }
  out.push(cur.trim());
  return out;
}

/**
 * Rewrites a simple `INSERT INTO t (cols…) VALUES (…) [ON CONFLICT … EXCLUDED.<col> …]` for a row whose bytes went to
 * R2: <bytesCol> gets NULL and <bytesCol>_file_id gets the file id. With fileId null the statement is returned unchanged
 * (Postgres storage, and databases without 091). Used only on the API's own literal statements, never on user text.
 */
export function withFile(sql: string, params: unknown[], bytesCol: string, fileId: string | null): [string, unknown[]] {
  if (!fileId) return [sql, params];
  const head = /^\s*INSERT\s+INTO\s+\w+\s*/i.exec(sql);
  if (!head || sql[head[0].length] !== '(') throw new Error('withFile: unsupported statement');
  const [colText, afterCols] = group(sql, head[0].length);
  const v = /^\s*VALUES\s*/i.exec(sql.slice(afterCols));
  if (!v || sql[afterCols + v[0].length] !== '(') throw new Error('withFile: unsupported statement');
  const valOpen = afterCols + v[0].length;
  const [valText, afterVals] = group(sql, valOpen);
  const cols = items(colText), vals = items(valText);
  const i = cols.indexOf(bytesCol);
  if (i < 0 || cols.length !== vals.length) throw new Error(`withFile: column ${bytesCol} not in the statement`);
  vals[i] = 'NULL';
  cols.push(`${bytesCol}_file_id`);
  vals.push(`$${params.length + 1}`);
  let rest = sql.slice(afterVals);
  if (new RegExp(`EXCLUDED\\.${bytesCol}\\b`).test(rest)) {
    rest = rest.replace(new RegExp(`(${bytesCol}\\s*=\\s*EXCLUDED\\.${bytesCol})\\b`), `$1, ${bytesCol}_file_id = EXCLUDED.${bytesCol}_file_id`);
  }
  return [`${head[0]}(${cols.join(', ')})${sql.slice(afterCols, valOpen)}(${vals.join(', ')})${rest}`, [...params, fileId]];
}
