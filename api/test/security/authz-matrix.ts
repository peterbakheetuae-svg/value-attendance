// Security review tool (not part of npm test): calls EVERY registered route as each role and records the status.
// Run: TEST_PG_URL=... node --import tsx test/security/authz-matrix.ts > out.tsv
import { harness, cast } from '../helpers.ts';
import { buildRouter } from '../../src/app.ts';

const h = await harness('2026-03-10T08:00:00Z');
const c = await cast(h);
const routes = buildRouter({ db: h.db, clock: () => h.now.value }).list();
const OTHER = '00000000-0000-4000-8000-000000000001';
const fill = (p: string) => p.replace(/:(\w+)/g, (_, k) => /emp|employee|user|person|id$/i.test(k) && k !== 'id' ? c.ids.e3 : (k === 'id' ? c.ids.e3 : (k === 'kind' ? 'photo' : (k === 'month' ? '2026-03' : OTHER))));
const codes: Record<string, string> = { e1: 'E1', sm1: 'SM1', acc: 'ACC1', hr: 'HR1' };
const roles: [string, string | null][] = [['anon', null], ['e1', c.t.e1], ['sm1', c.t.sm1], ['acc', c.t.acc], ['hr', c.t.hr]];
const { PW } = await import('../helpers.ts');
const out: string[] = ['route\t' + roles.map((r) => r[0]).join('\t')];
for (const rt of routes) {
  const [method, path] = rt.split(' ');
  if (method === 'OPTIONS' || path === '/auth/logout') continue;
  const cells: string[] = [];
  for (const [name, tok] of roles.map((x) => [...x] as [string, string | null])) {
    // destructive routes are only checked for "is the caller blocked" — a non-owner reaching them is the finding
    const send = (t: string | null) => h.call(t, method, fill(path), method === 'GET' || method === 'DELETE' ? undefined : {}).catch((e) => ({ status: 0, body: String(e) } as any));
    let r = await send(tok);
    // a route that signed the caller out (sessions, password …): sign in again so the next routes are tested for real
    if (tok && r.status === 401) {
      const i = roles.findIndex((x) => x[0] === name);
      await h.db.query(`UPDATE employees SET failed_logins = 0, locked_until = NULL, status = 'active' WHERE code = $1`, [codes[name]]).catch(() => {});
      roles[i][1] = await h.login(codes[name], PW).catch(() => null);
      r = await send(roles[i][1]);
      if (r.status === 401) r.body = { error: { code: 'unauthenticated-after-relogin' } };
    }
    cells.push(String(r.status) + (r.status >= 400 && r.body?.error?.code ? ':' + r.body.error.code : ''));
  }
  out.push(`${rt}\t${cells.join('\t')}`);
}
console.log(out.join('\n'));
await h.close();
process.exit(0);
