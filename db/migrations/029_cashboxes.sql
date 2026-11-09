-- Financial system, phase 1: the two cashboxes (office / HR), transfers between them, expenses, collections
-- (numbered receipts) and opening / reconciliation adjustments. Additive only: no existing table, column or
-- row is changed or removed.
--
-- One source of truth: every movement lives in its own table, and the view cash_ledger lines them up per cashbox
-- (it also takes in the existing صرف مالية payouts, so HR's existing payments count against the HR cashbox).
-- Book balance = sum(cash_ledger). The HR cashbox may go negative (= money the office owes it).
-- Nothing posted is ever deleted or edited: a correction is a reversal recorded next to the original.

INSERT INTO permissions (key, description) VALUES
  ('cash.office',     'Office cashbox: see it, record its collections / expenses, approve transfers and large HR expenses'),
  ('cash.hr_view',    'See the HR cashbox (balance, movements, expenses)'),
  ('cash.hr_operate', 'Run the HR cashbox: collections, expenses, transfer requests / hand-overs'),
  ('cash.settings',   'Cashbox settings (expense approval threshold, opening balances)')
  ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role_key, perm_key) VALUES
  ('owner','cash.office'), ('owner','cash.hr_view'), ('owner','cash.hr_operate'), ('owner','cash.settings'),
  ('manager','cash.office'), ('manager','cash.hr_view'), ('manager','cash.settings'),
  ('hr_manager','cash.hr_view'), ('hr_manager','cash.hr_operate')
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key)
SELECT r.key, rp.perm_key FROM roles r JOIN role_permissions rp ON rp.role_key = r.base_key
 WHERE r.base_key IS NOT NULL AND rp.perm_key LIKE 'cash.%'
ON CONFLICT DO NOTHING;

-- HR expenses above this amount wait for the manager first (approved policy: 1,000 EGP; editable)
ALTER TABLE company_settings ADD COLUMN expense_approval_threshold numeric(12,2) NOT NULL DEFAULT 1000
  CHECK (expense_approval_threshold >= 0);

CREATE SEQUENCE cash_ref_seq START 1001;   -- one running reference number for every cash document

