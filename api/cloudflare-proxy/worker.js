// Cloudflare Worker (free plan, no card): a mirror address for the Value Attendance API.
// Some mobile networks block or throttle host domains; the app tries this address first and the
// API host (Vercel) second. It only forwards requests — no secrets, no data stored here.
const UPSTREAM = 'https://value-attendance.vercel.app';

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const target = UPSTREAM + url.pathname + url.search;
    const headers = new Headers(request.headers);
    headers.delete('host');
    const init = { method: request.method, headers, redirect: 'manual' };
    if (!['GET', 'HEAD'].includes(request.method)) init.body = await request.arrayBuffer();
    return fetch(target, init);
  },
};
