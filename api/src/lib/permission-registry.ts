/**
 * The permission registry: every permission key the application knows, with its Arabic name, module and whether it is
 * sensitive (changing it asks for confirmation). This is the ONE list:
 *  - a key that is not here is denied, even if a database row grants it (no wildcard, nothing silently granted);
 *  - the «الصلاحيات» page is built from it;
 *  - a CI test checks that it matches the `permissions` table exactly.
 *
 * Keys added by migration 066 (fine-grained) are listed with `since: 66`. Until that migration runs on a database the key
 * does not exist there, and code asks for it through `can(a, fine, broad)` (context.ts), which falls back to the broad key
 * it was split from — so nobody gains or loses access before / after the migration.
 */
export interface PermDef {
  key: string;
  module: string;
  nameAr: string;
  descAr: string;
  sensitive?: boolean;
  /** the broad key(s) this one was split from (holding any of them gave it before; kept for compatibility) */
  splitFrom?: string | string[];
  /** before this key existed the action had no separate check (everyone who could reach it could do it) */
  openBefore?: boolean;
  since?: number;
}

export const MODULES: { key: string; nameAr: string }[] = [
  { key: 'employees', nameAr: 'الموظفين' },
  { key: 'attendance', nameAr: 'الحضور والانصراف' },
  { key: 'requests', nameAr: 'الطلبات والإذونات' },
  { key: 'performance', nameAr: 'التقييم ومؤشرات الأداء' },
  { key: 'custody', nameAr: 'العهد' },
  { key: 'finance', nameAr: 'المالية والرواتب' },
  { key: 'cash', nameAr: 'الخزن' },
  { key: 'commissions', nameAr: 'العمولات' },
  { key: 'sales', nameAr: 'المبيعات والمشاريع الحصرية' },
  { key: 'leads', nameAr: 'السيلز (الليدز والصفقات)' },
  { key: 'forms', nameAr: 'الاستمارات' },
  { key: 'notifications', nameAr: 'الإشعارات' },
  { key: 'settings', nameAr: 'الإعدادات والصلاحيات' },
];

const P = (module: string, key: string, nameAr: string, descAr: string, extra: Partial<PermDef> = {}): PermDef =>
  ({ key, module, nameAr, descAr, ...extra });

