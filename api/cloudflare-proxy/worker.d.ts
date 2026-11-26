export function mirrorSignature(key: string, ip: string, method: string, pathname: string, ts: number): Promise<string>;
export function upstreamRequest(request: Request, env?: { MIRROR_SIGNING_KEY?: string }, nowMs?: number): Promise<{ url: string; init: RequestInit & { headers: Headers } } | null>;
declare const _default: { fetch(request: Request, env: { MIRROR_SIGNING_KEY?: string }): Promise<Response> };
export default _default;
