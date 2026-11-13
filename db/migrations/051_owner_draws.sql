-- مسحوبات الملاك: an owner takes money out of his own account (what he injected + his share of the profit),
-- approved by another owner. Recorded as an office cashbox expense that is NOT a cost of the office.
ALTER TABLE cash_expenses ADD COLUMN owner_draw_id uuid REFERENCES employees(id);
CREATE INDEX cash_expenses_owner_draw ON cash_expenses (owner_draw_id) WHERE owner_draw_id IS NOT NULL;
