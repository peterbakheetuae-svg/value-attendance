import { invalid } from '../http/errors.ts';
export const TZ = 'Africa/Cairo';

const fmt = new Intl.DateTimeFormat('en-CA', {
  timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit',
  hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23',
});

export interface LocalParts { date: string; minutes: number; isoDow: number }

/** Local (Cairo) calendar date, minutes since local midnight and ISO weekday. */
export function local(d: Date): LocalParts {
  const p = Object.fromEntries(fmt.formatToParts(d).map((x) => [x.type, x.value]));
  const date = `${p.year}-${p.month}-${p.day}`;
  const dow = new Date(date + 'T00:00:00Z').getUTCDay(); // 0 = Sun
  return { date, minutes: Number(p.hour) * 60 + Number(p.minute), isoDow: dow === 0 ? 7 : dow };
}

export function isoDow(date: string): number {
  const d = new Date(date + 'T00:00:00Z').getUTCDay();
  return d === 0 ? 7 : d;
}

/** Convert a Cairo local date + 'HH:MM' into an absolute instant (handles DST). */
export function cairoInstant(date: string, hhmm: string): Date {
  const [h, m] = hhmm.split(':').map(Number);
  // start with UTC guess and correct by the observed offset (twice for DST edges)
  let guess = Date.UTC(+date.slice(0, 4), +date.slice(5, 7) - 1, +date.slice(8, 10), h, m);
  for (let i = 0; i < 2; i++) {
    const l = local(new Date(guess));
    const want = Date.UTC(+date.slice(0, 4), +date.slice(5, 7) - 1, +date.slice(8, 10), h, m);
    const got = Date.UTC(+l.date.slice(0, 4), +l.date.slice(5, 7) - 1, +l.date.slice(8, 10), Math.floor(l.minutes / 60), l.minutes % 60);
    guess += want - got;
  }
  return new Date(guess);
}

export const timeToMinutes = (t: string) => { const [h, m] = t.split(':').map(Number); return h * 60 + m; };

export function daysInMonth(period: string): string[] {
  const y = +period.slice(0, 4), m = +period.slice(5, 7);
  const n = new Date(Date.UTC(y, m, 0)).getUTCDate();
  return Array.from({ length: n }, (_, i) => `${period.slice(0, 7)}-${String(i + 1).padStart(2, '0')}`);
}

export function addMonths(period: string, delta: number): string {
  const y = +period.slice(0, 4), m = +period.slice(5, 7) - 1 + delta;
  const d = new Date(Date.UTC(y, m, 1));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-01`;
}

export function daysBetween(a: string, b: string): number {
  return Math.round((Date.parse(b + 'T00:00:00Z') - Date.parse(a + 'T00:00:00Z')) / 86400000);
}

/** Clock is injectable so tests can pin "now". */
export type Clock = () => Date;
export const systemClock: Clock = () => new Date();

/**
 * When an action was really done: the device time of a punch queued offline (`offlineAt`, ISO),
 * accepted only within the last 48 hours and not in the future; otherwise the server clock.
 */
export function actionTime(body: Record<string, unknown>, now: Date): { at: Date; offline: boolean } {
  const v = body.offlineAt;
  if (v === undefined || v === null || v === '') return { at: now, offline: false };
  const at = typeof v === 'string' ? new Date(v) : new Date(NaN);
  if (Number.isNaN(at.getTime())) throw invalid('offlineAt must be an ISO time', { field: 'offlineAt' });
  if (at.getTime() > now.getTime() + 2 * 60_000) throw invalid('offlineAt is in the future', { field: 'offlineAt' });
  if (at.getTime() < now.getTime() - 48 * 3600_000) throw invalid('Offline records older than 48 hours are not accepted', { field: 'offlineAt', reason: 'offline_too_old' });
  return { at, offline: true };
}
