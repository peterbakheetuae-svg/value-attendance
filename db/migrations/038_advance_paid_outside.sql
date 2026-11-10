-- An advance that was already handed over before this system (or outside it): it shows in the employee's advances
-- and is deducted from his salary, but it never touches a cashbox and cannot be paid (صرف) again.
ALTER TABLE advance_requests ADD COLUMN paid_outside boolean NOT NULL DEFAULT false;
