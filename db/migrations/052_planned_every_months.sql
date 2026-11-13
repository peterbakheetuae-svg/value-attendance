-- استمارة الحجز: the installments are planned «كل كام شهر» (1, 2, 3, 6 … months) next to their count
ALTER TABLE ex_units ADD COLUMN planned_every_months int CHECK (planned_every_months BETWEEN 1 AND 60);
