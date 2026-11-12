-- «استمارة حجز وحدة»: what the printed reservation form says beyond the price and the deposit.
ALTER TABLE ex_units
  ADD COLUMN unit_type            text NOT NULL DEFAULT '',      -- تجاري / إداري / سكني …
  ADD COLUMN floor                text NOT NULL DEFAULT '',      -- أرضي / أول علوي …
  ADD COLUMN area_m2              numeric(12,4) CHECK (area_m2 IS NULL OR area_m2 > 0),
  ADD COLUMN activity             text NOT NULL DEFAULT '',      -- النشاط
  ADD COLUMN maintenance_deposit  numeric(16,2) NOT NULL DEFAULT 0 CHECK (maintenance_deposit >= 0),
  ADD COLUMN client_national_id   text NOT NULL DEFAULT '',
  ADD COLUMN client_address       text NOT NULL DEFAULT '',
  ADD COLUMN planned_down_payment numeric(16,2) CHECK (planned_down_payment IS NULL OR planned_down_payment >= 0),
  ADD COLUMN down_payment_due     date,                          -- آخر موعد لاستكمال المقدم
  ADD COLUMN planned_installments int CHECK (planned_installments IS NULL OR planned_installments BETWEEN 0 AND 240),
  ADD COLUMN deposit_paid_on      date;                          -- تاريخ سداد دفعة الحجز
