-- Release: Marketing Intelligence (branch feat/marketing-intelligence). Applied by the production deploy of main only after the
-- owner's review of that branch. Body = db/proposed/092_marketing_intelligence.sql, byte for byte.
-- 092 — Marketing Intelligence (feat/marketing-intelligence): lead attribution, campaign ownership history, Meta Ads
-- Insights daily snapshots, lead quality (structure + manual classification + history), KPI calculation sources.
-- Additive only: new nullable / defaulted columns, new tables, triggers, one permission key. Nothing existing is rewritten
-- or removed; every statement is safe to re-run (IF NOT EXISTS / CREATE OR REPLACE / ON CONFLICT / guarded DO blocks).
-- Independent of 091 (file storage) and 090 (brokerage handover). PostgreSQL 16 and 18.

-- ============================================================ C. attribution (set once when the lead comes in)
-- What Meta told us about a lead's origin, kept as Meta gave it (no invented values: a field Meta did not send stays NULL).
-- attribution_source NULL = unknown (leads from before 092, or sources that carry no attribution).
ALTER TABLE leads ADD COLUMN IF NOT EXISTS meta_page_id text;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS meta_form_id text;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS meta_campaign_id text;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS meta_adset_id text;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS meta_ad_id text;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS attributed_company_id uuid REFERENCES marketing_companies(id) ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS attributed_at timestamptz;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS attribution_source text;
DO $$ BEGIN
  ALTER TABLE leads ADD CONSTRAINT leads_attribution_source CHECK (attribution_source IS NULL OR attribution_source IN ('meta_webhook', 'meta_sync', 'manual'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS leads_meta_campaign ON leads (meta_campaign_id) WHERE meta_campaign_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS leads_attributed_company ON leads (attributed_company_id) WHERE attributed_company_id IS NOT NULL;

-- once set, the attribution never changes (a later ownership change or a re-sync cannot rewrite history)
CREATE OR REPLACE FUNCTION leads_attribution_once() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.attribution_source IS NOT NULL AND (
       NEW.attribution_source IS DISTINCT FROM OLD.attribution_source OR NEW.attributed_at IS DISTINCT FROM OLD.attributed_at
    OR NEW.attributed_company_id IS DISTINCT FROM OLD.attributed_company_id OR NEW.meta_page_id IS DISTINCT FROM OLD.meta_page_id
    OR NEW.meta_form_id IS DISTINCT FROM OLD.meta_form_id OR NEW.meta_campaign_id IS DISTINCT FROM OLD.meta_campaign_id
    OR NEW.meta_adset_id IS DISTINCT FROM OLD.meta_adset_id OR NEW.meta_ad_id IS DISTINCT FROM OLD.meta_ad_id) THEN
    -- the only change allowed: a company that was deleted (ON DELETE SET NULL)
    IF NOT (NEW.attributed_company_id IS NULL AND OLD.attributed_company_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM marketing_companies WHERE id = OLD.attributed_company_id)
        AND NEW.attribution_source IS NOT DISTINCT FROM OLD.attribution_source AND NEW.attributed_at IS NOT DISTINCT FROM OLD.attributed_at
        AND NEW.meta_page_id IS NOT DISTINCT FROM OLD.meta_page_id AND NEW.meta_form_id IS NOT DISTINCT FROM OLD.meta_form_id
        AND NEW.meta_campaign_id IS NOT DISTINCT FROM OLD.meta_campaign_id AND NEW.meta_adset_id IS NOT DISTINCT FROM OLD.meta_adset_id
        AND NEW.meta_ad_id IS NOT DISTINCT FROM OLD.meta_ad_id) THEN
      RAISE EXCEPTION 'a lead''s attribution is set once and never rewritten' USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS leads_attribution_once ON leads;
CREATE TRIGGER leads_attribution_once BEFORE UPDATE ON leads FOR EACH ROW EXECUTE FUNCTION leads_attribution_once();

-- ============================================================ C. campaign ownership history
-- Every change of a campaign's marketing company is kept (from / to), whichever code path makes it (a trigger records it).
-- marketing_company_id NULL = an office-direct campaign for that period.
CREATE TABLE IF NOT EXISTS lead_campaign_owners (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id          uuid NOT NULL REFERENCES lead_campaigns(id) ON DELETE CASCADE ON UPDATE CASCADE,
  marketing_company_id uuid REFERENCES marketing_companies(id) ON DELETE SET NULL ON UPDATE CASCADE,
  from_at              timestamptz NOT NULL,
  to_at                timestamptz,
  CONSTRAINT lead_campaign_owners_period CHECK (to_at IS NULL OR to_at >= from_at)
);
CREATE UNIQUE INDEX IF NOT EXISTS lead_campaign_owners_open ON lead_campaign_owners (campaign_id) WHERE to_at IS NULL;
CREATE INDEX IF NOT EXISTS lead_campaign_owners_campaign ON lead_campaign_owners (campaign_id, from_at DESC);
CREATE INDEX IF NOT EXISTS lead_campaign_owners_company ON lead_campaign_owners (marketing_company_id) WHERE marketing_company_id IS NOT NULL;

CREATE OR REPLACE FUNCTION lead_campaign_owner_track() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.marketing_company_id IS DISTINCT FROM OLD.marketing_company_id THEN
    UPDATE lead_campaign_owners SET to_at = now() WHERE campaign_id = NEW.id AND to_at IS NULL;
    INSERT INTO lead_campaign_owners (campaign_id, marketing_company_id, from_at) VALUES (NEW.id, NEW.marketing_company_id, now());
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS lead_campaign_owner_track ON lead_campaigns;
CREATE TRIGGER lead_campaign_owner_track AFTER INSERT OR UPDATE OF marketing_company_id ON lead_campaigns
  FOR EACH ROW EXECUTE FUNCTION lead_campaign_owner_track();
-- the campaigns that exist today: one open period from their creation (only those without one, so a re-run adds nothing)
INSERT INTO lead_campaign_owners (campaign_id, marketing_company_id, from_at)
  SELECT c.id, c.marketing_company_id, c.created_at FROM lead_campaigns c
   WHERE NOT EXISTS (SELECT 1 FROM lead_campaign_owners o WHERE o.campaign_id = c.id);

-- ============================================================ D. Meta Ads Insights, one row per Meta campaign per day
-- Values as Meta reported them, in the ad account's currency and day (its time zone). A metric Meta did not return is NULL
-- (unavailable), never 0. A row is replaced only by a later COMPLETE answer for the same day (see modules/meta_insights.ts).
CREATE TABLE IF NOT EXISTS meta_insights_daily (
  meta_campaign_id  text NOT NULL CHECK (meta_campaign_id ~ '^[0-9]{3,30}$'),
  day               date NOT NULL,
  account_id        text,
  account_currency  text CHECK (account_currency IS NULL OR account_currency ~ '^[A-Z]{3}$'),
  campaign_name     text,
  objective         text,
  impressions       bigint CHECK (impressions IS NULL OR impressions >= 0),
  reach             bigint CHECK (reach IS NULL OR reach >= 0),
  clicks            bigint CHECK (clicks IS NULL OR clicks >= 0),
  spend             numeric(16, 2) CHECK (spend IS NULL OR spend >= 0),
  cpm               numeric(16, 4),
  cpc               numeric(16, 4),
  ctr               numeric(12, 6),
  leads             bigint CHECK (leads IS NULL OR leads >= 0),
  cost_per_lead     numeric(16, 4),
  fetched_at        timestamptz NOT NULL,
  PRIMARY KEY (meta_campaign_id, day)
);
CREATE INDEX IF NOT EXISTS meta_insights_daily_day ON meta_insights_daily (day);
-- the insights pass's own checkpoint and outcome (one row: the office's connection)
ALTER TABLE integrations ADD COLUMN IF NOT EXISTS insights_sync_at timestamptz;
ALTER TABLE integrations ADD COLUMN IF NOT EXISTS insights_synced_through date;
-- A. the Meta user who connected the office (a hash only), to match Meta's deauthorize / data-deletion callbacks
ALTER TABLE integrations ADD COLUMN IF NOT EXISTS meta_user_hash text;

