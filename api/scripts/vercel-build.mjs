// Builds the API for Vercel using the Build Output API (v3): one Node.js function that serves every path.
// Run by Vercel after `npm install` (see vercel.json). No secrets are read here.
import { build } from 'esbuild';
import { mkdirSync, rmSync, writeFileSync, cpSync } from 'node:fs';

const out = process.argv[2] ?? '.vercel/output';
const fn = `${out}/functions/index.func`;
rmSync(out, { recursive: true, force: true });
mkdirSync(fn, { recursive: true });

await build({
  entryPoints: ['vercel/entry.ts'],
  outfile: `${fn}/index.mjs`,
  bundle: true,
  platform: 'node',
  format: 'esm',
  target: 'node22',
  // pg's optional native and Cloudflare backends are never used on Node.
  external: ['pg-native', 'pg-cloudflare', 'cloudflare:sockets'],
  // CommonJS deps (pg) call require(); give the ESM bundle a real one.
  banner: { js: "import { createRequire as __cr } from 'node:module'; const require = __cr(import.meta.url);" },
  logLevel: 'info',
});

// Run the API next to the database: every screen makes several database round trips, so an API in another
// continent than the database makes everything slow. The region is read from the database host name only
// (e.g. ep-….eu-central-1.aws.neon.tech → fra1); nothing secret is printed. VA_REGION overrides it.
const NEON_TO_VERCEL = {
  'aws:us-east-1': 'iad1', 'aws:us-east-2': 'cle1', 'aws:us-west-2': 'pdx1', 'aws:eu-central-1': 'fra1',
  'aws:eu-west-2': 'lhr1', 'aws:ap-southeast-1': 'sin1', 'aws:ap-southeast-2': 'syd1', 'aws:sa-east-1': 'gru1',
  'aws:ap-northeast-1': 'hnd1', 'aws:ap-south-1': 'bom1', 'aws:eu-west-1': 'dub1', 'aws:eu-west-3': 'cdg1',
  'azure:eastus2': 'iad1', 'azure:westus3': 'sfo1', 'azure:gwc': 'fra1',
};
function regionFor(url) {
  try {
    const parts = new URL(url).hostname.split('.');
    const i = parts.indexOf('neon');
    if (i < 2) return null;
    return NEON_TO_VERCEL[`${parts[i - 1]}:${parts[i - 2]}`] ?? null;
  } catch { return null; }
}
const region = process.env.VA_REGION || regionFor(process.env.DATABASE_URL ?? '');
console.log(`API region: ${region ?? 'Vercel default'}`);

writeFileSync(`${fn}/.vc-config.json`, JSON.stringify({
  runtime: 'nodejs22.x', handler: 'index.mjs', launcherType: 'Nodejs', shouldAddHelpers: false, maxDuration: 30,
  ...(region ? { regions: [region] } : {}),
}, null, 2));
writeFileSync(`${fn}/package.json`, JSON.stringify({ type: 'module' }));

mkdirSync(`${out}/static`, { recursive: true });
cpSync('public', `${out}/static`, { recursive: true });
writeFileSync(`${out}/config.json`, JSON.stringify({
  version: 3,
  routes: [{ src: '/(.*)', dest: '/index' }],
}, null, 2));
console.log('vercel build output ready');
