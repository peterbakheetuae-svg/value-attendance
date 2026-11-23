-- 089 — a resale / rental sale made from a lead (لوحة السيلز → «بيع / إيجار عقار») — additive, safe to re-run. Needs 087.
--  • brokerage_deals.lead_id: the client's lead. Selling a listing from the lead moves the lead to «حجز» (waiting for the
--    commission); the commission received → «صفقة مكتملة»; the sale cancelled / rejected → back to «متابعة» — each step
--    written on the lead as a system action, like a project unit's reservation.
ALTER TABLE brokerage_deals ADD COLUMN IF NOT EXISTS lead_id uuid REFERENCES leads(id);
CREATE INDEX IF NOT EXISTS brokerage_deals_lead ON brokerage_deals (lead_id) WHERE lead_id IS NOT NULL;
