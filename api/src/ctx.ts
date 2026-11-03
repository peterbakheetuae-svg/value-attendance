import type { Db } from './db.ts';
import type { Clock } from './lib/time.ts';
import type { Router } from './http/router.ts';

export interface Ctx { db: Db; clock: Clock }
export type Module = (r: Router, ctx: Ctx) => void;

export const ok = (json: unknown, status = 200) => ({ status, json });
