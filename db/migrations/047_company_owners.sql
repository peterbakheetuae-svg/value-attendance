-- ضخ أموال: each owner's share of the company (نسبة الملكية) — his part of the office's net profit
-- (the commissions after salaries and expenses).
CREATE TABLE company_owners (
  employee_id uuid PRIMARY KEY REFERENCES employees(id),
  pct         numeric(7,4) NOT NULL CHECK (pct >= 0 AND pct <= 100),
  updated_by  uuid REFERENCES employees(id),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
