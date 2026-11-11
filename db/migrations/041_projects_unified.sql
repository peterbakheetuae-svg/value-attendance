-- One projects system for both kinds (حصري / تسويق), one sales flow (حجز → تعاقد) for both, and the cashbox split
-- the way the office reads its money:
--   المتاح = بنك + نقدي (نقدي = خزنة المكتب + خزنة المحاسب)
--   الدخل = عمولات (الربح الوحيد) / مبيعات (حجوزات، تعاقد، أقساط) / ضخ من المالك - المدير العام / أمانات (الحصري)
-- Additive only.

-- 1) marketing companies: one paid a fixed monthly fee (an office expense), one paid a commission on the sales it
--    brings (its % comes out of the office's share of that unit's commission)
CREATE TABLE marketing_companies (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text NOT NULL CHECK (length(trim(name)) BETWEEN 2 AND 120),
  kind         text NOT NULL CHECK (kind IN ('fixed','commission')),
  default_pct  numeric(7,4) NOT NULL DEFAULT 0 CHECK (default_pct >= 0 AND default_pct <= 100),
  monthly_fee  numeric(14,2) NOT NULL DEFAULT 0 CHECK (monthly_fee >= 0),
  phone        text NOT NULL DEFAULT '',
  status       text NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive')),
  created_by   uuid NOT NULL REFERENCES employees(id),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX marketing_companies_name ON marketing_companies (lower(trim(name)));

-- 2) units of either kind; the marketing company that brought the client (and its %, frozen on the unit)
ALTER TABLE ex_units ADD COLUMN mk_company_id uuid REFERENCES marketing_companies(id),
                     ADD COLUMN mk_pct numeric(7,4) NOT NULL DEFAULT 0 CHECK (mk_pct >= 0 AND mk_pct <= 100);

-- 3) expenses: paid in cash or from the bank account; a marketing company's fee / commission is linked to it
ALTER TABLE cash_expenses ADD COLUMN payment_method text NOT NULL DEFAULT 'cash' CHECK (payment_method IN ('cash','bank')),
                          ADD COLUMN marketing_company_id uuid REFERENCES marketing_companies(id);

-- 4) receipts: a developer paying the office its commission (عمولة مستلمة) and the owner injecting money (ضخ)
ALTER TABLE cash_receipts DROP CONSTRAINT IF EXISTS cash_receipts_kind_check;
ALTER TABLE cash_receipts ADD CONSTRAINT cash_receipts_kind_check
  CHECK (kind IN ('reservation','down_payment','installment','settlement','other','commission','injection'));
ALTER TABLE cash_receipts ADD COLUMN project_id uuid REFERENCES commission_projects(id);
CREATE INDEX cash_receipts_kind ON cash_receipts (kind, occurred_at DESC);
