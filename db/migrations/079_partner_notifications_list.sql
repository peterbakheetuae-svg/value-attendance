-- شركة التسويق's notifications in the same page as everyone's: kept rows (read / deleted like an employee's), filled from
-- what happened on its campaigns' leads (a new lead, a salesman's follow-up)
CREATE TABLE partner_notifications (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES marketing_companies(id) ON DELETE CASCADE,
  key        text NOT NULL,
  type       text NOT NULL,
  title      text NOT NULL,
  body       text NOT NULL DEFAULT '',
  entity     text,
  entity_id  text,
  created_at timestamptz NOT NULL,
  read_at    timestamptz,
  deleted    boolean NOT NULL DEFAULT false,
  UNIQUE (company_id, key)
);
CREATE INDEX partner_notifications_company ON partner_notifications (company_id, created_at DESC) WHERE NOT deleted;
