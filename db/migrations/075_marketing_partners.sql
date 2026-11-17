-- شركات التسويق (marketing agencies) and the Meta campaigns each of our campaigns takes its leads from.
--  * a marketing company is NOT an employee: it signs in with its own e-mail / mobile + password (its own sessions table,
--    so its token is refused by every employee endpoint) and reaches only /partner/… — its dashboard, the leads of the
--    campaigns linked to it (read-only: stage, salesman, comments, closed or not) and adding a lead to one of them.
--  * lead_campaigns.marketing_company_id: the company running that campaign.
--  * lead_campaigns.meta_campaign_ids: the Meta (Facebook / Instagram) campaigns whose lead-form leads come to it. A lead
--    from a Meta campaign linked to none of ours is not added (only the chosen campaigns come in); it is counted in
--    meta_seen_campaigns so it can be linked from the settings.
-- the marketing companies already exist (041, «شركات التسويق» of the projects / cashbox): each gets its own sign-in
ALTER TABLE marketing_companies
  ADD COLUMN login_email          text CHECK (login_email IS NULL OR length(login_email) <= 160),
  ADD COLUMN login_phone          text CHECK (login_phone IS NULL OR length(login_phone) <= 30),
  ADD COLUMN login_phone_norm     text,
  ADD COLUMN password_hash        text,                     -- NULL = no sign-in
  ADD COLUMN must_change_password boolean NOT NULL DEFAULT true,
  ADD COLUMN failed_logins        int NOT NULL DEFAULT 0,
  ADD COLUMN locked_until         timestamptz,
  ADD CONSTRAINT marketing_companies_login CHECK (password_hash IS NULL OR login_email IS NOT NULL OR login_phone IS NOT NULL);
CREATE UNIQUE INDEX marketing_companies_login_email ON marketing_companies (lower(login_email)) WHERE login_email IS NOT NULL;
CREATE UNIQUE INDEX marketing_companies_login_phone ON marketing_companies (login_phone_norm) WHERE login_phone_norm IS NOT NULL;

CREATE TABLE partner_sessions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash   bytea NOT NULL UNIQUE,
  company_id   uuid NOT NULL REFERENCES marketing_companies(id) ON DELETE CASCADE,
  expires_at   timestamptz NOT NULL,
  revoked_at   timestamptz,
  last_seen_at timestamptz,
  user_agent   text NOT NULL DEFAULT '',
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX partner_sessions_company ON partner_sessions (company_id);

ALTER TABLE lead_campaigns ADD COLUMN marketing_company_id uuid REFERENCES marketing_companies(id) ON DELETE SET NULL;
ALTER TABLE lead_campaigns ADD COLUMN meta_campaign_ids text[] NOT NULL DEFAULT '{}';
CREATE INDEX lead_campaigns_company ON lead_campaigns (marketing_company_id) WHERE marketing_company_id IS NOT NULL;

-- a lead the marketing company added itself
ALTER TABLE leads ADD COLUMN partner_company_id uuid REFERENCES marketing_companies(id) ON DELETE SET NULL;

-- Meta campaigns leads arrived from (linked or not): what the settings offer to link
CREATE TABLE meta_seen_campaigns (
  campaign_id text PRIMARY KEY CHECK (campaign_id ~ '^[0-9]{3,30}$'),
  name        text NOT NULL DEFAULT '',
  leads       int NOT NULL DEFAULT 0,       -- leads received from it
  skipped     int NOT NULL DEFAULT 0,       -- of those, not added (the campaign was linked to none of ours)
  last_at     timestamptz NOT NULL DEFAULT now()
);

-- the sign-ins and the campaign links are set from the leads settings (leads.config); no new permission key