export const PERMISSIONS: PermDef[] = [
  // ---- employees
  P('employees', 'employee.read_all', 'عرض كل الموظفين', 'فتح ملف أي موظف في الشركة'),
  P('employees', 'employee.read_team', 'عرض موظفي فريقه', 'فتح ملفات موظفي الفرق اللي بيديرها بس'),
  P('employees', 'employee.manage', 'إدارة الموظفين (شامل)', 'إضافة وتعديل وإيقاف الموظفين — الصلاحية القديمة الشاملة، باقية للتوافق', { sensitive: true }),
  P('employees', 'employee.create', 'إضافة موظف', 'إنشاء حساب موظف جديد', { sensitive: true, splitFrom: 'employee.manage', since: 66 }),
  P('employees', 'employee.edit', 'تعديل بيانات موظف', 'تعديل بيانات الملف والمسمى والفريق والإعدادات', { sensitive: true, splitFrom: 'employee.manage', since: 66 }),
  P('employees', 'employee.deactivate', 'إيقاف / تفعيل موظف', 'إيقاف حساب موظف أو إعادة تفعيله', { sensitive: true, splitFrom: 'employee.manage', since: 66 }),
  P('employees', 'employee.reset_password', 'إعادة تعيين كلمة السر', 'إصدار كلمة سر مؤقتة لموظف', { sensitive: true, splitFrom: 'employee.manage', since: 66 }),
  P('employees', 'employee.view_contact', 'عرض بيانات التواصل', 'رقم الموبايل والإيميل وجهة الطوارئ والرقم القومي والعنوان', { sensitive: true, splitFrom: 'employee.read_all', since: 66 }),
  P('employees', 'employee.salary_read', 'عرض المرتبات', 'رؤية المرتب الأساسي والبيانات المالية للموظف', { sensitive: true }),
  P('employees', 'employee.salary_manage', 'تعديل المرتبات', 'تغيير المرتب والبيانات المالية', { sensitive: true }),
  P('employees', 'employee.attendance_exempt', 'تحديد «حضور وانصراف»', 'تحديد إن الموظف لديه أو ليس لديه حضور وانصراف', { sensitive: true }),
  P('employees', 'documents.read', 'عرض مستندات الموظفين', 'فتح المستندات الخاصة (بطاقة، عقد…)', { sensitive: true }),
  P('employees', 'documents.manage', 'رفع مستندات الموظفين', 'رفع أو استبدال مستندات الموظف'),
  P('employees', 'devices.approve', 'الموافقة على الأجهزة', 'الموافقة على جهاز إضافي لحساب موظف', { sensitive: true }),
  P('employees', 'positions.manage', 'إدارة المسميات الوظيفية', 'إنشاء وتعديل وإيقاف المسميات'),
  P('employees', 'org.manage', 'إدارة الأقسام والفرق', 'إنشاء وتعديل الأقسام وفرق المبيعات'),
  // ---- attendance
  P('attendance', 'attendance.read_all', 'عرض حضور الكل', 'سجل حضور كل الموظفين وخريطة التتبع'),
  P('attendance', 'attendance.read_team', 'عرض حضور فريقه', 'سجل حضور موظفي فرقه بس'),
  P('attendance', 'attendance.view_location', 'عرض مواقع الموظفين', 'خريطة التتبع ونقاط الموقع ومكان البصمة لغيره (في نطاقه)', { sensitive: true, splitFrom: ['attendance.read_all', 'attendance.read_team'], since: 66 }),
  P('attendance', 'report.export', 'تصدير تقارير الحضور', 'تنزيل تقرير الحضور الشهري وملخص الرواتب إكسيل (في نطاقه)', { openBefore: true, since: 66 }),
  P('attendance', 'attendance.correct', 'تعديل سجلات الحضور', 'تصحيح البصمة (بيتسجل في سجل التدقيق)', { sensitive: true }),
  P('attendance', 'attendance.config', 'إعدادات الدوام', 'المواعيد والإجازات الرسمية ومواقع العمل'),
  P('attendance', 'report.read_all', 'التقارير الشهرية للكل', 'تقرير الحضور الشهري لكل الشركة'),
  P('attendance', 'report.read_team', 'التقارير الشهرية لفريقه', 'تقرير الحضور الشهري لفرقه'),
  P('attendance', 'report.payroll', 'ملخصات الحضور للرواتب', 'ملخص الحضور المستخدم في الرواتب', { sensitive: true }),
  // ---- requests
  P('requests', 'request.read_all', 'عرض كل الطلبات', 'طلبات الإجازات والسلف والإذونات لكل الموظفين'),
  P('requests', 'request.read_team', 'عرض طلبات فريقه', 'طلبات موظفي فرقه'),
  P('requests', 'request.approve_manager', 'موافقة المدير المباشر', 'الموافقة أو الرفض في مرحلة مدير المبيعات (فرقه)'),
  P('requests', 'request.create_for_others', 'تسجيل طلب لموظف', 'تسجيل إجازة أو إذن باسم موظف تاني (بيتعتمد على طول)', { sensitive: true, splitFrom: 'request.approve_hr', since: 66 }),
  P('requests', 'request.approve_hr', 'موافقة الموارد البشرية', 'الموافقة أو الرفض في مرحلة الموارد البشرية', { sensitive: true }),
  P('requests', 'leave.manage_balances', 'أرصدة الإجازات', 'تعديل أرصدة الإجازات', { sensitive: true }),
  // ---- performance
  P('performance', 'kpi.config', 'إعداد مؤشرات الأداء', 'تعريف المؤشرات ومجموعاتها'),
  P('performance', 'kpi.enter_all', 'إدخال المؤشرات للكل', 'إدخال النتائج لأي موظف'),
  P('performance', 'kpi.enter_team', 'إدخال المؤشرات لفريقه', 'إدخال النتائج لموظفي فرقه'),
  P('performance', 'kpi.read_all', 'عرض مؤشرات الكل', 'نتائج المؤشرات لكل الموظفين'),
  P('performance', 'kpi.read_team', 'عرض مؤشرات فريقه', 'نتائج المؤشرات لفرقه'),
  P('performance', 'evaluation.read_all', 'عرض كل التقييمات', 'تقييمات كل الموظفين'),
  P('performance', 'evaluation.read_team', 'عرض تقييمات فريقه', 'تقييمات موظفي فرقه'),
  P('performance', 'evaluation.write_all', 'تقييم أي موظف', 'كتابة تقييم لأي موظف'),
  P('performance', 'evaluation.write_team', 'تقييم موظفي فريقه', 'كتابة تقييم لموظفي فرقه'),
  // ---- custody
  P('custody', 'custody.read_all', 'عرض عهد الكل', 'العهد مع كل الموظفين'),
  P('custody', 'custody.read_team', 'عرض عهد فريقه', 'العهد مع موظفي فرقه'),
  P('custody', 'custody.manage', 'تسليم واستلام العهد', 'تسليم أصول الشركة للموظفين واستلامها'),
  // ---- finance
  P('finance', 'finance.read', 'عرض التسويات المالية', 'المكافآت والخصومات والسلف', { sensitive: true }),
  P('finance', 'finance.manage', 'إنشاء تسويات مالية', 'إضافة مكافأة أو خصم', { sensitive: true }),
  P('finance', 'finance.approve', 'اعتماد التسويات المالية', 'اعتماد التسويات (مش اللي عملها بنفسه)', { sensitive: true }),
  P('finance', 'finance.disburse', 'الصرف للموظفين', 'صرف مرتبات وسلف وعمولات ومصروفات من الخزنة', { sensitive: true }),
  P('finance', 'finance.fund', 'تمويل الموارد البشرية', 'تسليم نقدية للموارد البشرية للصرف', { sensitive: true }),
  P('finance', 'payroll.prepare', 'تجهيز كشف الرواتب', 'تجهيز الكشف الشهري وخصم السلف وصرف المعتمد', { sensitive: true }),
  P('finance', 'payroll.approve', 'اعتماد كشف الرواتب', 'اعتماد الكشف الشهري (مش اللي جهّزه)', { sensitive: true }),
  // ---- cash
  P('cash', 'cash.hr_view', 'عرض خزنة الموارد البشرية', 'الرصيد والحركات والمصروفات', { sensitive: true }),
  P('cash', 'cash.hr_operate', 'تشغيل خزنة الموارد البشرية', 'تحصيل ومصروفات وطلبات تحويل', { sensitive: true }),
  P('cash', 'cash.office', 'خزنة المكتب', 'عرضها وتسجيل حركاتها واعتماد التحويلات', { sensitive: true }),
  P('cash', 'cash.approve', 'اعتماد مصروفات وتحويلات', 'موافقة / رفض المصروفات الكبيرة وطلبات التحويل، وتأكيد المراجعة (مش اللي عمله بنفسه)', { sensitive: true, splitFrom: 'cash.office', since: 66 }),
  P('cash', 'cash.reverse', 'عكس الحركات', 'عكس تحصيل أو مصروف مُسجّل (بسبب، ومتسجل)', { sensitive: true, splitFrom: 'cash.office', since: 66 }),
  P('cash', 'cash.bank_view', 'عرض حركات البنك', 'الإيداعات والسحوبات بين الخزنة والبنك', { sensitive: true, splitFrom: 'cash.office', since: 66 }),
  P('cash', 'cash.bank_transfer', 'تحويل بين الخزنة والبنك', 'تسجيل إيداع في البنك أو سحب منه', { sensitive: true, splitFrom: 'cash.office', since: 66 }),
  P('cash', 'cash.owner_funds', 'ضخ وسحب أموال الملاك', 'ضخ أموال، سحب أرباح، ونسب الملاك', { sensitive: true, splitFrom: 'cash.office', since: 66 }),
  P('finance', 'finance.dashboard_view', 'لوحة المالية', 'لوحة المالية وتفاصيلها (في حدود الخزن اللي يشوفها)', { sensitive: true, splitFrom: ['cash.hr_view', 'cash.office'], since: 66 }),
  P('cash', 'cash.settings', 'إعدادات الخزن', 'حد اعتماد المصروفات والأرصدة الافتتاحية', { sensitive: true }),
  // ---- commissions
  P('commissions', 'commission.read_all', 'عرض كل العمولات', 'كل العمولات المعتمدة واستحقاقات الموظفين', { sensitive: true }),
  P('commissions', 'commission.read_team', 'عرض عمولات فريقه', 'المشاريع والوحدات المباعة لفريقه (من غير أرقام الشركة)'),
  P('commissions', 'commission.approve', 'اعتماد طلبات العمولة', 'اعتماد أو رفض طلبات العمولة وتحديد شهر الصرف', { sensitive: true }),
  P('commissions', 'commission.project_manage', 'إدارة مشاريع العمولات', 'إنشاء وتعديل المشاريع وتقسيم العمولة'),
  P('commissions', 'commission.company_view', 'عرض أرباح الشركة', 'نصيب الشركة والإيراد والربح', { sensitive: true }),
  // ---- sales
  P('sales', 'sales.view', 'عرض مبيعات الوحدات', 'المبيعات وصفحة الأقساط المستحقة'),
  P('sales', 'sales.manage', 'تسجيل المبيعات والتحصيل', 'تسجيل بيع وحدة وتحصيل المقدمات والأقساط', { sensitive: true }),
  P('sales', 'sales.approve', 'اعتماد المبيعات', 'اعتماد أو رفض المبيعات (مش بتاعته)', { sensitive: true }),
  P('sales', 'sales.cancel', 'إلغاء بيع', 'إلغاء بيع وحدة مع رد المحصّل', { sensitive: true }),
  P('sales', 'exclusive.reserve', 'حجز وحدة', 'حجز وحدات في المشاريع الحصرية'),
  // ---- leads
  P('leads', 'leads.own', 'العمل على ليدز متسندة له', 'شغل الليدز المتسندة ليه'),
  P('leads', 'leads.team', 'ليدز فريقه', 'رؤية ليدز فريقه وإعادة إسنادها'),
  P('leads', 'leads.read_all', 'كل الليدز والتقارير', 'رؤية كل الليدز وتقاريرها'),
  P('leads', 'leads.distribute', 'توزيع الليدز', 'إضافة واستيراد الليدز وإسنادها لأي سيلز'),
  P('leads', 'leads.create', 'إضافة ليد', 'إضافة ليدز'),
  P('leads', 'leads.edit', 'تعديل ليد', 'تعديل بيانات الليد'),
  P('leads', 'leads.import', 'استيراد ليدز', 'استيراد من إكسيل'),
  P('leads', 'leads.export', 'تصدير ليدز', 'تصدير إلى إكسيل', { sensitive: true }),
  P('leads', 'leads.reports', 'تقارير الليدز', 'فتح تقارير الليدز'),
  P('leads', 'leads.tasks', 'إسناد مهام', 'إعطاء مهام للآخرين'),
  P('leads', 'leads.config', 'إعدادات الليدز', 'القنوات والحملات وأسباب الإلغاء'),
  P('leads', 'leads.stages', 'مراحل الليد', 'إدارة مراحل الليد'),
  P('leads', 'leads.waiting_alert', 'تنبيه الليد المنتظر', 'يوصله تنبيه لما ليد جديد ميلاقيش سيلز متصل'),
  P('leads', 'deals.view', 'لوحة الصفقات', 'فتح لوحة الصفقات'),
  P('leads', 'deals.create', 'إضافة صفقة', 'تحويل ليد لصفقة'),
  P('leads', 'deals.edit', 'تعديل صفقة', 'تعديل الصفقات ونقلها'),
  P('leads', 'deals.delete', 'حذف صفقة', 'حذف الصفقات', { sensitive: true }),
  // ---- forms
  P('forms', 'forms.delete', 'حذف الاستمارات', 'حذف استمارات سابقة', { sensitive: true }),
  // ---- notifications
  P('notifications', 'notification.send', 'إرسال إشعارات', 'إرسال إشعارات للموظفين'),
  // ---- settings
  P('settings', 'settings.manage', 'إعدادات الشركة', 'تعديل إعدادات الشركة (منها التتبع)', { sensitive: true }),
  P('settings', 'roles.manage', 'إدارة الصلاحيات', 'صفحة الصلاحيات: المسميات والاستثناءات الفردية وسجلها', { sensitive: true }),
  P('settings', 'audit.read', 'سجل التدقيق', 'قراءة سجل التدقيق', { sensitive: true }),
  P('settings', 'data.reset', 'استيراد / مسح البيانات', 'استيراد بيانات قديمة أو مسح بيانات الشركة (كانت للمالك بالاسم)', { sensitive: true, since: 66 }),
  P('commissions', 'commission.void_approved', 'إلغاء عمولة معتمدة', 'إلغاء عمولة بعد اعتمادها (كانت للمالك بالاسم)', { sensitive: true, since: 66 }),
];

export const PERM_BY_KEY: ReadonlyMap<string, PermDef> = new Map(PERMISSIONS.map((p) => [p.key, p]));
export const isRegistered = (key: string) => PERM_BY_KEY.has(key);

/**
 * The owner recovery path, documented on purpose: the built-in `owner` role (المالك) always holds every registered
 * permission (every migration grants it), its profile cannot be edited, an owner account cannot be given an individual
 * restriction, and at least one active owner must remain (employees.ts: assertOwnerRemains). Nothing else bypasses
 * permissions: no other role name is ever checked to grant access.
 */
export const OWNER_ROLE = 'owner';