-- opening balances and cash counts (reconciliation)
CREATE TABLE cash_adjustments (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_no       bigint NOT NULL UNIQUE DEFAULT nextval('cash_ref_seq'),
  cashbox      text NOT NULL CHECK (cashbox IN ('office','hr')),
  kind         text NOT NULL CHECK (kind IN ('opening','adjustment')),
  amount_egp   numeric(14,2) NOT NULL CHECK (amount_egp <> 0),      -- + adds to the box, − takes from it
  counted_cash numeric(14,2),                                        -- physical cash counted, for a reconciliation
  reason       text NOT NULL CHECK (length(trim(reason)) >= 3),
  created_by   uuid NOT NULL REFERENCES employees(id),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX cash_adjustments_one_opening ON cash_adjustments (cashbox) WHERE kind = 'opening';

-- collections (incoming money) with a numbered receipt
CREATE TABLE cash_receipts (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_no              bigint NOT NULL UNIQUE DEFAULT nextval('cash_ref_seq'),
  kind                text NOT NULL CHECK (kind IN ('reservation','down_payment','installment','settlement','other')),
  amount_egp          numeric(14,2) NOT NULL CHECK (amount_egp > 0),
  cashbox             text NOT NULL CHECK (cashbox IN ('office','hr')),
  actual_recipient_id uuid NOT NULL REFERENCES employees(id),          -- who physically got the money
  payer_name          text NOT NULL CHECK (length(trim(payer_name)) >= 2),
  payer_phone         text NOT NULL DEFAULT '',
  purpose             text NOT NULL CHECK (length(trim(purpose)) >= 2),
  payment_method      text NOT NULL DEFAULT 'cash' CHECK (payment_method IN ('cash','bank_transfer','cheque','card','wallet')),
  external_no         text,                                            -- paper receipt book number, if any
  client_ref          uuid UNIQUE,                                     -- same form sent twice → one receipt
  sale_id             uuid,                                            -- unit sale (phase 2)
  installment_id      uuid,                                            -- installment (phase 2)
  notes               text NOT NULL DEFAULT '',
  attachment          bytea CHECK (attachment IS NULL OR octet_length(attachment) <= 600000),
  occurred_at         timestamptz NOT NULL DEFAULT now(),
  recorded_by         uuid NOT NULL REFERENCES employees(id),
  status              text NOT NULL DEFAULT 'posted' CHECK (status IN ('posted','reversed')),
  reversed_by         uuid REFERENCES employees(id),
  reversed_at         timestamptz,
  reverse_reason      text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (status <> 'reversed' OR (reversed_by IS NOT NULL AND reversed_at IS NOT NULL AND length(trim(COALESCE(reverse_reason,''))) >= 3))
);
CREATE UNIQUE INDEX cash_receipts_external_no ON cash_receipts (lower(trim(external_no))) WHERE external_no IS NOT NULL AND trim(external_no) <> '';
CREATE INDEX cash_receipts_box ON cash_receipts (cashbox, occurred_at DESC);

-- expenses (outgoing money)
CREATE TABLE cash_expenses (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_no         bigint NOT NULL UNIQUE DEFAULT nextval('cash_ref_seq'),
  cashbox        text NOT NULL CHECK (cashbox IN ('office','hr')),
  amount_egp     numeric(14,2) NOT NULL CHECK (amount_egp > 0),
  category       text NOT NULL CHECK (length(trim(category)) >= 2),
  reason         text NOT NULL CHECK (length(trim(reason)) >= 2),
  beneficiary    text NOT NULL CHECK (length(trim(beneficiary)) >= 2),
  notes          text NOT NULL DEFAULT '',
  attachment     bytea CHECK (attachment IS NULL OR octet_length(attachment) <= 600000),
  client_ref     uuid UNIQUE,
  occurred_at    timestamptz NOT NULL DEFAULT now(),
  recorded_by    uuid NOT NULL REFERENCES employees(id),
  status         text NOT NULL CHECK (status IN ('pending_approval','posted','rejected','reversed')),
  approved_by    uuid REFERENCES employees(id),
  approved_at    timestamptz,
  reject_reason  text,
  reviewed_by    uuid REFERENCES employees(id),                  -- manager / owner looked at it after payment
  reviewed_at    timestamptz,
  reversed_by    uuid REFERENCES employees(id),
  reversed_at    timestamptz,
  reverse_reason text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CHECK (status <> 'reversed' OR (reversed_by IS NOT NULL AND reversed_at IS NOT NULL AND length(trim(COALESCE(reverse_reason,''))) >= 3)),
  CHECK (status <> 'rejected' OR length(trim(COALESCE(reject_reason,''))) >= 3)
);
CREATE INDEX cash_expenses_box ON cash_expenses (cashbox, occurred_at DESC);

-- transfers between the two cashboxes: request → approval (office→HR only) → hand-over → receipt confirmation
CREATE TABLE cash_transfers (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_no           bigint NOT NULL UNIQUE DEFAULT nextval('cash_ref_seq'),
  direction        text NOT NULL CHECK (direction IN ('office_to_hr','hr_to_office')),
  amount_requested numeric(14,2) NOT NULL CHECK (amount_requested > 0),
  reason           text NOT NULL CHECK (length(trim(reason)) >= 2),
  status           text NOT NULL DEFAULT 'requested'
                   CHECK (status IN ('requested','approved','rejected','executed','received','cancelled')),
  requested_by     uuid NOT NULL REFERENCES employees(id),
  requested_at     timestamptz NOT NULL DEFAULT now(),
  decided_by       uuid REFERENCES employees(id),
  decided_at       timestamptz,
  reject_reason    text,
  executed_by      uuid REFERENCES employees(id),                -- who handed the cash over
  executed_at      timestamptz,
  amount_executed  numeric(14,2) CHECK (amount_executed IS NULL OR amount_executed > 0),
  received_by      uuid REFERENCES employees(id),                -- who confirmed getting it
  received_at      timestamptz,
  CHECK (status NOT IN ('executed','received') OR (executed_by IS NOT NULL AND amount_executed IS NOT NULL)),
  CHECK (status <> 'received' OR (received_by IS NOT NULL AND received_at IS NOT NULL)),
  CHECK (received_by IS NULL OR received_by <> executed_by)      -- hand-over and receipt by two different people
);
CREATE INDEX cash_transfers_status ON cash_transfers (status, requested_at DESC);

-- money records are never deleted; posted amounts never edited (only their status moves forward)
CREATE FUNCTION cash_no_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'cash records are never deleted (record a reversal instead)'; END IF;
  RAISE EXCEPTION 'cash adjustments are final (record another adjustment)';
END $$;
CREATE FUNCTION cash_doc_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'cash records are never deleted (record a reversal instead)'; END IF;
  IF (NEW.amount_egp, NEW.cashbox, NEW.occurred_at, NEW.recorded_by, NEW.ref_no) IS DISTINCT FROM
     (OLD.amount_egp, OLD.cashbox, OLD.occurred_at, OLD.recorded_by, OLD.ref_no) THEN
    RAISE EXCEPTION 'posted amounts cannot be changed (record a reversal instead)';
  END IF;
  RETURN NEW;
END $$;
CREATE FUNCTION cash_transfer_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'cash records are never deleted'; END IF;
  IF OLD.status IN ('received','rejected','cancelled') THEN RAISE EXCEPTION 'a finished transfer cannot be changed'; END IF;
  IF OLD.amount_executed IS NOT NULL AND NEW.amount_executed IS DISTINCT FROM OLD.amount_executed THEN
    RAISE EXCEPTION 'the handed-over amount cannot be changed';
  END IF;
  IF (NEW.direction, NEW.amount_requested, NEW.requested_by, NEW.ref_no) IS DISTINCT FROM
     (OLD.direction, OLD.amount_requested, OLD.requested_by, OLD.ref_no) THEN
    RAISE EXCEPTION 'a transfer request cannot be edited';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER cash_adjustments_guard BEFORE UPDATE OR DELETE ON cash_adjustments FOR EACH ROW EXECUTE FUNCTION cash_no_delete();
CREATE TRIGGER cash_receipts_guard    BEFORE UPDATE OR DELETE ON cash_receipts    FOR EACH ROW EXECUTE FUNCTION cash_doc_guard();
CREATE TRIGGER cash_expenses_guard    BEFORE UPDATE OR DELETE ON cash_expenses    FOR EACH ROW EXECUTE FUNCTION cash_doc_guard();
CREATE TRIGGER cash_transfers_guard   BEFORE UPDATE OR DELETE ON cash_transfers   FOR EACH ROW EXECUTE FUNCTION cash_transfer_guard();

-- every movement per cashbox (+ in / − out); reversals appear as their own opposite line on the reversal date
CREATE VIEW cash_ledger AS
  SELECT a.cashbox, a.amount_egp AS amount, a.created_at AS at, a.kind AS type, a.ref_no, a.id AS source_id,
         'cash_adjustments'::text AS source, a.reason AS label, a.created_by AS by_id
    FROM cash_adjustments a
  UNION ALL
  SELECT r.cashbox, r.amount_egp, r.occurred_at, 'receipt', r.ref_no, r.id, 'cash_receipts', r.purpose || ' — ' || r.payer_name, r.recorded_by
    FROM cash_receipts r
  UNION ALL
  SELECT r.cashbox, -r.amount_egp, r.reversed_at, 'receipt_reversal', r.ref_no, r.id, 'cash_receipts', r.reverse_reason, r.reversed_by
    FROM cash_receipts r WHERE r.status = 'reversed'
  UNION ALL
  SELECT e.cashbox, -e.amount_egp, COALESCE(e.approved_at, e.occurred_at), 'expense', e.ref_no, e.id, 'cash_expenses', e.category || ' — ' || e.reason, e.recorded_by
    FROM cash_expenses e WHERE e.status IN ('posted','reversed')
  UNION ALL
  SELECT e.cashbox, e.amount_egp, e.reversed_at, 'expense_reversal', e.ref_no, e.id, 'cash_expenses', e.reverse_reason, e.reversed_by
    FROM cash_expenses e WHERE e.status = 'reversed'
  UNION ALL
  SELECT CASE t.direction WHEN 'office_to_hr' THEN 'office' ELSE 'hr' END, -t.amount_executed, t.received_at,
         'transfer_out', t.ref_no, t.id, 'cash_transfers', t.reason, t.executed_by
    FROM cash_transfers t WHERE t.status = 'received'
  UNION ALL
  SELECT CASE t.direction WHEN 'office_to_hr' THEN 'hr' ELSE 'office' END, t.amount_executed, t.received_at,
         'transfer_in', t.ref_no, t.id, 'cash_transfers', t.reason, t.received_by
    FROM cash_transfers t WHERE t.status = 'received'
  UNION ALL
  -- existing صرف مالية: money the manager / owner handed HR ("صرف أموال") once HR confirmed it …
  SELECT 'hr', p.amount_egp, p.received_at, 'fund_in', NULL, p.id, 'payouts', p.note, p.employee_id
    FROM payouts p WHERE p.kind = 'fund' AND p.status = 'received'
  UNION ALL
  SELECT 'office', -p.amount_egp, p.received_at, 'fund_out', NULL, p.id, 'payouts', p.note, p.created_by
    FROM payouts p WHERE p.kind = 'fund' AND p.status = 'received'
  UNION ALL
  -- … and every salary / advance / commission / work-expense payment HR made (not cancelled)
  SELECT 'hr', -p.amount_egp, p.created_at, 'payout_' || p.kind, NULL, p.id, 'payouts', p.note, p.created_by
    FROM payouts p WHERE p.kind <> 'fund' AND p.status <> 'cancelled';
