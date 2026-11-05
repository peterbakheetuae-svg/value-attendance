-- Project commission management (إدارة عمولات المشاريع).
--  * commission_projects: one row per real-estate project with its commission split (percent of unit value).
--  * commission_requests: a salesperson's "عمولة صفقة" for one sold unit; the percentages and amounts are
--    frozen on the row (snapshot) and can never change after approval — editing the project later only
--    affects new requests.
--  * commission_entitlements: what goes into the monthly payroll (salesperson + his sales manager), one row
--    per request and role, so the payroll can never count the same unit twice. The company's share is
--    reported only and never enters any payroll.
--  Paying a commission uses the existing صرف مالية (payouts, kind 'commission') linked to the entitlement.

INSERT INTO permissions (key, description) VALUES
  ('commission.project_manage', 'Create / edit real-estate projects and their commission split'),
  ('commission.company_view',   'See the company commission share, earnings and profit'),
  ('commission.approve',        'Approve / reject deal-commission requests and pick the payroll month'),
  ('commission.read_all',       'See every approved commission and employee entitlement (payroll)'),
  ('commission.read_team',      'See projects and the sold units of own sales team (no company figures)')
  ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role_key, perm_key) VALUES
  ('owner','commission.project_manage'), ('owner','commission.company_view'), ('owner','commission.approve'),
  ('owner','commission.read_all'), ('owner','commission.read_team'),
  ('manager','commission.project_manage'), ('manager','commission.company_view'), ('manager','commission.approve'),
  ('manager','commission.read_all'), ('manager','commission.read_team'),
  ('hr_manager','commission.read_all'),
  ('sales_manager','commission.read_team')
  ON CONFLICT DO NOTHING;
-- job positions built on those roles get the same new permissions
INSERT INTO role_permissions (role_key, perm_key)
SELECT r.key, rp.perm_key FROM roles r JOIN role_permissions rp ON rp.role_key = r.base_key
 WHERE r.base_key IS NOT NULL AND rp.perm_key LIKE 'commission.%'
ON CONFLICT DO NOTHING;

