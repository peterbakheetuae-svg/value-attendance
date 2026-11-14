-- the built-in stages take Engaz's names (unless the leads settings already renamed them)
UPDATE lead_stages SET name_ar = 'لا رد على المكالمة الأولى' WHERE key = 'no_answer' AND name_ar = 'أول مكالمة — مردّش';
UPDATE lead_stages SET name_ar = 'اجتماع' WHERE key = 'meeting' AND name_ar = 'ميتنج';
UPDATE lead_stages SET name_ar = 'متابعة بعد الاجتماع' WHERE key = 'after_meeting' AND name_ar = 'متابعة بعد الميتنج';
UPDATE lead_stages SET name_ar = 'إعادة جدولة الاجتماع' WHERE key = 'reschedule' AND name_ar = 'تأجيل ميتنج';
UPDATE lead_stages SET name_ar = 'صفقة مكتملة' WHERE key = 'done_deal' AND name_ar = 'تم البيع';
