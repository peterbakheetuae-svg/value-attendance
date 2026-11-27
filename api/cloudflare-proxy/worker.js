// Cloudflare Worker (free plan, no card): a mirror address for the Value Attendance API.
// Deployed as Worker `value-attendance-api` on the Cloudflare account valunivo@gmail.com → https://value-attendance-api.valunivo.workers.dev
// Some mobile networks block or throttle host domains; the app tries this address first and the
// API host (Vercel) second. It only forwards requests — nothing is stored here, and the API still does every
// authentication and authorization check itself.
//
// SEC-05 / mirror security:
//  - the caller's own address (CF-Connecting-IP, written by Cloudflare) is sent to the API with an HMAC signature
//    (secret MIRROR_SIGNING_KEY: the same value as on Vercel — `wrangler secret put MIRROR_SIGNING_KEY`), bound to
//    the request's method and path and to the minute it was sent, so the API's sign-in throttling sees the real caller
//    and not Cloudflare's shared address. Without the secret no signature is sent (the API then behaves as before).
//  - any x-va-* header a caller sends is removed first (a caller can never pose as the mirror), and so are the
//    forwarding headers a caller could set (x-forwarded-*, x-real-ip, forwarded, x-vercel-*).
//  - only the methods the API serves are forwarded; the response is never cached here (the API sends no-store).
const UPSTREAM = 'https://value-attendance.vercel.app';
const METHODS = new Set(['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS']);
const STRIP = /^(x-va-|x-forwarded-|x-vercel-|x-real-ip$|forwarded$|host$|cf-connecting-ip$)/i;

const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');

export async function mirrorSignature(key, ip, method, pathname, ts) {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(`v1|${ts}|${ip}|${method.toUpperCase()}|${pathname}`));
  return `v1.${ts}.${hex(mac)}`;
}

/** the request to send upstream (exported for the API's tests) */
export async function upstreamRequest(request, env = {}, nowMs = Date.now()) {
  if (!METHODS.has(request.method)) return null;
  const url = new URL(request.url);
  const headers = new Headers();
  for (const [k, v] of request.headers) if (!STRIP.test(k)) headers.set(k, v);
  const ip = request.headers.get('cf-connecting-ip');
  const key = env.MIRROR_SIGNING_KEY;
  if (ip && typeof key === 'string' && key.length >= 32) {
    headers.set('x-va-client-ip', ip);
    headers.set('x-va-mirror-sig', await mirrorSignature(key, ip, request.method, url.pathname, Math.floor(nowMs / 1000)));
  }
  const init = { method: request.method, headers, redirect: 'manual' };
  if (!['GET', 'HEAD'].includes(request.method)) init.body = await request.arrayBuffer();
  return { url: UPSTREAM + url.pathname + url.search, init };
}

export default {
  async fetch(request, env) {
    const up = await upstreamRequest(request, env);
    if (!up) return new Response('Method not allowed', { status: 405 });
    return fetch(up.url, up.init);
  },
};
