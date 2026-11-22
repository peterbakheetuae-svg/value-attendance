-- R4 synthetic KPI data (scratch copy only): every set scope, retired set, partly/fully/below-target evaluated months
INSERT INTO kpi_definitions (id, key, name_ar, name_en, measurement_type, higher_is_better) VALUES
 ('00000000-0000-0000-0000-00000000d001','zz_deals','صفقات','Deals','count',true),
 ('00000000-0000-0000-0000-00000000d002','zz_calls','مكالمات','Calls','count',true),
 ('00000000-0000-0000-0000-00000000d003','zz_late','تأخير','Late','count',false),
 ('00000000-0000-0000-0000-00000000d004','zz_revenue','إيراد','Revenue','amount_egp',true);
WITH own AS (SELECT id FROM employees WHERE role_key='owner' LIMIT 1)
INSERT INTO kpi_sets (id, name, scope_type, job_title, employee_id, position_key, version, active, created_by)
SELECT * FROM (VALUES
 ('00000000-0000-0000-0000-00000000a001'::uuid,'title set','job_title','مستشار عقاري',NULL::uuid,NULL,1,true),
 ('00000000-0000-0000-0000-00000000a002'::uuid,'position set','position',NULL,NULL,'sales_manager',1,true),
 ('00000000-0000-0000-0000-00000000a003'::uuid,'title set v0 (retired)','job_title','مستشار عقاري',NULL,NULL,0,false)) v(id,name,st,jt,emp,pk,ver,act), own
ON CONFLICT DO NOTHING;
UPDATE kpi_sets SET created_by = (SELECT id FROM employees WHERE role_key='owner' LIMIT 1);
-- employee-scoped sets for 3 sales employees (override the title set)
INSERT INTO kpi_sets (name, scope_type, employee_id, version, active, created_by)
SELECT 'emp set '||e.code, 'employee', e.id, 1, true, (SELECT id FROM employees WHERE role_key='owner' LIMIT 1)
  FROM (SELECT id, code FROM employees WHERE role_key='sales_employee' AND status='active' ORDER BY code LIMIT 3) e;
INSERT INTO kpi_set_items (set_id, kpi_id, weight, target) VALUES
 ('00000000-0000-0000-0000-00000000a001','00000000-0000-0000-0000-00000000d001',60,10),
 ('00000000-0000-0000-0000-00000000a001','00000000-0000-0000-0000-00000000d002',40,200),
 ('00000000-0000-0000-0000-00000000a002','00000000-0000-0000-0000-00000000d001',50,30),
 ('00000000-0000-0000-0000-00000000a002','00000000-0000-0000-0000-00000000d003',20,3),
 ('00000000-0000-0000-0000-00000000a002','00000000-0000-0000-0000-00000000d004',30,500000),
 ('00000000-0000-0000-0000-00000000a003','00000000-0000-0000-0000-00000000d002',100,999);
INSERT INTO kpi_set_items (set_id, kpi_id, weight, target)
SELECT s.id, d.id, w, t FROM kpi_sets s, (VALUES ('00000000-0000-0000-0000-00000000d001'::uuid,70,5),('00000000-0000-0000-0000-00000000d004'::uuid,30,100000)) x(id,w,t)
  JOIN kpi_definitions d ON d.id = x.id WHERE s.scope_type='employee';
-- a past month (2026-10): snapshot for 40 employees, with varied evaluation states
INSERT INTO kpi_results (employee_id, period, set_id, kpi_id, weight_snapshot, target_snapshot, actual, state)
SELECT e.id, '2026-10-01', i.set_id, i.kpi_id, i.weight, i.target,
       CASE WHEN rn % 4 = 0 THEN NULL WHEN rn % 4 = 1 THEN i.target WHEN rn % 4 = 2 THEN i.target * 0.5 ELSE i.target * 1.3 END,
       CASE WHEN rn % 4 = 0 THEN 'not_evaluated' WHEN rn % 4 = 3 THEN 'in_progress' ELSE 'completed' END
  FROM (SELECT id, job_title, role_key, row_number() OVER (ORDER BY code) rn FROM employees WHERE status='active' AND role_key IN ('sales_employee','sales_manager')) e
  JOIN kpi_set_items i ON i.set_id = CASE WHEN e.role_key='sales_manager' THEN '00000000-0000-0000-0000-00000000a002'::uuid ELSE '00000000-0000-0000-0000-00000000a001'::uuid END
 WHERE e.rn <= 40;
-- current month: 5 employees already snapshotted (one evaluated), the rest get snapshotted by the GET
INSERT INTO kpi_results (employee_id, period, set_id, kpi_id, weight_snapshot, target_snapshot, actual, state)
SELECT e.id, '2026-11-01', i.set_id, i.kpi_id, i.weight, i.target, CASE WHEN e.rn = 1 THEN i.target END, CASE WHEN e.rn = 1 THEN 'completed' ELSE 'not_evaluated' END
  FROM (SELECT id, row_number() OVER (ORDER BY code DESC) rn FROM employees WHERE status='active' AND role_key='sales_employee') e
  JOIN kpi_set_items i ON i.set_id = '00000000-0000-0000-0000-00000000a001' WHERE e.rn <= 5;
