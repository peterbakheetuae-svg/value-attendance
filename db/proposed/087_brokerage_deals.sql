-- 087 — Resale and rental (الإعادة بيع / الإيجار) under «التسويق» — PROPOSED, apply only with the owner's approval.
-- Additive, one transaction, safe to re-run. Until it runs the API answers installed:false and the app shows nothing new.
--
--  • brokerage_deals: one resale or rental transaction. The sales employee registers it and proposes the commission
--    (resale: 1 % – 2.5 % of the price; rental: one month from the owner / from the tenant / half from each / one month
--    from one side / a fixed amount — each side's amount kept on its own). The general manager (brokerage.approve) approves
--    the distribution; from then on the agreement is frozen (database trigger) and kept as an immutable snapshot.
--  • brokerage_shares: who gets what — the property contributor, the closing salesperson, the sales manager, other approved
--    beneficiaries — as a percentage or a fixed amount, validated against the commission. Frozen once approved.
--  • cash_receipts.brokerage_deal_id / brokerage_side: a commission collected from the owner or the client side goes into
--    a cashbox as kind 'commission' (office revenue — only when actually collected; the rest stays a receivable).
--  • cash_expenses.brokerage_share_id: the settlement of an approved beneficiary outside the staff (one live per share).
--  • A reversed commission receipt re-opens a collected deal and cancels its entitlements (refused once any share was paid).
--  • commission_entitlements.brokerage_share_id: once the commission is fully collected each employee share becomes a
--    commission entitlement of that month (paid with «صرف العمولة», counted in payroll like every other commission).
--    request_id becomes nullable for these rows only (CHECK: exactly one of request_id / brokerage_share_id).

CREATE TABLE IF NOT EXISTS brokerage_deals (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind               text NOT NULL CHECK (kind IN ('resale', 'rental')),
  status             text NOT NULL DEFAULT 'proposed' CHECK (status IN ('proposed', 'approved', 'rejected', 'cancelled', 'collected')),
  property           text NOT NULL CHECK (length(trim(property)) BETWEEN 2 AND 300),
  owner_name         text NOT NULL CHECK (length(trim(owner_name)) BETWEEN 2 AND 120),
  owner_phone        text NOT NULL DEFAULT '',
  client_name        text NOT NULL CHECK (length(trim(client_name)) BETWEEN 2 AND 120),  -- the buyer / the tenant
  client_phone       text NOT NULL DEFAULT '',
  price_egp          numeric(16,2) NOT NULL CHECK (price_egp > 0),                     -- sale price / monthly rent
  rate_pct           numeric(6,3) CHECK (rate_pct IS NULL OR (rate_pct >= 1 AND rate_pct <= 2.5)),
  arrangement        text CHECK (arrangement IS NULL OR arrangement IN ('owner_month', 'client_month', 'half_each', 'fixed', 'percent')),
  owner_commission_egp  numeric(14,2) NOT NULL DEFAULT 0 CHECK (owner_commission_egp >= 0),
  client_commission_egp numeric(14,2) NOT NULL DEFAULT 0 CHECK (client_commission_egp >= 0),
  total_commission_egp  numeric(14,2) GENERATED ALWAYS AS (owner_commission_egp + client_commission_egp) STORED,
  contributor_id     uuid NOT NULL REFERENCES employees(id),      -- registered / brought the property
  closer_id          uuid NOT NULL REFERENCES employees(id),      -- completed the sale / rental (may be someone else)
  sales_manager_id   uuid REFERENCES employees(id),
  proposed_by        uuid NOT NULL REFERENCES employees(id),
  notes              text NOT NULL DEFAULT '' CHECK (length(notes) <= 1000),
  decided_by         uuid REFERENCES employees(id),
  decided_at         timestamptz,
  decision_note      text NOT NULL DEFAULT '',
  snapshot           jsonb,                                       -- the approved agreement + distribution, as approved
  collected_at       timestamptz,
  client_ref         uuid UNIQUE,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (owner_commission_egp + client_commission_egp > 0),
  CHECK (kind <> 'resale' OR (rate_pct IS NOT NULL AND arrangement = 'percent')),
  CHECK (kind <> 'rental' OR (arrangement IS NOT NULL AND arrangement <> 'percent'))
);
CREATE INDEX IF NOT EXISTS brokerage_deals_kind ON brokerage_deals (kind, status, created_at DESC);

CREATE TABLE IF NOT EXISTS brokerage_shares (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deal_id      uuid NOT NULL REFERENCES brokerage_deals(id),
  role         text NOT NULL CHECK (role IN ('contributor', 'closer', 'sales_manager', 'other')),
  employee_id  uuid REFERENCES employees(id),                      -- null: an approved beneficiary outside the staff
  beneficiary  text NOT NULL DEFAULT '' CHECK (length(beneficiary) <= 120),
  mode         text NOT NULL CHECK (mode IN ('pct', 'fixed')),
  value        numeric(14,4) NOT NULL CHECK (value > 0),
  amount_egp   numeric(14,2) NOT NULL CHECK (amount_egp > 0),
  created_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (employee_id IS NOT NULL OR length(trim(beneficiary)) >= 2)
);
CREATE INDEX IF NOT EXISTS brokerage_shares_deal ON brokerage_shares (deal_id);

-- an approved agreement never changes: no edit of its terms, no deletion; shares are written once (at approval)
CREATE OR REPLACE FUNCTION brokerage_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_TABLE_NAME = 'brokerage_shares' THEN
    RAISE EXCEPTION 'an approved commission distribution cannot be changed';
  END IF;
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'a brokerage deal is never deleted'; END IF;
  IF OLD.status IN ('approved', 'collected') AND (
       NEW.kind, NEW.property, NEW.owner_name, NEW.client_name, NEW.price_egp, NEW.rate_pct, NEW.arrangement,
       NEW.owner_commission_egp, NEW.client_commission_egp, NEW.contributor_id, NEW.closer_id, NEW.sales_manager_id,
       NEW.proposed_by, NEW.decided_by, NEW.decided_at, NEW.snapshot)
     IS DISTINCT FROM (
       OLD.kind, OLD.property, OLD.owner_name, OLD.client_name, OLD.price_egp, OLD.rate_pct, OLD.arrangement,
       OLD.owner_commission_egp, OLD.client_commission_egp, OLD.contributor_id, OLD.closer_id, OLD.sales_manager_id,
       OLD.proposed_by, OLD.decided_by, OLD.decided_at, OLD.snapshot) THEN
    RAISE EXCEPTION 'an approved commission agreement cannot be changed';
  END IF;
  -- collected → approved only: a reversed collection reopens the deal (its entitlements are cancelled in the same transaction)
  IF OLD.status = 'collected' AND NEW.status IS DISTINCT FROM OLD.status AND NEW.status <> 'approved' THEN
    RAISE EXCEPTION 'a collected deal can only be reopened by a reversal';
  END IF;
  IF OLD.status IN ('rejected', 'cancelled') AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'a % deal is final', OLD.status;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS brokerage_deals_guard ON brokerage_deals;
CREATE TRIGGER brokerage_deals_guard BEFORE UPDATE OR DELETE ON brokerage_deals FOR EACH ROW EXECUTE FUNCTION brokerage_guard();
DROP TRIGGER IF EXISTS brokerage_shares_guard ON brokerage_shares;
CREATE TRIGGER brokerage_shares_guard BEFORE UPDATE OR DELETE ON brokerage_shares FOR EACH ROW EXECUTE FUNCTION brokerage_guard();

-- the commission collected for a deal, and from which side
ALTER TABLE cash_receipts ADD COLUMN IF NOT EXISTS brokerage_deal_id uuid REFERENCES brokerage_deals(id);
ALTER TABLE cash_receipts ADD COLUMN IF NOT EXISTS brokerage_side text;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'cash_receipts_brokerage_side') THEN
    ALTER TABLE cash_receipts ADD CONSTRAINT cash_receipts_brokerage_side CHECK (
      (brokerage_deal_id IS NULL AND brokerage_side IS NULL)
      OR (brokerage_deal_id IS NOT NULL AND brokerage_side IN ('owner', 'client') AND kind = 'commission'));
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS cash_receipts_brokerage ON cash_receipts (brokerage_deal_id) WHERE brokerage_deal_id IS NOT NULL;

