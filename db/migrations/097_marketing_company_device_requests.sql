-- 2026-11-26: a marketing company signing in from a new device ASKS for it (as an employee's new phone does) instead of
-- being refused with no request: the request is kept on the company row (a company has one linked device), its approvers
-- (devices.approve holders — the administrative officer, the owner — and the company's own general manager / direct
-- manager) are told, and approving makes it the company's device. Additive, forward-only: existing rows are unchanged
-- (no pending request, nothing rejected).
ALTER TABLE marketing_companies
  ADD COLUMN IF NOT EXISTS pending_device_id    text CHECK (pending_device_id IS NULL OR pending_device_id ~ '^[A-Za-z0-9_-]{16,100}$'),
  ADD COLUMN IF NOT EXISTS pending_device_label text,
  ADD COLUMN IF NOT EXISTS pending_device_at    timestamptz,
  ADD COLUMN IF NOT EXISTS rejected_device_ids  text[] NOT NULL DEFAULT '{}';
