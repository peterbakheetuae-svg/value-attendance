-- the sales board's extra cards: a tap on «اتصال» / «واتساب» from a lead is logged (Phone Call / WhatsApp Contacts)
ALTER TABLE lead_logs DROP CONSTRAINT lead_logs_kind_check;
ALTER TABLE lead_logs ADD CONSTRAINT lead_logs_kind_check
  CHECK (kind IN ('create','assign','edit','view','duplicate','referral','import','form','attachment','checkin','request','rating','bulk',
                  'call','whatsapp'));
CREATE INDEX lead_logs_contact ON lead_logs (kind, created_at) WHERE kind IN ('call','whatsapp');
CREATE INDEX IF NOT EXISTS leads_created_at ON leads (created_at);
