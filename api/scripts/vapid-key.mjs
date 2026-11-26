#!/usr/bin/env node
// Generates an independent Web Push (VAPID, P-256) key pair for VAPID_PRIVATE_KEY.
// Run it on YOUR machine (never in CI), paste the private value straight into Vercel → Settings → Environment
// Variables → VAPID_PRIVATE_KEY (Production, Sensitive), and do not keep it anywhere else. The public key is derived
// from it at runtime (GET /me/web-push) and is not a secret.
//   node api/scripts/vapid-key.mjs            → prints the public key only and writes the private key to ./vapid-private-key.txt (mode 600)
//   node api/scripts/vapid-key.mjs --stdout   → prints the private key to the terminal instead
import { createECDH } from 'node:crypto';
import { writeFileSync } from 'node:fs';

const ecdh = createECDH('prime256v1');
ecdh.generateKeys();
let d = ecdh.getPrivateKey();
if (d.length < 32) d = Buffer.concat([Buffer.alloc(32 - d.length), d]); // keep the fixed 32-byte form
const priv = d.toString('base64url');
const pub = ecdh.getPublicKey().toString('base64url');
if (process.argv.includes('--stdout')) {
  console.log(`VAPID_PRIVATE_KEY=${priv}`);
} else {
  writeFileSync('vapid-private-key.txt', priv + '\n', { mode: 0o600 });
  console.log('private key written to ./vapid-private-key.txt (mode 600) — paste it into Vercel, then delete the file');
}
console.log(`public key (not secret, for checking GET /me/web-push after the deploy): ${pub}`);
