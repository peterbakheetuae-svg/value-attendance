import type { IncomingMessage, ServerResponse } from 'node:http';
import { AppError, fromDbError } from './errors.ts';

export interface Req {
  method: string;
  path: string;
  params: Record<string, string>;
  query: URLSearchParams;
  headers: IncomingMessage['headers'];
  body: any;
}

export type Reply =
  | { status?: number; json: unknown }
  | { status?: number; binary: Buffer; contentType: string; fileName?: string };

export type Handler = (req: Req) => Promise<Reply>;

interface Route { method: string; parts: string[]; handler: Handler }

export class Router {
  private routes: Route[] = [];

  add(method: string, pattern: string, handler: Handler) {
    this.routes.push({ method, parts: pattern.split('/').filter(Boolean), handler });
  }
  get(p: string, h: Handler) { this.add('GET', p, h); }
  post(p: string, h: Handler) { this.add('POST', p, h); }
  put(p: string, h: Handler) { this.add('PUT', p, h); }
  patch(p: string, h: Handler) { this.add('PATCH', p, h); }
  delete(p: string, h: Handler) { this.add('DELETE', p, h); }

  list() { return this.routes.map((r) => `${r.method} /${r.parts.join('/')}`); }

  match(method: string, path: string): { handler: Handler; params: Record<string, string> } | null {
    const segs = path.split('/').filter(Boolean);
    let methodMismatch = false;
    for (const r of this.routes) {
      if (r.parts.length !== segs.length) continue;
      const params: Record<string, string> = {};
      let ok = true;
      for (let i = 0; i < r.parts.length; i++) {
        const p = r.parts[i];
        if (p.startsWith(':')) params[p.slice(1)] = decodeURIComponent(segs[i]);
        else if (p !== segs[i]) { ok = false; break; }
      }
      if (!ok) continue;
      if (r.method !== method) { methodMismatch = true; continue; }
      return { handler: r.handler, params };
    }
    if (methodMismatch) throw new AppError('not_found', 'Method not allowed on this path');
    return null;
  }
}

const MAX_BODY = 8 * 1024 * 1024;

async function readBody(req: IncomingMessage): Promise<any> {
  if (req.method === 'GET' || req.method === 'HEAD') return undefined;
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const c of req) {
    size += (c as Buffer).length;
    if (size > MAX_BODY) throw new AppError('payload_too_large', 'Request body too large');
    chunks.push(c as Buffer);
  }
  if (!size) return {};
  const ct = req.headers['content-type'] ?? '';
  if (!ct.includes('application/json')) throw new AppError('bad_request', 'Expected application/json');
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw new AppError('bad_request', 'Malformed JSON'); }
}

export function createHandler(router: Router, opts: { corsOrigins: string[]; log?: (o: object) => void }) {
  return async (req: IncomingMessage, res: ServerResponse) => {
    const origin = req.headers.origin;
    if (origin && opts.corsOrigins.includes(origin)) {
      res.setHeader('Access-Control-Allow-Origin', origin);
      res.setHeader('Vary', 'Origin');
      res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type');
      res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS');
      res.setHeader('Access-Control-Expose-Headers', 'Content-Disposition');
    }
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Cache-Control', 'no-store');
    if (req.method === 'OPTIONS') { res.writeHead(204).end(); return; }

    const url = new URL(req.url ?? '/', 'http://local');
    try {
      const m = router.match(req.method ?? 'GET', url.pathname);
      if (!m) throw new AppError('not_found', 'Route not found');
      const body = await readBody(req);
      const reply = await m.handler({
        method: req.method ?? 'GET', path: url.pathname, params: m.params,
        query: url.searchParams, headers: req.headers, body,
      });
      send(res, reply);
    } catch (e: any) {
      const err = e instanceof AppError ? e : fromDbError(e);
      if (err) {
        send(res, { status: err.status, json: { error: { code: err.code, message: err.message, details: err.details } } });
      } else {
        opts.log?.({ level: 'error', msg: 'unhandled', path: url.pathname, err: String(e?.stack ?? e) });
        send(res, { status: 500, json: { error: { code: 'internal_error', message: 'Internal error' } } });
      }
    }
  };
}

function send(res: ServerResponse, r: Reply) {
  if ('binary' in r) {
    res.setHeader('Content-Type', r.contentType);
    if (r.fileName) res.setHeader('Content-Disposition', `attachment; filename="${r.fileName.replace(/[^\w.\-]/g, '_')}"`);
    res.writeHead(r.status ?? 200).end(r.binary);
    return;
  }
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.writeHead(r.status ?? 200).end(JSON.stringify(r.json));
}
