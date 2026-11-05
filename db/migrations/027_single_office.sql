-- One office location only: the one set from "معلومات الشركة" (the old "موقع العمل" page is gone).
-- Every check (check-in, return from a permission / visit, leaving the office, tracking) uses it.
-- The kept row is the company-info office ("المكتب الرئيسي"); any other saved location is removed.
-- Nothing references work_locations, so removing a row touches no attendance history.
DELETE FROM work_locations
 WHERE id <> COALESCE(
   (SELECT id FROM work_locations WHERE id = 'd1c0a613-832b-4584-9552-a67628885e56'),
   (SELECT id FROM work_locations ORDER BY active DESC, (name = 'المكتب الرئيسي') DESC, id LIMIT 1));
UPDATE work_locations SET active = true;
CREATE UNIQUE INDEX work_locations_single ON work_locations ((true));

-- the attendance circle can be as small as 5 m
ALTER TABLE work_locations DROP CONSTRAINT IF EXISTS work_locations_radius_m_check;
ALTER TABLE work_locations ADD CONSTRAINT work_locations_radius_m_check CHECK (radius_m BETWEEN 5 AND 5000);
