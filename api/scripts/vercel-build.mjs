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

writeFileSync(`${fn}/.vc-config.json`, JSON.stringify({
  runtime: 'nodejs22.x', handler: 'index.mjs', launcherType: 'Nodejs', shouldAddHelpers: false, maxDuration: 30,
}, null, 2));
writeFileSync(`${fn}/package.json`, JSON.stringify({ type: 'module' }));

mkdirSync(`${out}/static`, { recursive: true });
cpSync('public', `${out}/static`, { recursive: true });
writeFileSync(`${out}/config.json`, JSON.stringify({
  version: 3,
  routes: [{ src: '/(.*)', dest: '/index' }],
}, null, 2));
console.log('vercel build output ready');
