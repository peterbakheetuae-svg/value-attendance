-- VALUNIVO — READ-ONLY detection of money that may have been paid / collected twice (audit F1 / F4), 2026-11-22.
-- It changes NOTHING: the whole file runs inside a READ ONLY transaction and ends with ROLLBACK.
-- NOT run anywhere yet — prepared for the owner's review; run on Neon only after his explicit approval.
--
-- HOW TO RUN (Neon SQL editor or psql): paste the whole file and run it; each block prints one result set.
-- Every row is a CANDIDATE to look at with the accountant, never an automatic correction: no row is changed, and any
-- correction (a reversal / a reconciliation note) needs its own approval.

BEGIN TRANSACTION READ ONLY;

-- 1) F1 — a payroll sheet line paid the WHOLE net (salary + commissions + work expenses, the rule before 2026-11-22),
--    and the same month's commission / work expense was ALSO paid on its own (صرف العمولة / صرف الطلب).
--    possible_double = the smaller of (what the sheet paid above the salary part) and (what was paid directly).
WITH line AS (
  SELECT l.id AS line_id, l.employee_id, b.period, b.ref_no AS batch_no,
         (l.snapshot->>'net')::numeric AS net,
         COALESCE((l.snapshot->>'commissions')::numeric, 0) AS commissions,
         COALESCE((l.snapshot->>'workExpenses')::numeric, 0) AS work_expenses,
         l.snapshot->>'settles' AS settles
    FROM payroll_batch_lines l JOIN payroll_batches b ON b.id = l.batch_id
   WHERE b.status = 'approved'),
paid AS (
  SELECT line.*,
         COALESCE((SELECT sum(p.amount_egp) FROM payouts p WHERE p.batch_line_id = line.line_id AND p.status <> 'cancelled'), 0) AS sheet_paid,
         COALESCE((SELECT sum(p.amount_egp) FROM payouts p WHERE p.employee_id = line.employee_id AND p.period = line.period
                    AND p.kind = 'commission' AND p.status <> 'cancelled'), 0) AS commission_paid_direct,
         COALESCE((SELECT sum(p.amount_egp) FROM payouts p WHERE p.employee_id = line.employee_id AND p.period = line.period
                    AND p.kind = 'work_expense' AND p.status <> 'cancelled'), 0) AS work_expense_paid_direct
    FROM line)
SELECT 'F1 payroll sheet + direct payment' AS check_name, e.code, e.full_name, to_char(paid.period, 'YYYY-MM') AS month, paid.batch_no,
       paid.net, paid.commissions, paid.work_expenses, paid.sheet_paid,
       round(GREATEST(paid.sheet_paid - GREATEST(paid.net - paid.commissions - paid.work_expenses, 0), 0), 2) AS sheet_paid_above_salary_part,
       paid.commission_paid_direct, paid.work_expense_paid_direct,
       round(LEAST(GREATEST(paid.sheet_paid - GREATEST(paid.net - paid.commissions - paid.work_expenses, 0), 0),
                   paid.commission_paid_direct + paid.work_expense_paid_direct), 2) AS possible_double
  FROM paid JOIN employees e ON e.id = paid.employee_id
 WHERE COALESCE(paid.settles, '') <> 'salary_only'
   AND paid.sheet_paid > GREATEST(paid.net - paid.commissions - paid.work_expenses, 0) + 0.009
   AND paid.commission_paid_direct + paid.work_expense_paid_direct > 0.009
 ORDER BY possible_double DESC;

-- 2) F1 — a month's salary payouts (any path) above the whole net of that month: paid more than the payroll says.
--    (Needs the payroll calculation for an exact figure; this uses the latest payroll-sheet snapshot of the month.)
SELECT 'F1 salary above the month''s net' AS check_name, e.code, e.full_name, to_char(b.period, 'YYYY-MM') AS month,
       (l.snapshot->>'net')::numeric AS sheet_net,
       (SELECT sum(p.amount_egp) FROM payouts p WHERE p.employee_id = l.employee_id AND p.period = b.period AND p.kind = 'salary' AND p.status <> 'cancelled') AS salary_paid
  FROM payroll_batch_lines l JOIN payroll_batches b ON b.id = l.batch_id JOIN employees e ON e.id = l.employee_id
 WHERE b.status = 'approved'
   AND (SELECT sum(p.amount_egp) FROM payouts p WHERE p.employee_id = l.employee_id AND p.period = b.period AND p.kind = 'salary' AND p.status <> 'cancelled')
       > (l.snapshot->>'net')::numeric + 0.009
 ORDER BY 6 DESC;

-- 3) more than one live payout for the same approved advance / work-expense request (085 refuses to install while any exist)
SELECT 'one request paid twice' AS check_name, ar.kind, e.code, e.full_name, ar.amount_egp AS approved, count(*) AS live_payouts,
       sum(p.amount_egp) AS paid_total, string_agg(p.id::text, ', ') AS payout_ids
  FROM payouts p JOIN advance_requests ar ON ar.id = p.advance_id JOIN employees e ON e.id = p.employee_id
 WHERE p.status <> 'cancelled'
 GROUP BY ar.id, ar.kind, e.code, e.full_name, ar.amount_egp HAVING count(*) > 1;

-- 4) F4 — an exclusive unit collected more than its deposit / down payment (request confirmed + direct receipt)
SELECT 'F4 unit over-collected' AS check_name, p.name AS project, u.unit_no, u.client_name, u.status,
       u.deposit_amount,
       COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_unit_id = u.id AND r.status = 'posted' AND r.kind = 'reservation'), 0) AS deposit_collected,
       u.down_payment,
       COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_unit_id = u.id AND r.status = 'posted' AND r.kind IN ('reservation','down_payment')), 0) AS down_collected
  FROM ex_units u JOIN commission_projects p ON p.id = u.project_id
 WHERE COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_unit_id = u.id AND r.status = 'posted' AND r.kind = 'reservation'), 0)
         > COALESCE(u.deposit_amount, 0) + 0.009
    OR (u.down_payment IS NOT NULL AND u.down_payment > 0 AND
        COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_unit_id = u.id AND r.status = 'posted' AND r.kind IN ('reservation','down_payment')), 0)
         > u.down_payment + 0.009)
 ORDER BY p.name, u.unit_no;

-- 5) F4 — money recorded on a marketing (broker) project's unit (its client pays the developer, not our cashbox)
SELECT 'F4 receipt on a marketing unit' AS check_name, p.name AS project, u.unit_no, r.ref_no, r.kind, r.amount_egp, r.cashbox, r.occurred_at
  FROM cash_receipts r JOIN ex_units u ON u.id = r.ex_unit_id JOIN commission_projects p ON p.id = u.project_id
 WHERE p.kind <> 'exclusive' AND r.status = 'posted'
 ORDER BY r.occurred_at;

-- 6) F2 — salary / commission payouts made with no link (free amount, before the 2026-11-22 rule) — for review only
SELECT 'F2 unlinked payout' AS check_name, p.kind, e.code, e.full_name, to_char(p.period, 'YYYY-MM') AS month, p.amount_egp, p.status, p.created_at
  FROM payouts p JOIN employees e ON e.id = p.employee_id
 WHERE p.status <> 'cancelled' AND ((p.kind = 'salary' AND p.batch_line_id IS NULL AND p.note NOT LIKE 'مرتب %')
    OR (p.kind = 'commission' AND p.commission_entitlement_id IS NULL))
 ORDER BY p.created_at;

ROLLBACK;
