-- شركة التسويق's file, like an employee's (without what only an employee has: national ID, birth date, job, day off,
-- attendance, selfie, working hours, absence multiplier, the employee documents):
--  * المدير العام and المدير المباشر (the direct manager is an «مسؤول إداري»)
--  * تاريخ التعاقد; الوضع = status: active «متعاقد» / inactive «تم فسخ التعاقد» (the existing column)
--  * المحاسبة = kind: fixed «مبلغ ثابت» (monthly_fee) / commission «بالعمولة» (default_pct) (the existing columns)
--  * its documents: عقد التعاقد، بلان الاتفاقات المالية، رؤية الشركة للتنفيذ (+ its logo)
ALTER TABLE marketing_companies
  ADD COLUMN general_manager_id uuid REFERENCES employees(id),
  ADD COLUMN manager_id         uuid REFERENCES employees(id),
  ADD COLUMN contract_date      date;

CREATE TABLE marketing_company_files (
  company_id  uuid NOT NULL REFERENCES marketing_companies(id) ON DELETE CASCADE,
  kind        text NOT NULL CHECK (kind IN ('contract', 'financial_plan', 'execution_vision', 'logo')),
  file_name   text NOT NULL CHECK (length(file_name) BETWEEN 1 AND 200),
  mime        text NOT NULL CHECK (mime IN ('application/pdf', 'image/jpeg', 'image/png', 'image/webp')),
  data        bytea NOT NULL CHECK (octet_length(data) <= 3 * 1024 * 1024),
  uploaded_by uuid REFERENCES employees(id),
  uploaded_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (company_id, kind)
);
