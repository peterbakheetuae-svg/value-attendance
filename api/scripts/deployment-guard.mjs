// C1 (security re-verification 2026-11-24): the retired Vercel project «value-attendance-api»
// (value-attendance-api-eight.vercel.app) still builds every push to main with the PRODUCTION database, push and e-mail
// credentials, but without the production secrets (no BACKUP_TOKEN, no META_APP_SECRETS). Until the owner removes it in
// the Vercel dashboard, a deployment of that project neither serves the API nor migrates the database.
//
// A deployment is treated as retired only when ALL of these hold — so the real API can never be caught by it:
//  - a Vercel production deployment (VERCEL_ENV=production)
//  - its project is the retired one: the project's production domain or the deployment's own URL starts with
//    «value-attendance-api-» / is «value-attendance-api.vercel.app» (Vercel names deployments <project>-<hash>-<scope>)
//  - and it lacks the production scheduler secret (BACKUP_TOKEN, ≥ 24 characters) that the real API has
//    (live /readyz on 2026-11-24: real API backup=true, retired one backup=false)
// Plain JavaScript: used by the build script (node, no TypeScript) and bundled into the function by esbuild.

/** @param {Record<string, string | undefined>} env @returns {boolean} */
export function retiredDeployment(env) {
  if (env.VERCEL_ENV !== 'production') return false;
  const names = [env.VERCEL_PROJECT_PRODUCTION_URL, env.VERCEL_URL]
    .map((x) => String(x ?? '').trim().toLowerCase()).filter(Boolean);
  const retiredName = names.some((h) => h.startsWith('value-attendance-api-') || h.startsWith('value-attendance-api.'));
  const hasProductionSecret = String(env.BACKUP_TOKEN ?? '').length >= 24;
  return retiredName && !hasProductionSecret;
}
