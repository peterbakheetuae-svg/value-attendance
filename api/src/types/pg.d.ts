// Minimal typings for the subset of node-postgres this API uses.
declare module 'pg' {
  export interface QueryResult<R = any> { rows: R[]; rowCount: number | null }
  export interface PoolClient {
    query<R = any>(text: string, values?: unknown[]): Promise<QueryResult<R>>;
    release(err?: Error | boolean): void;
  }
  export interface PoolConfig {
    connectionString?: string; host?: string; port?: number; user?: string;
    password?: string; database?: string; max?: number; ssl?: unknown;
  }
  export class Pool {
    constructor(config?: PoolConfig);
    query<R = any>(text: string, values?: unknown[]): Promise<QueryResult<R>>;
    connect(): Promise<PoolClient>;
    end(): Promise<void>;
    on(event: 'error', cb: (err: Error) => void): this;
  }
  export const types: { setTypeParser(oid: number, fn: (v: string) => unknown): void };
  const pg: { Pool: typeof Pool; types: typeof types };
  export default pg;
}
