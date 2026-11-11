-- The sales flow brings money in, nobody types it: the salesperson's reservation (العربون) and contract (باقي المقدم /
-- الكاش) each wait as a pending payment; the accountant (into خزنة المحاسب) or المالك / المدير العام (into خزنة المكتب)
-- presses «تم استلام المبلغ» and the receipt is made with the amount written on the reservation / contract.
CREATE TABLE ex_payments (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_no         bigint NOT NULL UNIQUE DEFAULT nextval('cash_ref_seq'),
  unit_id        uuid NOT NULL REFERENCES ex_units(id),
  kind           text NOT NULL CHECK (kind IN ('reservation','down_payment')),
  amount_egp     numeric(16,2) NOT NULL CHECK (amount_egp > 0),
  payment_method text NOT NULL DEFAULT 'cash',
  status         text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','received','cancelled')),
  requested_by   uuid NOT NULL REFERENCES employees(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  received_by    uuid REFERENCES employees(id),
  received_at    timestamptz,
  receipt_id     uuid REFERENCES cash_receipts(id),
  CHECK (status <> 'received' OR (received_by IS NOT NULL AND receipt_id IS NOT NULL))
);
CREATE INDEX ex_payments_pending ON ex_payments (created_at) WHERE status = 'pending';
CREATE INDEX ex_payments_unit ON ex_payments (unit_id);
