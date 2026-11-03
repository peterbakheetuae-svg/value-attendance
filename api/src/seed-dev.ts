/**
 * First-run bootstrap for a NEW, EMPTY database.
 *   npm run seed:dev            → creates the owner account only
 *   npm run seed:dev -- --demo  → also a demo organisation for local testing (clearly named "تجريبي")
 * Refuses to run when any employee already exists. Passwords are random and printed once.
 */
import { createDb } from './db.ts';
import { hashPassword, tempPassword } from './auth/password.ts';
import { audit } from './auth/context.ts';

const url = process.env.DATABASE_URL;
if (!url) { console.error('DATABASE_URL is required'); process.exit(2); }
const demo = process.argv.includes('--demo');
const db = createDb(url);

try {
  const name = (await db.query(`SELECT current_database() AS d`)).rows[0].d;
  const expect = process.env.EXPECT_DATABASE;
  if (expect && expect !== name) { console.error(`Refusing: connected to "${name}", expected "${expect}"`); process.exit(3); }
  const n = (await db.query(`SELECT count(*)::int AS n FROM employees`)).rows[0].n;
  if (n > 0) { console.error(`Refusing: "${name}" already has ${n} employees. Seed only an empty database.`); process.exit(4); }

  const created: { code: string; role: string; password: string }[] = [];
  await db.tx(async (q) => {
    const add = async (code: string, fullName: string, role: string, extra: Record<string, unknown> = {}) => {
      const pw = tempPassword();
      const r = await q.query(`INSERT INTO employees (code, full_name, role_key, job_title, team_id, department_id, password_hash, must_change_password)
                               VALUES ($1,$2,$3,$4,$5,$6,$7,true) RETURNING id`,
        [code, fullName, role, extra.jobTitle ?? '', extra.teamId ?? null, extra.departmentId ?? null, await hashPassword(pw)]);
      await q.query(`INSERT INTO leave_balances (employee_id, year) VALUES ($1, extract(year FROM now())::int)`, [r.rows[0].id]);
      created.push({ code, role, password: pw });
      return r.rows[0].id as string;
    };
    const owner = await add('OWNER', 'مالك المكتب', 'owner', { jobTitle: 'المالك' });
    await audit(q, owner, 'system.bootstrap', 'employee', owner, undefined, { demo });

    if (demo) {
      const dep = (await q.query(`INSERT INTO departments (name_ar, name_en) VALUES ('المبيعات (تجريبي)', 'Sales (demo)') RETURNING id`)).rows[0].id;
      await add('HR1', 'مديرة الموارد البشرية (تجريبي)', 'hr_manager', { jobTitle: 'موارد بشرية' });
      await add('ACC1', 'المحاسب (تجريبي)', 'accountant', { jobTitle: 'محاسب' });
      const sm = await add('SM1', 'مدير المبيعات (تجريبي)', 'sales_manager', { jobTitle: 'مدير مبيعات', departmentId: dep });
      const team = (await q.query(`INSERT INTO teams (name, department_id, manager_id) VALUES ('فريق التجمع (تجريبي)', $1, $2) RETURNING id`, [dep, sm])).rows[0].id;
      for (let i = 1; i <= 3; i++) await add(`E${i}`, `مستشار عقاري ${i} (تجريبي)`, 'sales_employee', { jobTitle: 'مستشار عقاري', teamId: team, departmentId: dep });
    }
  });
  console.log(`database: ${name}`);
  console.log('Accounts created (temporary passwords — shown once; each user must change it at first sign-in):');
  for (const c of created) console.log(`  ${c.code.padEnd(6)} ${c.role.padEnd(15)} ${c.password}`);
} catch (e: any) {
  console.error(`Seed failed (${e?.code ?? 'error'}): ${e?.message ?? e}`);
  process.exitCode = 1;
} finally {
  await db.end();
}