-- ============================================================ E. lead quality (separate from the sales stage)
-- The statuses are the owner's specification (2026-11-25). WHO may classify is the permission leads.quality, held by the
-- owner role only until the owner decides; no automatic classification exists.
ALTER TABLE leads ADD COLUMN IF NOT EXISTS quality text NOT NULL DEFAULT 'unreviewed';
DO $$ BEGIN
  ALTER TABLE leads ADD CONSTRAINT leads_quality CHECK (quality IN ('unreviewed', 'qualified', 'not_qualified', 'invalid_contact', 'duplicate', 'unreachable'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS leads_quality ON leads (quality) WHERE quality <> 'unreviewed';

CREATE TABLE IF NOT EXISTS lead_quality_events (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id    uuid NOT NULL REFERENCES leads(id) ON DELETE CASCADE ON UPDATE CASCADE,
  from_q     text NOT NULL,
  to_q       text NOT NULL CHECK (to_q IN ('unreviewed', 'qualified', 'not_qualified', 'invalid_contact', 'duplicate', 'unreachable')),
  reason     text NOT NULL DEFAULT '' CHECK (length(reason) <= 500),
  evidence   jsonb,
  by_id      uuid REFERENCES employees(id) ON DELETE SET NULL ON UPDATE CASCADE,
  at         timestamptz NOT NULL DEFAULT now(),
  -- rejecting or invalidating a lead needs a reason (owner's specification)
  CONSTRAINT lead_quality_events_reason CHECK (to_q IN ('unreviewed', 'qualified') OR length(trim(reason)) >= 3)
);
CREATE INDEX IF NOT EXISTS lead_quality_events_lead ON lead_quality_events (lead_id, at DESC);
CREATE INDEX IF NOT EXISTS lead_quality_events_by ON lead_quality_events (by_id) WHERE by_id IS NOT NULL;
-- the history is append-only (a correction is a new event)
CREATE OR REPLACE FUNCTION lead_quality_events_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'lead quality history is append-only' USING ERRCODE = 'check_violation'; END $$;
DROP TRIGGER IF EXISTS lead_quality_events_immutable ON lead_quality_events;
CREATE TRIGGER lead_quality_events_immutable BEFORE UPDATE ON lead_quality_events FOR EACH ROW EXECUTE FUNCTION lead_quality_events_immutable();

INSERT INTO permissions (key, description) VALUES ('leads.quality', 'Leads: classify a lead''s quality (qualified / not qualified / invalid …)')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key) SELECT 'owner', 'leads.quality' WHERE EXISTS (SELECT 1 FROM roles WHERE key = 'owner')
  ON CONFLICT DO NOTHING;

-- ============================================================ F. KPI calculation sources
-- A definition may name a calculator (code: modules/kpi_auto.ts). It is used only once the owner approved it (approved_at);
-- until then every KPI stays manual. A result records where its value came from; manual entries are never overwritten.
ALTER TABLE kpi_definitions ADD COLUMN IF NOT EXISTS calc_source text;
ALTER TABLE kpi_definitions ADD COLUMN IF NOT EXISTS calc_approved_by uuid REFERENCES employees(id) ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE kpi_definitions ADD COLUMN IF NOT EXISTS calc_approved_at timestamptz;
DO $$ BEGIN
  ALTER TABLE kpi_definitions ADD CONSTRAINT kpi_definitions_calc_approval CHECK (calc_approved_at IS NULL OR calc_source IS NOT NULL);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE kpi_results ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'manual';
DO $$ BEGIN
  ALTER TABLE kpi_results ADD CONSTRAINT kpi_results_source CHECK (source IN ('manual', 'auto'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE kpi_results ADD COLUMN IF NOT EXISTS calculated_at timestamptz;
ALTER TABLE kpi_results ADD COLUMN IF NOT EXISTS evidence jsonb;
