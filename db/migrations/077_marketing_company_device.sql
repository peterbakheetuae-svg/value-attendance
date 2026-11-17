-- شركة التسويق's sign-in like an employee's: «ربط الحساب بالجهاز» (the first device it signs in from is its device; any other
-- is refused until the administration frees it) and «حالة تسجيل الدخول» (on / off, independent of the contract status)
ALTER TABLE marketing_companies
  ADD COLUMN device_lock  boolean NOT NULL DEFAULT true,
  ADD COLUMN device_id    text CHECK (device_id IS NULL OR device_id ~ '^[A-Za-z0-9_-]{16,100}$'),
  ADD COLUMN device_label text,
  ADD COLUMN login_active boolean NOT NULL DEFAULT true;
