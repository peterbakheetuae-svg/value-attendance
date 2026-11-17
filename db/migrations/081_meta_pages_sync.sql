-- Meta: several Facebook pages (each with its own page token, subscribed to «leadgen»), and the leads of a linked Meta
-- campaign pulled from Meta by themselves (not only the ones the webhook pushes): every Meta lead comes in once
CREATE TABLE meta_pages (
  page_id      text PRIMARY KEY,
  name         text NOT NULL DEFAULT '',
  access_token text NOT NULL,
  subscribed   boolean NOT NULL DEFAULT false,
  last_error   text,
  added_at     timestamptz NOT NULL DEFAULT now(),
  added_by     uuid REFERENCES employees(id) ON DELETE SET NULL
);
ALTER TABLE leads ADD COLUMN meta_lead_id text;
CREATE UNIQUE INDEX leads_meta_lead_id ON leads (meta_lead_id) WHERE meta_lead_id IS NOT NULL;
ALTER TABLE lead_campaigns ADD COLUMN meta_synced_at timestamptz;
ALTER TABLE integrations ADD COLUMN meta_sync_at timestamptz;
