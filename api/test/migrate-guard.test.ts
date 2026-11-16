import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, chmodSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
// @ts-ignore — plain .mjs build script
import { decide } from '../scripts/migrate-if-production.mjs';

/** Branch previews / feature branches / non-production builds can never run migrations against the real database. */
const API = fileURLToPath(new URL('..', import.meta.url));
const ROOT = join(API, '..');

test('decision: only an explicit production build of main migrates', () => {
  const cases: [Record<string, string>, boolean][] = [
    [{ VERCEL: '1', VERCEL_ENV: 'production', VERCEL_GIT_COMMIT_REF: 'main' }, true],
    [{ VERCEL: '1', VERCEL_ENV: 'preview', VERCEL_GIT_COMMIT_REF: 'feature/permissions' }, false],
    [{ VERCEL: '1', VERCEL_ENV: 'preview', VERCEL_GIT_COMMIT_REF: 'main' }, false],
    [{ VERCEL: '1', VERCEL_ENV: 'production', VERCEL_GIT_COMMIT_REF: 'feature/x' }, false],
    [{ VERCEL: '1', VERCEL_ENV: 'production' }, false],                          // CLI deploy without a git ref
    [{ VERCEL: '1', VERCEL_ENV: 'development', VERCEL_GIT_COMMIT_REF: 'main' }, false],
    [{ VERCEL: '1', VERCEL_ENV: 'preview', VERCEL_GIT_COMMIT_REF: 'x', VA_ALLOW_MIGRATE: 'production' }, false], // no override on Vercel
    [{ NETLIFY: 'true', CONTEXT: 'production', BRANCH: 'main' }, true],
    [{ NETLIFY: 'true', CONTEXT: 'deploy-preview', BRANCH: 'feature/x' }, false],
    [{ NETLIFY: 'true', CONTEXT: 'branch-deploy', BRANCH: 'main' }, false],
    [{ NETLIFY: 'true', CONTEXT: 'production', BRANCH: 'feature/x' }, false],
    [{}, false],                                                                  // a laptop / CI
    [{ CI: 'true', GITHUB_REF: 'refs/heads/main' }, false],
    [{ VA_ALLOW_MIGRATE: 'yes' }, false],
    [{ VA_ALLOW_MIGRATE: 'production' }, true],                                   // deliberate, explicit
  ];
  for (const [env, want] of cases) assert.equal(decide(env).allow, want, JSON.stringify(env));
});

function runGuard(env: Record<string, string>) {
  // a fake `npm` first on PATH records every call instead of touching any database
  const dir = mkdtempSync(join(tmpdir(), 'mig-'));
  const log = join(dir, 'calls.log');
  writeFileSync(join(dir, 'npm'), `#!/bin/sh\necho "$@" >> "${log}"\n`); chmodSync(join(dir, 'npm'), 0o755);
  const clean: Record<string, string> = { PATH: `${dir}:${process.env.PATH}`, HOME: process.env.HOME ?? '' };
  const r = spawnSync(process.execPath, [join(API, 'scripts/migrate-if-production.mjs')], { env: { ...clean, ...env }, encoding: 'utf8' });
  return { status: r.status, out: r.stdout + r.stderr, calls: existsSync(log) ? readFileSync(log, 'utf8').trim().split('\n') : [] };
}

test('the real script: a preview build never calls migrate or seed; production of main does', () => {
  const previews: Record<string, string>[] = [{ VERCEL: '1', VERCEL_ENV: 'preview', VERCEL_GIT_COMMIT_REF: 'integration/final' },
                     { NETLIFY: 'true', CONTEXT: 'deploy-preview', BRANCH: 'feature/permissions' }, {}];
  for (const env of previews) {
    const r = runGuard(env);
    assert.equal(r.status, 0, r.out);
    assert.deepEqual(r.calls, [], `no npm call for ${JSON.stringify(env)}`);
    assert.match(r.out, /no migrate, no seed/);
  }
  const prod = runGuard({ VERCEL: '1', VERCEL_ENV: 'production', VERCEL_GIT_COMMIT_REF: 'main' });
  assert.equal(prod.status, 0, prod.out);
  assert.deepEqual(prod.calls, ['run migrate', 'run seed:dev -- --if-empty']);
});

test('every build / start command goes through the guard (no direct migrate or seed anywhere)', () => {
  const cmds: [string, string][] = [
    ['vercel.json', JSON.parse(readFileSync(join(ROOT, 'vercel.json'), 'utf8')).buildCommand],
    ['api/vercel.json', JSON.parse(readFileSync(join(API, 'vercel.json'), 'utf8')).buildCommand],
    ['api/netlify.toml', /^\s*command\s*=\s*"([^"]*)"/m.exec(readFileSync(join(API, 'netlify.toml'), 'utf8'))![1]],
  ];
  const scripts = JSON.parse(readFileSync(join(API, 'package.json'), 'utf8')).scripts as Record<string, string>;
  for (const [k, v] of Object.entries(scripts)) if (!['migrate', 'seed:dev'].includes(k)) cmds.push([`package.json ${k}`, v]);
  for (const [where, cmd] of cmds) {
    assert.ok(!/\bmigrate\b(?!-if-production)|src\/migrate\.ts|seed:dev|seed-dev/.test(cmd.replace(/migrate-if-production\.mjs/g, '')),
      `${where} must not run migrate / seed directly: ${cmd}`);
  }
  for (const [where, cmd] of cmds.slice(0, 3)) assert.match(cmd, /migrate-if-production\.mjs/, `${where} uses the guard`);
});
