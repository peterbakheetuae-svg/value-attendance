// C1 — which Vercel deployment may run the API (revised 2026-11-24, second review: fixed identities, fail closed).
//
// Background: the retired Vercel project «value-attendance-api» (production domain value-attendance-api-eight.vercel.app,
// verified live 2026-11-24) builds every push to main with the production database, push and e-mail credentials.
// Removing it is a dashboard action for the owner; until then, a deployment of it must never serve the API or migrate.
//
// Identity = the project's production domain, which Vercel itself writes into every deployment of a project
// (VERCEL_PROJECT_PRODUCTION_URL; also VERCEL_URL / VERCEL_BRANCH_URL = <project>-<hash>-<scope>.vercel.app).
// Both projects' domains were verified live on 2026-11-24:
//   real API      valunivo.vercel.app, value-attendance.vercel.app (and the workers.dev mirror's upstream)  /readyz backup=true
//   retired       value-attendance-api-eight.vercel.app                                                   /readyz backup=false
// (A Vercel project id would be stronger, but it is not readable from outside the dashboard — see the report.)
//
// Decision (secrets play no part — a token being present or absent never changes it):
//   retired   any Vercel domain of the deployment is the retired project's            → 410, no database, no migration
//   serve     a Vercel production deployment whose project domain is the real API's, or whose own deployment URL is
//             the real project's (value-attendance-<hash>-hi-8dea.vercel.app)              → normal API
//   unverified a Vercel production deployment proven to be neither                        → 503, no database, no migration
//   serve     not a Vercel production deployment (previews have no production secrets; Netlify / laptop / CI use
//             their own entry points and the migrate guard's own rules)
// Plain JavaScript: used by the build script (node, no TypeScript) and bundled into the Vercel function by esbuild.

export const REAL_API_DOMAINS = Object.freeze(['valunivo.vercel.app', 'value-attendance.vercel.app']);
export const RETIRED_DOMAIN = 'value-attendance-api-eight.vercel.app';
const RETIRED_PROJECT_PREFIX = 'value-attendance-api-'; // every deployment URL of that project starts with its name
// Vercel team «hi-8dea»: projects «value-attendance» (the real API) and «value-attendance-api» (retired) — both read from
// Vercel's own commit statuses on 0d23322 («Vercel – value-attendance», «Vercel – value-attendance-api»).
// Vercel names each deployment <project>-<hash>-<team>.vercel.app: a second, Vercel-written proof of the real project,
// so the real API stays up even if its production domain is one not listed above.
const REAL_PROJECT_DEPLOYMENT = /^value-attendance-[a-z0-9]+-hi-8dea\.vercel\.app$/;

const clean = (x) => String(x ?? '').trim().toLowerCase().replace(/^https?:\/\//, '').replace(/\/.*$/, '');

/** @param {Record<string, string | undefined>} env @returns {'retired' | 'serve' | 'unverified'} */
export function deploymentStatus(env) {
  const prod = clean(env.VERCEL_PROJECT_PRODUCTION_URL);
  const urls = [prod, clean(env.VERCEL_URL), clean(env.VERCEL_BRANCH_URL)].filter(Boolean);
  if (urls.some((h) => h === RETIRED_DOMAIN || h === 'value-attendance-api.vercel.app' || h.startsWith(RETIRED_PROJECT_PREFIX))) {
    return 'retired';
  }
  const onVercel = env.VERCEL === '1' || !!env.VERCEL_ENV;
  if (!onVercel) return 'serve';
  // on Vercel: anything not proven to be a preview / development deployment is treated as production
  const production = env.VERCEL_ENV !== 'preview' && env.VERCEL_ENV !== 'development';
  if (!production) return 'serve';
  return REAL_API_DOMAINS.includes(prod) || REAL_PROJECT_DEPLOYMENT.test(clean(env.VERCEL_URL)) ? 'serve' : 'unverified';
}

/**
 * The function's final word: what the BUILD decided (from the build's own Vercel variables, baked into the bundle by
 * scripts/vercel-build.mjs) AND what the running instance sees — anything but «serve» on either side refuses.
 * @param {string | undefined} built @param {Record<string, string | undefined>} env
 */
export function combinedStatus(built, env) {
  const now = deploymentStatus(env);
  if (built === 'retired' || now === 'retired') return 'retired';
  if ((built !== undefined && built !== 'serve') || now !== 'serve') return 'unverified';
  return 'serve';
}

