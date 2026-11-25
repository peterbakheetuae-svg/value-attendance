// R2 client: AWS Signature V4 against AWS's published S3 examples, key safety, config parsing, and the client's
// request shape (no real bucket: a recording fetch stands in for R2).
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { R2Client, R2Error, assertSafeKey, presignV4, r2ConfigFromEnv, signV4 } from '../src/lib/r2.ts';

const AK = 'AKIAIOSFODNN7EXAMPLE';
const SK = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY';
const EMPTY = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

test('SigV4 header auth = AWS S3 example (GET /test.txt with Range)', () => {
  const r = signV4({
    method: 'GET', host: 'examplebucket.s3.amazonaws.com', path: '/test.txt',
    headers: { range: 'bytes=0-9', 'x-amz-content-sha256': EMPTY, 'x-amz-date': '20130524T000000Z' },
    payloadHash: EMPTY, amzDate: '20130524T000000Z', region: 'us-east-1', accessKeyId: AK, secretAccessKey: SK,
  });
  assert.equal(r.signature, 'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41');
  assert.equal(r.signedHeaders, 'host;range;x-amz-content-sha256;x-amz-date');
});

test('SigV4 presigned GET = AWS S3 example (86400 s)', () => {
  const url = presignV4({
    method: 'GET', host: 'examplebucket.s3.amazonaws.com', path: '/test.txt', region: 'us-east-1',
    accessKeyId: AK, secretAccessKey: SK, amzDate: '20130524T000000Z', expiresSec: 86400,
  });
  assert.match(url, /X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404$/);
});

test('object keys: server-generated shape only', () => {
  assertSafeKey('docs/2026/11/0b6f3c1e-5a2b-4c1d-9e8f-123456789abc');
  for (const bad of ['../etc/passwd', 'a//b', 'docs/', 'Docs/x', 'x y', 'a/b?c', '/abs', 'ab', 'docs/../x']) {
    assert.throws(() => assertSafeKey(bad), /unsafe object key/, bad);
  }
});

test('config: absent → null (Postgres storage); EU default; bad values refused', () => {
  assert.equal(r2ConfigFromEnv({}), null);
  const c = r2ConfigFromEnv({ R2_ACCOUNT_ID: 'a'.repeat(32), R2_ACCESS_KEY_ID: 'k', R2_SECRET_ACCESS_KEY: 's', R2_BUCKET: 'valunivo-files' });
  assert.equal(c?.jurisdiction, 'eu');
  assert.throws(() => r2ConfigFromEnv({ R2_ACCOUNT_ID: 'nope', R2_ACCESS_KEY_ID: 'k', R2_SECRET_ACCESS_KEY: 's', R2_BUCKET: 'b-1' }));
  assert.throws(() => r2ConfigFromEnv({ R2_ACCOUNT_ID: 'a'.repeat(32), R2_ACCESS_KEY_ID: 'k', R2_SECRET_ACCESS_KEY: 's', R2_BUCKET: 'Bad_Bucket' }));
});

function recorder(status = 200, headers: Record<string, string> = {}, body = '') {
  const calls: { url: string; init: RequestInit }[] = [];
  const f = (async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    return new Response(status === 204 || init.method === 'HEAD' ? null : body, { status, headers });
  }) as unknown as typeof fetch;
  return { f, calls };
}

const cfg = { accountId: 'a'.repeat(32), accessKeyId: 'AKID', secretAccessKey: 'SECRET', bucket: 'valunivo-files', jurisdiction: 'eu' };

test('put: EU endpoint, path-style, no-overwrite, sha256 metadata, signed; secret never sent', async () => {
  const { f, calls } = recorder(200, { etag: '"x"' });
  const c = new R2Client(cfg, f);
  const data = new TextEncoder().encode('hello');
  const sha = createHash('sha256').update(data).digest('hex');
  await c.put('docs/2026/11/abc-def', data, 'application/pdf', sha);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, `https://${'a'.repeat(32)}.eu.r2.cloudflarestorage.com/valunivo-files/docs/2026/11/abc-def`);
  const h = calls[0].init.headers as Record<string, string>;
  assert.equal(h['if-none-match'], '*');
  assert.equal(h['x-amz-meta-sha256'], sha);
  assert.equal(h['x-amz-content-sha256'], sha);
  assert.match(h.authorization, /^AWS4-HMAC-SHA256 Credential=AKID\/\d{8}\/auto\/s3\/aws4_request, SignedHeaders=content-length;content-type;host;if-none-match;x-amz-content-sha256;x-amz-date;x-amz-meta-sha256, Signature=[0-9a-f]{64}$/);
  assert.ok(!JSON.stringify(calls[0]).includes('SECRET'));
});

test('put: wrong sha256 refused before any network call', async () => {
  const { f, calls } = recorder();
  await assert.rejects(new R2Client(cfg, f).put('docs/2026/11/abc', new Uint8Array([1]), 'image/png', 'f'.repeat(64)), R2Error);
  assert.equal(calls.length, 0);
});

test('put: existing key (412) surfaces as an error, never a silent overwrite', async () => {
  const { f } = recorder(412, {}, '<Error><Code>PreconditionFailed</Code></Error>');
  const data = new Uint8Array([1, 2]);
  const sha = createHash('sha256').update(data).digest('hex');
  await assert.rejects(new R2Client(cfg, f).put('docs/2026/11/abc', data, 'image/png', sha), (e: R2Error) => e.status === 412 && e.code === 'PreconditionFailed' && !e.message.includes('http'));
});

test('get: integrity mismatch is an error; 404 → null', async () => {
  const bad = recorder(200, { 'content-type': 'image/png' }, 'tampered');
  await assert.rejects(new R2Client(cfg, bad.f).get('docs/2026/11/abc', '0'.repeat(64)), (e: R2Error) => e.code === 'IntegrityMismatch');
  const miss = recorder(404);
  assert.equal(await new R2Client(cfg, miss.f).get('docs/2026/11/abc'), null);
});

test('network failure → 503 R2Error without the URL', async () => {
  const f = (async () => { throw new TypeError('fetch failed https://secret-url'); }) as unknown as typeof fetch;
  await assert.rejects(new R2Client(cfg, f).head('docs/2026/11/abc'), (e: R2Error) => e.status === 503 && !e.message.includes('http'));
});

test('presignGet: ≤ 300 s, attachment disposition, no unsafe filename chars', () => {
  const c = new R2Client(cfg);
  const u = new URL(c.presignGet('docs/2026/11/abc', 'عقد "حجز"\r\n.pdf', 60));
  assert.equal(u.searchParams.get('X-Amz-Expires'), '60');
  assert.match(u.searchParams.get('response-content-disposition')!, /^attachment; filename\*=UTF-8''/);
  assert.ok(!u.searchParams.get('response-content-disposition')!.includes('\r'));
  assert.throws(() => c.presignGet('docs/2026/11/abc', 'x', 3600));
});
