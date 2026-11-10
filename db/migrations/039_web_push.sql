-- Web Push (the web app on iPhone / desktop browsers): one row per browser that allowed notifications.
CREATE TABLE web_push_subscriptions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES employees(id),
  session_id  uuid NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  endpoint    text NOT NULL UNIQUE CHECK (endpoint LIKE 'https://%' AND length(endpoint) <= 2000),
  p256dh      text NOT NULL CHECK (length(p256dh) BETWEEN 80 AND 100),
  auth        text NOT NULL CHECK (length(auth) BETWEEN 16 AND 30),
  user_agent  text NOT NULL DEFAULT '',
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX web_push_subscriptions_emp ON web_push_subscriptions (employee_id);
