-- مستندات الوحدة: in a marketing (تسويق) project the reservation and the contract are the developer's papers —
-- the salesman uploads «استمارة الحجز» and «عقد التعاقد» (a photo or a PDF) with the reservation / the contract.
CREATE TABLE ex_unit_files (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id     uuid NOT NULL REFERENCES ex_units(id) ON DELETE CASCADE,
  kind        text NOT NULL CHECK (kind IN ('reservation_form', 'contract')),
  file_name   text NOT NULL CHECK (length(file_name) BETWEEN 1 AND 160),
  mime        text NOT NULL CHECK (mime IN ('image/jpeg', 'image/png', 'image/webp', 'application/pdf')),
  size_bytes  int  NOT NULL CHECK (size_bytes BETWEEN 1 AND 3000000),
  data        bytea NOT NULL,
  by_id       uuid REFERENCES employees(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ex_unit_files_unit ON ex_unit_files (unit_id, kind, created_at);