CREATE TABLE commission_projects (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text NOT NULL CHECK (length(trim(name)) BETWEEN 2 AND 120),
  total_pct    numeric(7,4) NOT NULL CHECK (total_pct > 0 AND total_pct <= 100),
  sales_pct    numeric(7,4) NOT NULL CHECK (sales_pct >= 0),
  manager_pct  numeric(7,4) NOT NULL CHECK (manager_pct >= 0),
  company_pct  numeric(7,4) NOT NULL CHECK (company_pct >= 0),
  status       text NOT NULL DEFAULT 'active' CHECK (status IN ('active','paused','closed')),
  created_by   uuid NOT NULL REFERENCES employees(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (sales_pct + manager_pct + company_pct = total_pct)
);
CREATE UNIQUE INDEX commission_projects_name ON commission_projects (lower(trim(name)));

CREATE TABLE commission_requests (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ref             bigserial UNIQUE,                                   -- short number shown as "طلب #"
  project_id      uuid NOT NULL REFERENCES commission_projects(id),
  employee_id     uuid NOT NULL REFERENCES employees(id),            -- the salesperson (always the signed-in user)
  sales_manager_id uuid REFERENCES employees(id),                     -- his direct manager, frozen at approval
  unit_no         text NOT NULL CHECK (length(trim(unit_no)) BETWEEN 1 AND 60),
  price_per_m2    numeric(14,2) NOT NULL CHECK (price_per_m2 > 0),
  area_m2         numeric(10,2) NOT NULL CHECK (area_m2 > 0),
  unit_value      numeric(16,2) NOT NULL CHECK (unit_value > 0),
  total_pct       numeric(7,4) NOT NULL,
  sales_pct       numeric(7,4) NOT NULL,
  manager_pct     numeric(7,4) NOT NULL,
  company_pct     numeric(7,4) NOT NULL,
  sales_amount    numeric(14,2) NOT NULL,
  manager_amount  numeric(14,2) NOT NULL,
  company_amount  numeric(14,2) NOT NULL,
  note            text NOT NULL DEFAULT '' CHECK (length(note) <= 1000),
  status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','voided')),
  period          date CHECK (period IS NULL OR extract(day FROM period) = 1),  -- payroll month
  decided_by      uuid REFERENCES employees(id),
  decided_at      timestamptz,
  reject_reason   text,
  voided_by       uuid REFERENCES employees(id),
  voided_at       timestamptz,
  void_reason     text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (sales_pct + manager_pct + company_pct = total_pct),
  CHECK (status <> 'approved' OR (period IS NOT NULL AND decided_by IS NOT NULL AND decided_at IS NOT NULL)),
  CHECK (status <> 'rejected' OR (decided_by IS NOT NULL AND length(trim(COALESCE(reject_reason,''))) >= 3)),
  CHECK (status <> 'voided' OR (voided_by IS NOT NULL AND length(trim(COALESCE(void_reason,''))) >= 3)),
  CHECK (decided_by IS NULL OR decided_by <> employee_id)
);
-- one live request per unit of a project (pending or approved); a rejected / voided one frees the unit
CREATE UNIQUE INDEX commission_requests_unit ON commission_requests (project_id, lower(trim(unit_no)))
  WHERE status IN ('pending','approved');
CREATE INDEX commission_requests_employee ON commission_requests (employee_id, created_at DESC);
CREATE INDEX commission_requests_status ON commission_requests (status, created_at DESC);

-- an approved request is a frozen financial record: only the void fields may change afterwards
CREATE FUNCTION commission_requests_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'commission requests are never deleted'; END IF;
  IF OLD.status IN ('approved','rejected','voided') THEN
    IF NOT (OLD.status = 'approved' AND NEW.status = 'voided') THEN
      RAISE EXCEPTION 'a decided commission request cannot be changed';
    END IF;
    IF (NEW.project_id, NEW.employee_id, NEW.sales_manager_id, NEW.unit_no, NEW.price_per_m2, NEW.area_m2, NEW.unit_value,
        NEW.total_pct, NEW.sales_pct, NEW.manager_pct, NEW.company_pct, NEW.sales_amount, NEW.manager_amount,
        NEW.company_amount, NEW.period, NEW.decided_by, NEW.decided_at, NEW.created_at)
       IS DISTINCT FROM
       (OLD.project_id, OLD.employee_id, OLD.sales_manager_id, OLD.unit_no, OLD.price_per_m2, OLD.area_m2, OLD.unit_value,
        OLD.total_pct, OLD.sales_pct, OLD.manager_pct, OLD.company_pct, OLD.sales_amount, OLD.manager_amount,
        OLD.company_amount, OLD.period, OLD.decided_by, OLD.decided_at, OLD.created_at) THEN
      RAISE EXCEPTION 'approved commission values are immutable';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER commission_requests_immutable BEFORE UPDATE OR DELETE ON commission_requests
  FOR EACH ROW EXECUTE FUNCTION commission_requests_guard();

CREATE TABLE commission_entitlements (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id   uuid NOT NULL REFERENCES commission_requests(id),
  employee_id  uuid NOT NULL REFERENCES employees(id),
  role         text NOT NULL CHECK (role IN ('sales','manager')),
  amount_egp   numeric(14,2) NOT NULL CHECK (amount_egp > 0),
  period       date NOT NULL CHECK (extract(day FROM period) = 1),
  status       text NOT NULL DEFAULT 'active' CHECK (status IN ('active','cancelled')),
  included_at  timestamptz NOT NULL DEFAULT now(),          -- added to that month's payroll
  cancelled_at timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (request_id, role)                                -- idempotent: a unit pays each role once
);
CREATE INDEX commission_entitlements_payroll ON commission_entitlements (employee_id, period) WHERE status = 'active';

-- paying an entitlement goes through صرف مالية; one live payout per entitlement
ALTER TABLE payouts ADD COLUMN commission_entitlement_id uuid REFERENCES commission_entitlements(id);
CREATE UNIQUE INDEX payouts_one_per_entitlement ON payouts (commission_entitlement_id)
  WHERE commission_entitlement_id IS NOT NULL AND status <> 'cancelled';