-- an approved beneficiary outside the staff is paid from the office cashbox: one expense linked to his share, one live
-- (not reversed) settlement per share; reversing that expense re-opens the share for settlement
ALTER TABLE cash_expenses ADD COLUMN IF NOT EXISTS brokerage_share_id uuid REFERENCES brokerage_shares(id);
CREATE UNIQUE INDEX IF NOT EXISTS cash_expenses_brokerage_share_live ON cash_expenses (brokerage_share_id)
  WHERE brokerage_share_id IS NOT NULL AND status <> 'reversed';

-- an employee's share becomes a commission entitlement (payroll, «صرف العمولة») once the commission is collected
ALTER TABLE commission_entitlements ADD COLUMN IF NOT EXISTS brokerage_share_id uuid UNIQUE REFERENCES brokerage_shares(id);
ALTER TABLE commission_entitlements ALTER COLUMN request_id DROP NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'commission_entitlements_one_source') THEN
    ALTER TABLE commission_entitlements ADD CONSTRAINT commission_entitlements_one_source
      CHECK ((request_id IS NULL) <> (brokerage_share_id IS NULL));
  END IF;
END $$;

-- permissions: approving the distribution follows «اعتماد طلبات العمولة»; registering a deal follows «حجز وحدة»
INSERT INTO permissions (key, description) VALUES
  ('brokerage.propose', 'Register a resale / rental deal and propose its commission'),
  ('brokerage.approve', 'Approve / reject a resale / rental commission and its distribution'),
  ('brokerage.view_all', 'See every resale / rental deal')
  ON CONFLICT (key) DO NOTHING;
CREATE TEMP TABLE m087 (fine text, broad text) ON COMMIT DROP;
INSERT INTO m087 VALUES ('brokerage.propose', 'exclusive.reserve'), ('brokerage.approve', 'commission.approve'),
  ('brokerage.view_all', 'commission.approve'), ('brokerage.view_all', 'cash.office');
INSERT INTO role_permissions (role_key, perm_key)
  SELECT DISTINCT rp.role_key, m.fine FROM role_permissions rp JOIN m087 m ON m.broad = rp.perm_key
  ON CONFLICT DO NOTHING;
INSERT INTO employee_permissions (employee_id, perm_key, allow)
  SELECT DISTINCT ep.employee_id, m.fine, ep.allow FROM employee_permissions ep JOIN m087 m ON m.broad = ep.perm_key
  ON CONFLICT DO NOTHING;
