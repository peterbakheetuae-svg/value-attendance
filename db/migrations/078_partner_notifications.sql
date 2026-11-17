-- شركة التسويق's bell (its dashboard): what happened on its campaigns' leads since it last opened the notifications
ALTER TABLE marketing_companies ADD COLUMN notifications_seen_at timestamptz;
