import { test } from 'node:test';
import assert from 'node:assert/strict';
import { backupTokenSlot, hasBackupToken } from '../src/lib/backup-token.ts';

/** BACKUP_TOKEN rotation: BACKUP_TOKEN_NEXT is accepted only while set; short / empty / wrong tokens never pass. */
const A = 'a'.repeat(32), B = 'b'.repeat(32);
const h = (v?: string | string[]) => (v === undefined ? {} : { 'x-backup-token': v }) as any;

test('current token only (today): A passes, anything else fails', () => {
  const env = { BACKUP_TOKEN: A };
  assert.equal(backupTokenSlot(h(A), env), 'current');
  for (const v of [undefined, '', B, A.slice(1), A + 'x']) assert.equal(hasBackupToken(h(v), env), false, String(v));
});

test('during rotation both work; after it only the new one', () => {
  assert.equal(backupTokenSlot(h(A), { BACKUP_TOKEN: A, BACKUP_TOKEN_NEXT: B }), 'current');
  assert.equal(backupTokenSlot(h(B), { BACKUP_TOKEN: A, BACKUP_TOKEN_NEXT: B }), 'next');
  assert.equal(hasBackupToken(h(A), { BACKUP_TOKEN: B }), false, 'the old token stops when it is replaced');
  assert.equal(hasBackupToken(h(B), { BACKUP_TOKEN: B }), true);
});

test('a too-short token is never accepted (either slot), and no token configured = off', () => {
  assert.equal(hasBackupToken(h('short-token'), { BACKUP_TOKEN: 'short-token' }), false);
  assert.equal(hasBackupToken(h('short-next'), { BACKUP_TOKEN: A, BACKUP_TOKEN_NEXT: 'short-next' }), false);
  assert.equal(hasBackupToken(h(A), {}), false);
  assert.equal(hasBackupToken(h([A, B]), { BACKUP_TOKEN: A }), true, 'a repeated header: the first value only');
});
