import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';

/**
 * Integration secrets at rest (Meta page / office tokens): AES-256-GCM with a dedicated key from the environment
 * (SECRETS_KEY: 32 bytes, base64). Stored as «enc:v1:<base64 iv|tag|ciphertext>».
 *  - no key configured → values are stored as before (plain) and read as they are, so nothing breaks before the key is set;
 *  - a legacy plain value is still read as it is (backward compatible) and re-sealed the next time it is written;
 *  - a sealed value without the key (or with a wrong key) reads as null: never a crash, never the ciphertext used as a token.
 */
const PREFIX = 'enc:v1:';

function key(env = 'SECRETS_KEY'): Buffer | null {
  const raw = process.env[env] ?? '';
  if (!raw) return null;
  const k = Buffer.from(raw, 'base64');
  return k.length === 32 ? k : null;
}

export const secretsKeyConfigured = () => key() !== null;

export function seal(plain: string | null | undefined, env = 'SECRETS_KEY'): string | null {
  if (plain == null || plain === '') return plain ?? null;
  const k = key(env);
  if (!k) return plain;
  const iv = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', k, iv);
  const ct = Buffer.concat([c.update(plain, 'utf8'), c.final()]);
  return PREFIX + Buffer.concat([iv, c.getAuthTag(), ct]).toString('base64');
}

export function unseal(stored: string | null | undefined, env = 'SECRETS_KEY'): string | null {
  if (stored == null || stored === '') return null;
  if (!stored.startsWith(PREFIX)) return stored; // legacy plain value
  const k = key(env);
  if (!k) return null;
  try {
    const b = Buffer.from(stored.slice(PREFIX.length), 'base64');
    const d = createDecipheriv('aes-256-gcm', k, b.subarray(0, 12));
    d.setAuthTag(b.subarray(12, 28));
    return Buffer.concat([d.update(b.subarray(28)), d.final()]).toString('utf8');
  } catch {
    return null;
  }
}

/** the backup export is sealed with its own key (BACKUP_ENCRYPTION_KEY) when that key is configured */
export const backupKeyConfigured = () => key('BACKUP_ENCRYPTION_KEY') !== null;
