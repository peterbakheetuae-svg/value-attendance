-- صرف from the HR cashbox counts when the person confirms "تم الاستلام" (not when HR presses صرف), and
-- financial requests are approved by the general manager / owner only — HR then pays them (صرف).
--  * the HR cashbox book: a salary / advance / commission / work-expense payout leaves the box on receipt
--  * requests the general manager already approved that were still waiting for the old HR stage become approved
--    (decided by that general manager), so HR can pay them. Nothing is deleted.

CREATE OR REPLACE VIEW cash_ledger AS
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
  SELECT 'hr', p.amount_egp, p.received_at, 'fund_in', NULL, p.id, 'payouts', p.note, p.employee_id
    FROM payouts p WHERE p.kind = 'fund' AND p.status = 'received'
  UNION ALL
  SELECT 'office', -p.amount_egp, p.received_at, 'fund_out', NULL, p.id, 'payouts', p.note, p.created_by
    FROM payouts p WHERE p.kind = 'fund' AND p.status = 'received'
  UNION ALL
  -- salary / advance / commission / work-expense payments: out of the HR cashbox once the person confirmed receipt
  SELECT 'hr', -p.amount_egp, p.received_at, 'payout_' || p.kind, NULL, p.id, 'payouts', p.note, p.created_by
    FROM payouts p WHERE p.kind <> 'fund' AND p.status = 'received';

UPDATE advance_requests
   SET status = 'confirmed', decided_by = gm_approved_by, decided_at = gm_approved_at
 WHERE status = 'pending' AND gm_approved_at IS NOT NULL AND gm_approved_by IS NOT NULL AND gm_approved_by <> employee_id;
