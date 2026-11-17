// Opens a VALUNIVO backup file made while BACKUP_ENCRYPTION_KEY was set (a «rows» file holding "enc:v1:...").
// Usage (on the owner's computer, never on a shared machine):
//   set BACKUP_ENCRYPTION_KEY=<the same base64 key as on Vercel>
//   node tools/backup-decrypt.mjs employees.json > employees.plain.json
import { createDecipheriv } from 'node:crypto';
import { readFileSync } from 'node:fs';

const key = Buffer.from(process.env.BACKUP_ENCRYPTION_KEY ?? '', 'base64');
if (key.length !== 32) { console.error('BACKUP_ENCRYPTION_KEY (32 bytes, base64) is required'); process.exit(1); }
const v = JSON.parse(readFileSync(process.argv[2], 'utf8'));
if (typeof v !== 'string' || !v.startsWith('enc:v1:')) { console.log(JSON.stringify(v)); process.exit(0); } // not encrypted
const b = Buffer.from(v.slice(7), 'base64');
const d = createDecipheriv('aes-256-gcm', key, b.subarray(0, 12));
d.setAuthTag(b.subarray(12, 28));
process.stdout.write(Buffer.concat([d.update(b.subarray(28)), d.final()]).toString('utf8'));
