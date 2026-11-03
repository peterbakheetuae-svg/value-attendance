import { createDb } from './db.ts';
import { migrate } from './migrate-core.ts';

const url = process.env.DATABASE_URL;
if (!url) { console.error('DATABASE_URL is required'); process.exit(2); }
const db = createDb(url);
try {
  const name = (await db.query(`SELECT current_database() AS d`)).rows[0].d;
  const expect = process.env.EXPECT_DATABASE;
  if (expect && expect !== name) { console.error(`Refusing: connected to "${name}", expected "${expect}"`); process.exit(3); }
  const applied = await migrate(db);
  console.log(`database: ${name}`);
  console.log(applied.length ? `applied: ${applied.join(', ')}` : 'already up to date');
} catch (e: any) {
  console.error(`Migration failed (${e?.code ?? 'error'}): ${e?.message ?? e}`);
  process.exitCode = 1;
} finally {
  await db.end();
}
