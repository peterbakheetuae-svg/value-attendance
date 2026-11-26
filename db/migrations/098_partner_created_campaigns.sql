-- 2026-11-26: a marketing company may add its own campaign (linked to itself) and manage the ones it added. Who added a
-- campaign is kept so the company's management rights reach only those; campaigns the office created / linked stay the
-- office's (the company keeps choosing their Meta campaigns, as before). Additive, forward-only: existing campaigns get
-- NULL (= added by the office) and nothing else changes.
ALTER TABLE lead_campaigns ADD COLUMN IF NOT EXISTS created_by_company_id uuid REFERENCES marketing_companies(id);
