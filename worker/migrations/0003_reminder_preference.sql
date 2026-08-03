-- Per-license trial-reminder preference: the buyer picks when the pre-charge
-- email lands, in days before trial_end. 1 = the day before (the previous
-- fixed behavior, so existing rows keep their terms); 2 = two days before.
ALTER TABLE licenses ADD COLUMN remind_days_before INTEGER NOT NULL DEFAULT 1;
