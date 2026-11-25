-- Rollback of 092_marketing_intelligence.sql. Refuses (changes nothing) once any lead carries a quality decision or an
-- attribution, or any KPI result was calculated automatically: those are records of decisions and origins.
BEGIN;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM lead_quality_events) OR EXISTS (SELECT 1 FROM leads WHERE attribution_source IS NOT NULL)
     OR EXISTS (SELECT 1 FROM kpi_results WHERE source = 'auto') OR EXISTS (SELECT 1 FROM meta_data_deletion_requests) THEN
    RAISE EXCEPTION '092 rollback refused: quality decisions, attributions, automatic KPI results or Meta deletion requests exist';
  END IF;
END $$;
DROP TABLE IF EXISTS meta_data_deletion_requests;
DELETE FROM role_permissions WHERE perm_key IN ('leads.quality');
DELETE FROM permissions WHERE key IN ('leads.quality');
ALTER TABLE kpi_results DROP COLUMN IF EXISTS evidence;
ALTER TABLE kpi_results DROP COLUMN IF EXISTS calculated_at;
ALTER TABLE kpi_results DROP CONSTRAINT IF EXISTS kpi_results_source;
ALTER TABLE kpi_results DROP COLUMN IF EXISTS source;
ALTER TABLE kpi_definitions DROP CONSTRAINT IF EXISTS kpi_definitions_calc_approval;
ALTER TABLE kpi_definitions DROP COLUMN IF EXISTS calc_approved_at;
ALTER TABLE kpi_definitions DROP COLUMN IF EXISTS calc_approved_by;
ALTER TABLE kpi_definitions DROP COLUMN IF EXISTS calc_source;
DROP TRIGGER IF EXISTS lead_quality_events_immutable ON lead_quality_events;
DROP FUNCTION IF EXISTS lead_quality_events_immutable();
DROP TABLE IF EXISTS lead_quality_events;
DROP INDEX IF EXISTS leads_quality;
ALTER TABLE leads DROP CONSTRAINT IF EXISTS leads_quality;
ALTER TABLE leads DROP COLUMN IF EXISTS quality;
ALTER TABLE integrations DROP COLUMN IF EXISTS meta_user_hash;
ALTER TABLE integrations DROP COLUMN IF EXISTS insights_synced_through;
ALTER TABLE integrations DROP COLUMN IF EXISTS insights_sync_at;
DROP TABLE IF EXISTS meta_insights_daily;
DROP TRIGGER IF EXISTS lead_campaign_owner_track ON lead_campaigns;
DROP FUNCTION IF EXISTS lead_campaign_owner_track();
DROP TABLE IF EXISTS lead_campaign_owners;
DROP TRIGGER IF EXISTS leads_attribution_once ON leads;
DROP FUNCTION IF EXISTS leads_attribution_once();
DROP INDEX IF EXISTS leads_attributed_company;
DROP INDEX IF EXISTS leads_meta_campaign;
ALTER TABLE leads DROP CONSTRAINT IF EXISTS leads_attribution_source;
ALTER TABLE leads DROP COLUMN IF EXISTS attribution_source;
ALTER TABLE leads DROP COLUMN IF EXISTS attributed_at;
ALTER TABLE leads DROP COLUMN IF EXISTS attributed_company_id;
ALTER TABLE leads DROP COLUMN IF EXISTS meta_ad_id;
ALTER TABLE leads DROP COLUMN IF EXISTS meta_adset_id;
ALTER TABLE leads DROP COLUMN IF EXISTS meta_campaign_id;
ALTER TABLE leads DROP COLUMN IF EXISTS meta_form_id;
ALTER TABLE leads DROP COLUMN IF EXISTS meta_page_id;
COMMIT;
