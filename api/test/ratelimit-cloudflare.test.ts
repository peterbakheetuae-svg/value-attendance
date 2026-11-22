import { test, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { clientIp } from '../src/auth/ratelimit.ts';

/** On Cloudflare Workers only CF-Connecting-IP (set by the edge) is trusted; Vercel's headers are ignored there. */
const req = (headers: Record<string, string>) => ({ headers } as any);
afterEach(() => { delete process.env.VA_PLATFORM; delete process.env.VERCEL; delete process.env.TRUST_PLATFORM_IP; });

test('cloudflare: CF-Connecting-IP is the client IP', () => {
  process.env.VA_PLATFORM = 'cloudflare';
  assert.equal(clientIp(req({ 'cf-connecting-ip': '203.0.113.7' })), '203.0.113.7');
  assert.equal(clientIp(req({ 'cf-connecting-ip': '2001:db8::1' })), '2001:db8::1');
});

test('cloudflare: forgeable headers are not trusted, garbage is rejected', () => {
  process.env.VA_PLATFORM = 'cloudflare';
  assert.equal(clientIp(req({ 'x-real-ip': '6.6.6.6', 'x-vercel-forwarded-for': '6.6.6.6' })), null);
  assert.equal(clientIp(req({ 'cf-connecting-ip': '<script>' })), null);
});

test('vercel behaviour unchanged', () => {
  process.env.VERCEL = '1';
  assert.equal(clientIp(req({ 'x-vercel-forwarded-for': '198.51.100.2', 'cf-connecting-ip': '1.1.1.1' })), '198.51.100.2');
  delete process.env.VERCEL;
  assert.equal(clientIp(req({ 'cf-connecting-ip': '1.1.1.1' })), null, 'off-platform: nothing trusted');
});
