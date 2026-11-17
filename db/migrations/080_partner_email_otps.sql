-- «تعديل الحساب» of a marketing company: a new e-mail is kept only after the 4-digit code sent to it is entered
CREATE TABLE partner_email_otps (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id  uuid NOT NULL REFERENCES marketing_companies(id) ON DELETE CASCADE,
  new_email   text NOT NULL,
  code_hash   text NOT NULL,
  attempts    int NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL,
  verified_at timestamptz
);
CREATE INDEX partner_email_otps_company ON partner_email_otps (company_id, created_at DESC);
