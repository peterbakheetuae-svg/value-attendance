#!/usr/bin/env node
// The ONLY way a build / start runs database migrations (and the empty-database seed) on its own.
// Migrations write to the real database, so they run only on an explicit, verifiable production build:
//   - Vercel:  VERCEL_ENV=production AND VERCEL_GIT_COMMIT_REF=main      (previews / branches never)
//   - Netlify: CONTEXT=production AND the branch is main                  (deploy previews / branch deploys never)
//   - anything else (a server, a laptop, CI): only with VA_ALLOW_MIGRATE=production set on purpose
// Anything else skips migrate + seed (and says so). An error in this script fails the build — it never guesses.
// `npm run migrate` itself is unchanged for deliberate manual use.
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { deploymentStatus } from './deployment-guard.mjs';

/** @returns {{ allow: boolean, why: string }} */
export function decide(env) {
  // C1: only the real API's project ever migrates; the retired project, or a production build whose project cannot be
  // identified, never does (scripts/deployment-guard.mjs — fail closed)
  const who = deploymentStatus(env);
  if (who === 'retired') return { allow: false, why: 'retired Vercel project (value-attendance-api) — never migrates' };
  if (env.VERCEL === '1' || env.VERCEL_ENV) {
    if (who === 'unverified') {
      return { allow: false, why: `Vercel production build of an unidentified project (VERCEL_PROJECT_PRODUCTION_URL=${env.VERCEL_PROJECT_PRODUCTION_URL || 'missing'}) — never migrates` };
    }
    const ok = env.VERCEL_ENV === 'production' && env.VERCEL_GIT_COMMIT_REF === 'main';
    return { allow: ok, why: `Vercel ${env.VERCEL_ENV || '?'} build of ${env.VERCEL_GIT_COMMIT_REF || '?'}` };
  }
  if (env.NETLIFY === 'true') {
    const branch = env.BRANCH || env.HEAD || '';
    const ok = env.CONTEXT === 'production' && branch === 'main';
    return { allow: ok, why: `Netlify ${env.CONTEXT || '?'} build of ${branch || '?'}` };
  }
  return { allow: env.VA_ALLOW_MIGRATE === 'production', why: 'not a Vercel / Netlify build (needs VA_ALLOW_MIGRATE=production)' };
}

function run(cmd, args) {
  const r = spawnSync(cmd, args, { stdio: 'inherit', shell: process.platform === 'win32' });
  if (r.error) throw r.error;
  if (r.status !== 0) process.exit(r.status ?? 1);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  const d = decide(process.env);
  if (!d.allow) {
    console.log(`no migrate, no seed — ${d.why}`);
  } else {
    console.log(`migrate + seed — ${d.why}`);
    run('npm', ['run', 'migrate']);
    run('npm', ['run', 'seed:dev', '--', '--if-empty']);
  }
}
