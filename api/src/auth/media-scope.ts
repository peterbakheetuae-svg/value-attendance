import type { Q } from '../db.ts';
import { has, readableIds, type Actor } from './context.ts';
import { activeSql, effectiveSql } from './permission-admin.ts';

/**
 * Whose photo an employee may see (null = everyone). The union of what his permissions already show him:
 *  - himself;
 *  - the employees he may read (employee.read_all / employee.read_team) and whose attendance he may read
 *    (attendance.read_all / attendance.read_team: the attendance board shows their photos);
 *  - for whoever distributes or follows every lead (leads.distribute / leads.read_all): the salesmen he assigns leads to.
 */
export async function photoScope(q: Q, a: Actor): Promise<Set<string> | null> {
  const emp = await readableIds(q, a, 'employee');
  const att = await readableIds(q, a, 'attendance');
  if (emp === null || att === null) return null;
  const out = new Set<string>([a.id, ...emp, ...att]);
  if (has(a, 'leads.distribute') || has(a, 'leads.read_all')) {
    const s = await q.query<{ id: string }>(`SELECT e.id FROM employees e WHERE ${activeSql('e')} AND ${effectiveSql('e', `'leads.own'`)}`);
    for (const x of s.rows) out.add(x.id);
  }
  return out;
}

/** whose attendance selfies (by employee) he may see: his own and his attendance reading scope */
export async function selfieScope(q: Q, a: Actor): Promise<Set<string> | null> {
  const ids = await readableIds(q, a, 'attendance');
  return ids === null ? null : new Set(ids);
}
