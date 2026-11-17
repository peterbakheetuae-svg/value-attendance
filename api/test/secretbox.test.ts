import { test } from 'node:test';
import assert from 'node:assert/strict';
import { seal, unseal } from '../src/lib/secretbox.ts';

test('VA-05: Meta tokens sealed with AES-256-GCM; legacy plain values still read; no key / wrong key never yields the ciphertext', () => {
  delete process.env.SECRETS_KEY;
  assert.equal(seal('EAAtok'), 'EAAtok', 'no key: stored as before');
  assert.equal(unseal('EAAtok'), 'EAAtok');
  process.env.SECRETS_KEY = Buffer.alloc(32, 7).toString('base64');
  const s = seal('EAAtok-123')!;
  assert.ok(s.startsWith('enc:v1:') && !s.includes('EAAtok'));
  assert.notEqual(seal('EAAtok-123'), s, 'random IV');
  assert.equal(unseal(s), 'EAAtok-123');
  assert.equal(unseal('EAAlegacy'), 'EAAlegacy', 'legacy plain value');
  const tampered = s.slice(0, -4) + (s.endsWith('AAAA') ? 'BBBB' : 'AAAA');
  assert.equal(unseal(tampered), null, 'tampered → null');
  process.env.SECRETS_KEY = Buffer.alloc(32, 8).toString('base64');
  assert.equal(unseal(s), null, 'wrong key → null');
  delete process.env.SECRETS_KEY;
  assert.equal(unseal(s), null, 'sealed but no key → null, never the ciphertext');
  assert.equal(unseal(null), null);
});
