-- Firebase Cloud Messaging device tokens: one row per signed-in device, tied to its session so a
-- signed-out or expired device never receives pushes. Only the token is stored (no message content).
CREATE TABLE push_tokens (
  token        text PRIMARY KEY CHECK (length(token) BETWEEN 20 AND 4096),
  employee_id  uuid NOT NULL REFERENCES employees(id),
  session_id   uuid REFERENCES sessions(id) ON DELETE CASCADE,
  platform     text NOT NULL DEFAULT 'android' CHECK (platform IN ('android','ios','web')),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX push_tokens_employee ON push_tokens (employee_id);
