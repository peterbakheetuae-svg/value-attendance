import pg from 'pg';

// numeric -> JS number (all our numerics are small money/score values), date -> 'YYYY-MM-DD' string.
pg.types.setTypeParser(1700, (v) => Number(v));
pg.types.setTypeParser(20, (v) => Number(v));
pg.types.setTypeParser(1082, (v) => v);

export interface Q {
  query<R = any>(text: string, values?: unknown[]): Promise<{ rows: R[]; rowCount: number | null }>;
}

export interface Db extends Q {
  tx<T>(fn: (q: Q) => Promise<T>): Promise<T>;
  end(): Promise<void>;
}

export function createDb(connectionString: string): Db {
  const pool = new pg.Pool({ connectionString, max: 10 });
  pool.on('error', () => { /* idle client errors are surfaced on next query */ });
  return {
    query: (t, v) => pool.query(t, v),
    async tx(fn) {
      const c = await pool.connect();
      try {
        await c.query('BEGIN');
        const out = await fn(c);
        await c.query('COMMIT');
        return out;
      } catch (e) {
        await c.query('ROLLBACK').catch(() => {});
        throw e;
      } finally {
        c.release();
      }
    },
    end: () => pool.end(),
  };
}

export async function one<R = any>(q: Q, text: string, values?: unknown[]): Promise<R | undefined> {
  const r = await q.query<R>(text, values);
  return r.rows[0];
}
