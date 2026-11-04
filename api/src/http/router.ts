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

function parseBody(method: string, ct: string, buf: Buffer): any {
  if (method === 'GET' || method === 'HEAD') return undefined;
  if (buf.length > MAX_BODY) throw new AppError('payload_too_large', 'Request body too large');
  if (!buf.length) return {};
  if (!ct.includes('application/json')) throw new AppError('bad_request', 'Expected application/json');
  try { return JSON.parse(buf.toString('utf8')); }
  catch { throw new AppError('bad_request', 'Malformed JSON'); }
}

async function readNodeBody(req: IncomingMessage): Promise<Buffer> {
  if (req.method === 'GET' || req.method === 'HEAD') return Buffer.alloc(0);
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const c of req) {
    size += (c as Buffer).length;
    if (size > MAX_BODY) throw new AppError('payload_too_large', 'Request body too large');
    chunks.push(c as Buffer);
  }
  return Buffer.concat(chunks);
}

export interface Opts { corsOrigins: string[]; log?: (o: object) => void }
interface Out { status: number; headers: Record<string, string>; body: Buffer | string }

/** Transport-independent core shared by the Node server and the serverless (fetch) entry. */
async function handle(router: Router, opts: Opts, method: string, rawUrl: string,
  headers: IncomingMessage['headers'], getBody: () => Promise<Buffer>): Promise<Out> {
  const h: Record<string, string> = { 'X-Content-Type-Options': 'nosniff', 'Cache-Control': 'no-store' };
  const origin = headers.origin as string | undefined;
  if (origin && opts.corsOrigins.includes(origin)) {
    h['Access-Control-Allow-Origin'] = origin;
    h['Vary'] = 'Origin';
    h['Access-Control-Allow-Headers'] = 'Authorization, Content-Type';
    h['Access-Control-Allow-Methods'] = 'GET, POST, PUT, PATCH, DELETE, OPTIONS';
    h['Access-Control-Expose-Headers'] = 'Content-Disposition';
  }
  if (method === 'OPTIONS') return { status: 204, headers: h, body: '' };
  const url = new URL(rawUrl, 'http://local');
  const out = (r: Reply): Out => {
    if ('binary' in r) {
      h['Content-Type'] = r.contentType;
      if (r.fileName) h['Content-Disposition'] = `attachment; filename="${r.fileName.replace(/[^\w.\-]/g, '_')}"`;
      return { status: r.status ?? 200, headers: h, body: r.binary };
    }
    h['Content-Type'] = 'application/json; charset=utf-8';
    return { status: r.status ?? 200, headers: h, body: JSON.stringify(r.json) };
  };
  try {
    const m = router.match(method, url.pathname);
    if (!m) throw new AppError('not_found', 'Route not found');
    const body = parseBody(method, String(headers['content-type'] ?? ''), await getBody());
    return out(await m.handler({ method, path: url.pathname, params: m.params, query: url.searchParams, headers, body }));
  } catch (e: any) {
    const err = e instanceof AppError ? e : fromDbError(e);
    if (err) return out({ status: err.status, json: { error: { code: err.code, message: err.message, details: err.details } } });
    opts.log?.({ level: 'error', msg: 'unhandled', path: url.pathname, err: String(e?.stack ?? e) });
    return out({ status: 500, json: { error: { code: 'internal_error', message: 'Internal error' } } });
  }
}

export function createHandler(router: Router, opts: Opts) {
  return async (req: IncomingMessage, res: ServerResponse) => {
    const o = await handle(router, opts, req.method ?? 'GET', req.url ?? '/', req.headers, () => readNodeBody(req));
    for (const [k, v] of Object.entries(o.headers)) res.setHeader(k, v);
    res.writeHead(o.status).end(o.body);
  };
}

/** Web-standard (Request → Response) handler for serverless hosts (Netlify Functions). */
export function createFetchHandler(router: Router, opts: Opts) {
  return async (req: Request): Promise<Response> => {
    const headers: IncomingMessage['headers'] = {};
    req.headers.forEach((v, k) => { headers[k.toLowerCase()] = v; });
    const u = new URL(req.url);
    const o = await handle(router, opts, req.method, u.pathname + u.search, headers,
      async () => (req.method === 'GET' || req.method === 'HEAD' ? Buffer.alloc(0) : Buffer.from(await req.arrayBuffer())));
    return new Response(o.status === 204 ? null : (o.body as any), { status: o.status, headers: o.headers });
  };
}
