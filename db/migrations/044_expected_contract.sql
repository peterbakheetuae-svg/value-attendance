-- «التاريخ المتوقع للتعاقد» on the reservation: the expected commissions (عمولات متوقعة) fall in that month.
ALTER TABLE ex_units ADD COLUMN expected_contract_date date;
CREATE INDEX ex_units_expected ON ex_units (expected_contract_date) WHERE status IN ('reserving','reserved','contract_pending');
