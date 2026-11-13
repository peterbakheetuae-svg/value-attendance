-- صورة الإيصال الموقّع of a transfer between the cashboxes or of a payout (سلفة / قبض / عمولة / مصاريف عمل).
-- Kept apart: a finished transfer / payout is never edited, its signed receipt photo can still be added or changed.
CREATE TABLE cash_attachments (
  entity      text NOT NULL CHECK (entity IN ('transfer', 'payout')),
  entity_id   uuid NOT NULL,
  attachment  bytea NOT NULL,
  updated_by  uuid NOT NULL REFERENCES employees(id),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (entity, entity_id)
);
