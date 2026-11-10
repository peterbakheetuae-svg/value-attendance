import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../../core/api.dart';
import 'jph_bridge.dart';
import 'alert_center.dart';

/// The original JPH screens talk through `ApiService.post({'action': ...})`.
/// This router answers every action from the Value Attendance API and returns
/// the response shapes the original screens already read — screens stay unchanged.
class ApiService {
  ApiService._();

  static Future<Map<String, dynamic>> post(Map<String, dynamic> data) => JphRouter.dispatch(data);

  static Future<Map<String, dynamic>> checkUpdate({required String currentVersion, String platform = 'android', String lang = 'ar'}) =>
      post({'action': 'check_update'});

  static Future<Map<String, dynamic>> changePassword({required String uid, required String oldPass, required String newPass}) =>
      post({'action': 'changePassword', 'oldPass': oldPass, 'newPass': newPass});

  static Future<void> signOut() => JphBridge.session.logout();
  /// Permission check for screens (e.g. the owner-only "no attendance" switch).
  static bool can(String p) => JphRouter.can(p);
}

class JphRouter {
  static ApiClient get _api => JphBridge.api;

  // ------------------------------------------------------------------ labels
  static const roleAr = {
    'owner': 'المالك',
    'manager': 'المدير',
    'hr_manager': 'مدير الموارد البشرية',
    'accountant': 'محاسب',
    'sales_manager': 'مدير مبيعات',
    'sales_employee': 'سيلز',
  };
  static String roleKeyOf(String? label) {
    if (label == null || label == 'مستشار عقاري') return 'sales_employee';
    if (roleAr.containsKey(label)) return label;
    for (final e in roleAr.entries) {
      if (e.value == label) return e.key;
    }
    return 'sales_employee';
  }

  static const _monthsAr = ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];
  static int _monthIndex(Object? m) {
    final s = (m ?? '').toString().trim();
    final i = _monthsAr.indexOf(s);
    if (i >= 0) return i + 1;
    final n = int.tryParse(s);
    return (n != null && n >= 1 && n <= 12) ? n : DateTime.now().month;
  }

  static const _leaveTypeToKey = {
    'إجازة بدون راتب': 'unpaid',
    'إجازة مرضية': 'sick',
    'إجازة عادية': 'annual',
    'إجازة طارئة': 'casual',
  };
  static const _leaveKeyToType = {
    'unpaid': 'إجازة بدون راتب',
    'sick': 'إجازة مرضية',
    'annual': 'إجازة عادية',
    'casual': 'إجازة طارئة',
    'mission': 'مأمورية',
  };
  static String _leaveStatus(String s) => switch (s) {
        'approved' => 'مقبؤل',
        'rejected' => 'مرفوض',
        'cancelled' => 'ملغي',
        _ => 'قيد المراجعة',
      };
  static String _advanceStatus(String s) => switch (s) {
        'confirmed' => 'مؤكد',
        'rejected' => 'مرفوض',
        'cancelled' => 'ملغي',
        _ => 'قيد المراجعة',
      };
  static const _weekdaysAr = {1: 'الاثنين', 2: 'الثلاثاء', 3: 'الأربعاء', 4: 'الخميس', 5: 'الجمعة', 6: 'السبت', 7: 'الأحد'};

  // ------------------------------------------------------------------ small helpers
  static Map<String, dynamic> _ok([Map<String, dynamic> m = const {}]) => {'success': true, ...m};
  static Map<String, dynamic> _fail(String message) => {'success': false, 'message': message};
  static String _s(Object? v, [String dflt = '--']) {
    if (v == null) return dflt;
    final t = v.toString();
    return t.isEmpty ? dflt : t;
  }

  static DateTime? _dt(Object? iso) => iso == null ? null : DateTime.tryParse(iso.toString())?.toLocal();
  static String _two(int v) => v.toString().padLeft(2, '0');
  static String _time(Object? iso, [String dflt = '--:--']) {
    final d = _dt(iso);
    return d == null ? dflt : '${_two(d.hour)}:${_two(d.minute)}';
  }

  static String _date(Object? v) {
    if (v == null) return '';
    final s = v.toString();
    return s.length >= 10 ? s.substring(0, 10) : s;
  }

  static String _hm(num? minutes) {
    final m = (minutes ?? 0).round();
    return '${m ~/ 60}h ${m % 60}m';
  }

  static String _hhmm(num? minutes) {
    final m = (minutes ?? 0).round();
    return '${m ~/ 60}:${_two(m % 60)}';
  }

  static String _hms(num? minutes) {
    final m = (minutes ?? 0).round();
    return '${_two(m ~/ 60)}:${_two(m % 60)}:00';
  }

  static String _ymd(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
  static List<Map<String, dynamic>> _list(Object? v) => ((v as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  static bool _has(String p) => JphBridge.session.has(p);
  /// Permission check for screens (e.g. the owner-only "no attendance" switch).
  static bool can(String p) => _has(p);

  /// "uid" in the original screens is the employee code; resolve it to the API id.
  static Future<String> _id(Object? uid) async {
    final s = (uid ?? '').toString().trim();
    if (s.isEmpty || s == JphBridge.myCode || s == JphBridge.myId) return JphBridge.myId;
    if (RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-').hasMatch(s)) return s;
    final known = JphBridge.codeToId[s.toUpperCase()];
    if (known != null) return known;
    await _employees();
    return JphBridge.codeToId[s.toUpperCase()] ?? s;
  }

  static Future<Map<String, String>> _links({List<String> photos = const [], List<String> selfies = const []}) async {
    if (photos.isEmpty && selfies.isEmpty) return {};
    try {
      final r = await _api.post('/media/links', {'photos': photos, 'selfies': selfies});
      return ((r['links'] as Map?) ?? {}).map((k, v) => MapEntry(k.toString(), JphBridge.mediaUrl(v.toString())));
    } catch (_) {
      return {};
    }
  }

  // ------------------------------------------------------------------ dispatch
  static Future<Map<String, dynamic>> dispatch(Map<String, dynamic> p) async {
    final action = (p['action'] ?? '').toString();
    try {
      switch (action) {
        case 'login':
          return await _login(p);
        case 'forgot_password':
          final fg = await _api.post('/auth/forgot', {'identifier': (p['identifier'] ?? p['email'] ?? '').toString().trim()});
          final to = (fg['sentTo'] ?? '').toString();
          return _ok({'sentTo': to,
            'message': to.isNotEmpty ? 'اتبعت كود من 4 أرقام على $to — بص في البريد الوارد والـ Spam' : 'لو الحساب ليه إيميل مسجّل، هيوصلك كود من 4 أرقام'});
        case 'verify_otp':
          final v = await _api.post('/auth/forgot/verify', {'identifier': (p['identifier'] ?? '').toString().trim(), 'code': p['code']});
          return _ok({'resetToken': v['resetToken']});
        case 'reset_password':
          await _api.post('/auth/forgot/reset', {'resetToken': p['resetToken'], 'newPassword': p['newPassword']});
          return _ok({'message': 'تم تغيير كلمة المرور ✅ سجّل دخول بالجديدة'});
        case 'register':
          return _fail('إنشاء الحسابات يتم من الإدارة فقط');
        case 'changePassword':
          await JphBridge.session.changePassword((p['oldPass'] ?? '').toString(), (p['newPass'] ?? '').toString());
          return _ok({'message': 'تم تغيير كلمة المرور بنجاح'});
        case 'check_update':
          return _ok({'update_available': false, 'maintenance': false});
        case 'updateFcmToken':
          return _ok();

        case 'profile':
          return await _profile(p);
        case 'update_profile':
          return await _updateProfile(p);

        case 'dashboard_today':
        case 'get_dashboard_data':
          return await _today();
        case 'dashboard_month':
          return await _month();
        case 'checkin':
          return await _checkIn(p);
        case 'checkout':
          return await _checkOut(p);
        case 'break_start':
          return _fail('الاستراحة اتشالت — استخدم «إذن ساعات» أو «زيارة»');
        case 'break_end':
          await _api.post('/attendance/break-end', {});
          return _ok({'message': 'تم إنهاء الاستراحة'});

        // ---- hourly permission / external visit (replaces the break)
        case 'outing_today':
          return _ok((await _api.get('/outings/today')).cast<String, dynamic>());
        case 'outing_submit':
          final r = await _api.postOrQueue('/outings', {
            'kind': p['kind'], 'expectedReturn': p['expectedReturn'], 'reason': p['reason'],
            if (p['startAt'] != null) 'startAt': p['startAt'],
            if (p['parentId'] != null) 'parentId': p['parentId'],
          }, label: 'طلب إذن / زيارة');
          if (r['queued'] == true) return _ok({'message': 'الطلب اتحفظ على الموبايل 📴 وهيتبعت للموافقة أول ما النت يرجع'});
          return _ok({'outing': r['outing'], 'message': p['parentId'] != null ? 'تم إرسال طلب التمديد للموافقة' : 'تم إرسال الطلب للموافقة'});
        case 'outing_return':
          // "I'm back" is checked against the office location on the server
          final rr = await _api.postOrQueue('/outings/return', await _gps(), label: 'تسجيل الرجوع');
          return _ok({'message': rr['queued'] == true ? 'اتسجل رجوعك على الموبايل 📴 — هيتبعت أول ما النت يرجع' : 'تم تسجيل رجوعك'});
        case 'outing_cancel':
          await _api.post('/outings/${p['id']}/cancel', {});
          return _ok({'message': 'تم إلغاء الطلب'});
        case 'outing_decide':
          await _api.post('/outings/${p['id']}/decision', {
            'decision': p['approve'] == true ? 'approve' : 'reject',
            if ((p['comment'] ?? '').toString().trim().isNotEmpty) 'comment': p['comment'],
          });
          return _ok({'message': p['approve'] == true ? 'تمت الموافقة' : 'تم الرفض'});
        case 'outing_get':
          final r = await _api.get('/outings');
          final one = _list(r['outings']).where((x) => x['id'] == p['id']).toList();
          return one.isEmpty ? _fail('الطلب غير موجود') : _ok({'outing': one.first});
        case 'outings_awaiting':
          return _ok({'outings': _list((await _api.get('/outings', {'status': 'awaiting'}))['outings'])});

        // ---- company information & office geofence (Phase 3)
        case 'get_company_info':
        case 'get_company_tree':
          final r = (await _api.get('/company')).cast<String, dynamic>();
          final c = ((r['company'] as Map?) ?? {}).cast<String, dynamic>();
          return _ok({
            'data': {...c, 'name': c['nameAr'] ?? c['nameEn']},
            'offices': _list(r['offices']),
            'canEdit': r['canEdit'] == true,
          });
        case 'update_company':
          await _api.put('/company', {
            for (final k in const ['nameAr', 'nameEn', 'description', 'address', 'phone', 'email'])
              if (p[k] != null && (k == 'description' || k == 'address' || p[k].toString().trim().isNotEmpty)) k: p[k].toString().trim(),
          });
          return _ok({'message': 'تم حفظ بيانات الشركة'});
        case 'save_office':
        case 'add_work_location':
        case 'update_work_location':
          final body = {
            'name': p['name'],
            'lat': p['lat'] ?? p['latitude'],
            'lng': p['lng'] ?? p['longitude'],
            'radiusM': p['radiusM'],
            if (p['active'] != null) 'active': p['active'],
          };
          final id = (p['id'] ?? '').toString();
          if (id.isEmpty) {
            await _api.post('/work-locations', body);
          } else {
            await _api.patch('/work-locations/$id', body);
          }
          return _ok({'message': 'تم حفظ موقع المكتب'});
        case 'get_work_locations':
          final r = await _api.get('/work-locations');
          return _ok({
            'workLocations': _list(r['locations']).map((l) => {
                  ...l, 'latitude': l['lat'], 'longitude': l['lng'], 'radiusM': l['radius_m'], 'isActive': l['active'],
                }).toList(),
          });

        // ---- job positions & permissions (Phase 4)
        case 'get_positions':
          return _ok({'positions': _list((await _api.get('/positions'))['positions'])});
        case 'get_roles':
          final r = (await _api.get('/roles')).cast<String, dynamic>();
          return _ok({'roles': _list(r['roles']), 'permissions': _list(r['permissions']),
            'canEditPermissions': r['canEditPermissions'] == true, 'canManagePositions': r['canManagePositions'] == true});
        case 'add_position':
          await _api.post('/roles', {'nameAr': p['nameAr'], 'nameEn': p['nameEn'], 'baseKey': p['baseKey'], 'description': p['description'] ?? ''});
          return _ok({'message': 'تمت إضافة الوظيفة وظهرت في صفحة الصلاحيات'});
        case 'update_position':
          await _api.patch('/roles/${p['key']}', {
            for (final k in const ['nameAr', 'nameEn', 'description', 'active']) if (p[k] != null) k: p[k],
          });
          return _ok({'message': 'تم حفظ الوظيفة'});
        case 'set_position_permissions':
          await _api.put('/roles/${p['key']}/permissions', {'permissions': p['permissions']});
          return _ok({'message': 'تم حفظ الصلاحيات'});

        // ---- position-based KPIs + evaluations (Phase 4)
        case 'kpi_setup':
          final pos = _list((await _api.get('/positions'))['positions']);
          final defs = _list((await _api.get('/kpi/definitions'))['definitions']);
          List<Map<String, dynamic>> sets = const [];
          if (_has('kpi.config') || _has('kpi.read_all') || _has('kpi.read_team')) sets = _list((await _api.get('/kpi/sets'))['sets']);
          return _ok({'positions': pos, 'definitions': defs, 'sets': sets, 'canConfig': _has('kpi.config')});
        case 'kpi_add_definition':
          final r = await _api.post('/kpi/definitions', {
            'key': 'k${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}',
            'nameAr': p['nameAr'], 'nameEn': p['nameEn'] ?? '', 'measurementType': p['measurementType'] ?? 'count',
            'higherIsBetter': p['higherIsBetter'] != false,
          });
          return _ok({'definition': r['definition'], 'message': 'تمت إضافة المؤشر'});
        case 'kpi_save_set':
          final items = _list(p['items']);
          final defs = {for (final d in _list((await _api.get('/kpi/definitions'))['definitions'])) d['id']: d};
          for (final it in items) {
            if (defs[it['kpiId']]?['active'] == false) await _api.patch('/kpi/definitions/${it['kpiId']}', {'active': true});
          }
          await _api.post('/kpi/sets', {'scopeType': 'position', 'positionKey': p['positionKey'], 'name': p['name'], 'items': items});
          return _ok({'message': 'تم حفظ مؤشرات الوظيفة (نسخة جديدة — الشهور السابقة محفوظة كما هي)'});
        case 'kpi_overview':
          return _ok((await _api.get('/kpi/overview', <String, String?>{if (p['month'] != null) 'month': '${p['month']}'})).cast<String, dynamic>());
        case 'kpi_employee':
          return _ok((await _api.get('/kpi/employees/${p['id'] ?? JphBridge.myId}', <String, String?>{if (p['month'] != null) 'month': '${p['month']}'})).cast<String, dynamic>());
        case 'kpi_enter':
          await _api.put('/kpi/results/${p['id']}', {'state': p['state'], if (p['state'] != 'not_evaluated') 'actual': p['actual']});
          return _ok({'message': 'تم حفظ النتيجة'});
        case 'eval_list':
          return _ok({'evaluations': _list((await _api.get('/evaluations', <String, String?>{
            if (p['employeeId'] != null) 'employeeId': '${p['employeeId']}', if (p['month'] != null) 'month': '${p['month']}'}))['evaluations'])});
        case 'eval_save':
          final r = await _api.post('/evaluations', {
            'employeeId': p['employeeId'], 'month': p['month'], ...((p['scores'] as Map?) ?? {}).cast<String, dynamic>(),
            'feedback': p['feedback'] ?? '', 'improvementPlan': p['improvementPlan'] ?? '',
          });
          if (p['publish'] == true) await _api.post('/evaluations/${r['evaluation']['id']}/publish', {});
          return _ok({'message': p['publish'] == true ? 'تم نشر التقييم وتبليغ الموظف' : 'تم حفظ التقييم كمسودة'});
        case 'eval_publish':
          await _api.post('/evaluations/${p['id']}/publish', {});
          return _ok({'message': 'تم نشر التقييم وتبليغ الموظف'});

        // ---- employee documents + custody (Phase 5)
        case 'stage_document':
          final r = await _api.post('/documents/staged', {'kind': p['kind'], 'fileName': p['fileName'], 'mime': p['mime'], 'data': p['data']});
          return _ok({'id': r['id']});
        case 'employee_documents':
          return _ok((await _api.get('/employees/${await _id(p['id'] ?? p['uid'])}/documents')).cast<String, dynamic>());
        case 'upload_document':
          await _api.post('/employees/${await _id(p['id'] ?? p['uid'])}/documents',
              {'kind': p['kind'], 'fileName': p['fileName'], 'mime': p['mime'], 'data': p['data']});
          return _ok({'message': 'تم رفع المستند (النسخة القديمة محفوظة في السجل)'});
        case 'employee_custody':
          return _ok((await _api.get('/employees/${await _id(p['id'] ?? p['uid'])}/custody')).cast<String, dynamic>());
        case 'custody_assign':
          await _api.post('/employees/${await _id(p['id'] ?? p['uid'])}/custody', {
            for (final k in const ['assetId', 'assetName', 'assetType', 'description', 'serialNo', 'assignedOn', 'condition', 'notes'])
              if (p[k] != null && '${p[k]}'.isNotEmpty) k: p[k],
          });
          return _ok({'message': 'تم تسليم العهدة'});
        case 'custody_close':
          await _api.post('/custody/${p['itemId']}/close', {
            'outcome': p['outcome'], if (p['condition'] != null) 'condition': p['condition'], if ((p['notes'] ?? '').toString().isNotEmpty) 'notes': p['notes'],
          });
          return _ok({'message': p['outcome'] == 'lost' ? 'تم تسجيل العهدة مفقودة' : 'تم استلام العهدة'});

        case 'admin_overview':
          return _ok((await _api.get('/dashboard/overview')).cast<String, dynamic>());
        case 'save_late_rules':
          // tiers: late arrival and early leave use the same fixed-amount tiers (approved policy)
          await _api.patch('/settings', {
            'payrollAutoDeductions': p['enabled'] == true,
            'deductionMode': 'tiers',
            'lateTiers': p['tiers'],
            'earlyTiers': p['tiers'],
          });
          return _ok({'message': 'تم حفظ إعدادات خصم التأخير'});
        // ---- صرف مالية: salary / advance / commission / work-expense payouts and cash handed to HR
        case 'payouts_list':
          final pl = await _api.get('/payouts', <String, String?>{
            if (p['scope'] != null) 'scope': '${p['scope']}',
            if (p['status'] != null) 'status': '${p['status']}',
          });
          return _ok(pl.cast<String, dynamic>());
        // ---------------------------------------------------------------- الخزينة (office / HR cashboxes) — only /cash/* paths
        // تعديل وقت الحضور / الانصراف من التقرير اليومي (المدير / HR / المالك) — the original times and who edited stay on record
        case 'attendance_correct':
          final emp = await _id(p['uid']);
          final out = '${p['checkOut'] ?? ''}';
          await _api.post('/attendance/corrections', {
            'employeeId': emp, 'workDate': '${p['workDate']}', 'checkIn': '${p['checkIn']}',
            if (out.isNotEmpty) 'checkOut': out,
            'reason': '${p['reason'] ?? ''}'.trim().length >= 3 ? '${p['reason']}'.trim() : 'تعديل من تقرير الحضور',
          });
          return _ok({'message': 'تم تعديل المواعيد ✅'});
        case 'cash_get':
          final cg = '${p['path'] ?? ''}';
          if (!const ['/cash/', '/sales', '/payroll-batches', '/advances', '/finance/', '/insights/', '/payroll/employee/', '/forms/', '/payouts', '/commissions/', '/custody'].any(cg.startsWith)) return _fail('bad path');
          final cq = ((p['query'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', v == null || '$v'.isEmpty ? null : '$v'));
          return _ok((await _api.get(cg, cq.cast<String, String?>())).cast<String, dynamic>());
        case 'cash_post':
          final cp = '${p['path'] ?? ''}';
          if (!const ['/cash/', '/sales', '/payroll-batches', '/advances/', '/payouts/', '/forms/', '/finance/adjustments', '/custody'].any(cp.startsWith)) return _fail('bad path');
          final cr2 = p['method'] == 'delete' && cp.startsWith('/forms/')
              ? await _api.delete(cp)
              : p['method'] == 'patch'
              ? await _api.patch(cp, ((p['body'] as Map?) ?? const {}).cast<String, dynamic>())
              : await _api.post(cp, ((p['body'] as Map?) ?? const {}).cast<String, dynamic>());
          return _ok({...cr2.cast<String, dynamic>(), 'message': p['ok'] ?? 'تم ✅'});
        // ---------------------------------------------------------------- project commissions (عمولات المشاريع)
        case 'commission_projects':
          return _ok((await _api.get('/commissions/projects', <String, String?>{
            if ((p['q'] ?? '').toString().isNotEmpty) 'q': '${p['q']}',
            if ((p['status'] ?? '').toString().isNotEmpty) 'status': '${p['status']}',
          })).cast<String, dynamic>());
        case 'commission_project':
          return _ok((await _api.get('/commissions/projects/${p['id']}')).cast<String, dynamic>());
        case 'commission_project_save':
          final body = <String, dynamic>{
            'name': p['name'], 'totalPct': p['totalPct'], 'salesPct': p['salesPct'],
            'managerPct': p['managerPct'], 'companyPct': p['companyPct'], 'status': p['status'],
          };
          final saved = p['id'] == null
              ? await _api.post('/commissions/projects', body)
              : await _api.patch('/commissions/projects/${p['id']}', body);
          return _ok({...saved.cast<String, dynamic>(), 'message': p['id'] == null ? 'تم إضافة المشروع ✅' : 'تم حفظ المشروع ✅'});
        case 'commission_request_create':
          final cr = await _api.post('/commissions/requests', {
            'projectId': p['projectId'], 'unitNo': p['unitNo'], 'pricePerM2': p['pricePerM2'], 'areaM2': p['areaM2'],
            if ((p['note'] ?? '').toString().isNotEmpty) 'note': p['note'],
          });
          return _ok({...cr.cast<String, dynamic>(), 'message': 'تم إرسال طلب العمولة — مستني موافقة المدير العام'});
        case 'commission_requests':
          return _ok((await _api.get('/commissions/requests', <String, String?>{
            if (p['scope'] != null) 'scope': '${p['scope']}',
            if (p['status'] != null) 'status': '${p['status']}',
            if (p['projectId'] != null) 'projectId': '${p['projectId']}',
          })).cast<String, dynamic>());
        case 'commission_decide':
          final d = await _api.post('/commissions/requests/${p['id']}/decision', {
            'decision': p['decision'],
            if (p['month'] != null) 'month': p['month'],
            if ((p['reason'] ?? '').toString().isNotEmpty) 'reason': p['reason'],
          });
          return _ok({...d.cast<String, dynamic>(), 'message': p['decision'] == 'approve' ? 'تم اعتماد العمولة ✅' : 'تم رفض الطلب'});
        case 'commission_void':
          await _api.post('/commissions/requests/${p['id']}/void', {'reason': p['reason']});
          return _ok({'message': 'تم إلغاء العمولة'});
        case 'commission_entitlements':
          return _ok((await _api.get('/commissions/entitlements', <String, String?>{
            if (p['scope'] != null) 'scope': '${p['scope']}',
            if ((p['month'] ?? '').toString().isNotEmpty) 'month': '${p['month']}',
          })).cast<String, dynamic>());
        case 'payout_cashiers':
          return _ok((await _api.get('/payouts/cashiers')).cast<String, dynamic>());
        case 'payout_create':
          await _api.post('/payouts', {
            'employeeId': p['employeeId'], 'kind': p['kind'], 'amount': p['amount'],
            if ((p['month'] ?? '').toString().isNotEmpty) 'month': p['month'],
            if ((p['note'] ?? '').toString().isNotEmpty) 'note': p['note'],
            if (p['advanceId'] != null) 'advanceId': p['advanceId'],
            if (p['entitlementId'] != null) 'entitlementId': p['entitlementId'],
          });
          return _ok({'message': p['kind'] == 'fund' ? 'تم صرف الأموال — مستنية تأكيد الاستلام' : 'تم الصرف — مستني الموظف يأكد الاستلام'});
        case 'payout_receive':
          await _api.post('/payouts/${p['id']}/receive', {});
          return _ok({'message': 'تم تأكيد الاستلام ✅'});
        case 'payout_cancel':
          await _api.post('/payouts/${p['id']}/cancel', {});
          return _ok({'message': 'تم إلغاء الصرف'});
        case 'set_employee_flags':
          await _api.patch('/employees/${await _id(p['uid'])}', {
            if (p['deviceLock'] != null) 'deviceLock': p['deviceLock'] == true,
            if (p['selfieRequired'] != null) 'selfieRequired': p['selfieRequired'] == true,
          });
          return _ok({'message': 'تم الحفظ ✅'});
        case 'unbind_device':
          await _api.post('/employees/${await _id(p['uid'])}/unbind-device', {});
          return _ok({'message': 'تم فك ربط الموبايل — أول دخول جاي هيتربط بالموبايل الجديد'});
        case 'my_score':
          final sc = await _api.get('/me/score');
          return _ok({'score': sc['score'], 'deductions': sc['deductions'], 'evaluation': sc['evaluation']});
        case 'get_settings':
          return _ok({'settings': (await _api.get('/settings'))['settings']});

        case 'reset_employee_password':
          final r = await _api.post('/employees/${await _id(p['uid'])}/reset-password', {});
          return _ok({'emailed': r['emailed'] == true, 'emailTo': r['emailTo'], 'mailConfigured': r['mailConfigured'] == true,
            'password': r['temporaryPassword'] ?? r['pin']});

        case 'getLeaveRequests':
          return await _leaves(mineOnly: true);
        case 'getAllLeaveRequests':
          return await _leaves();
        case 'get_leave_requests':
          return await _leaves(pendingOnly: true);
        case 'submitLeaveRequest':
        case 'submitLeaveRequestByManager':
          return await _submitLeave(p);
        case 'cancelLeaveRequest':
          await _api.post('/requests/${p['requestId'] ?? p['request_id']}/cancel', {});
          return _ok({'message': 'تم إلغاء الطلب'});
        case 'approve_leave_request':
        case 'reject_leave_request':
          return await _decideLeave(p, action == 'approve_leave_request');

        case 'submitAdvanceRequest':
        case 'submitAdvanceRequestByManager':
        case 'submit_advance':
          return await _submitAdvance(p);
        case 'getAdvanceRequests':
          return await _advances(mineOnly: true);
        case 'getAllFinancialRequests':
        case 'getAllAdvanceRequests':
        case 'get_advances':
          return await _advances();
        case 'get_loan_requests':
          return await _advances(pendingOnly: true);
        case 'cancelAdvanceRequest':
          await _api.post('/advances/${Uri.decodeComponent((p['requestId'] ?? p['request_id']).toString())}/cancel', {});
          return _ok({'message': 'تم إلغاء الطلب'});
        case 'approve_loan_request':
        case 'reject_loan_request':
        case 'approveAdvanceRequest':
        case 'rejectAdvanceRequest':
          return await _decideAdvance(p, action.startsWith('approve'));
        case 'confirmReceiptAdvanceRequest':
          return _ok({'message': 'تم'});

        case 'get_all_employees':
          return await _employeesResponse(activeOnly: false);
        case 'employee_list':
        case 'getActiveEmployees':
          return await _employeesResponse(activeOnly: true);
        case 'get_employee_details':
          return await _employeeDetails(p);
        case 'add_employee':
          return await _addEmployee(p);
        case 'update_employee':
          return await _updateEmployee(p);
        case 'change_employee_status':
          final id = await _id(p['uid']);
          final active = p['active'] == true || p['active'] == '1' || p['active'] == 'true';
          await _api.post('/employees/$id/status', {'status': active ? 'active' : 'inactive'});
          return _ok({'message': active ? 'تم تفعيل الموظف' : 'تم إيقاف الموظف'});
        case 'change_employee_work_status':
          final id = await _id(p['uid']);
          await _mergeLegacy(id, {'status': (p['status'] ?? '').toString()});
          return _ok({'message': 'تم تحديث الحالة'});
        case 'update_employee_photo':
          return await _updatePhoto(await _id(p['uid']), p['image']);

        case 'getPublicHolidays':
        case 'getAllPublicHolidays':
        case 'getHolidaysByYear':
          return await _holidays(p['year']);
        case 'getHolidaysStats':
          return await _holidayStats();
        case 'addPublicHoliday':
          await _api.post('/holiday-periods', _holidayBody(p));
          return _ok({'message': 'تمت إضافة العطلة'});
        case 'updatePublicHoliday':
          await _api.put('/holiday-periods/${p['holidayId'] ?? p['id']}', _holidayBody(p));
          return _ok({'message': 'تم تحديث العطلة'});
        case 'deletePublicHoliday':
          await _api.delete('/holiday-periods/${p['holidayId'] ?? p['id']}');
          return _ok({'message': 'تم حذف العطلة'});

        case 'getUserNotifications':
        case 'getNotifications':
        case 'getReceivedNotifications':
          return await _notifications();
        case 'markNotificationAsRead':
          await _api.post('/notifications/${p['notificationId']}/read', {});
          return _ok();
        case 'markAllNotificationsAsRead':
          await _api.post('/notifications/read-all', {});
          return _ok();
        case 'deleteNotification':
          await _api.delete('/notifications/${p['notificationId']}');
          return _ok();
        case 'clearAllNotifications':
          await _api.delete('/notifications');
          return _ok();
        case 'sendNotification':
          return await _sendNotification(p);
        case 'getSentNotifications':
          return await _sentNotifications();

        case 'attendance_report_daily':
        case 'attendance_report_daily_expanded':
          return await _dailyReport(p, expanded: action.endsWith('expanded'));
        case 'attendance_report_monthly':
          return await _monthlyReport(p);
        case 'get_today_stats':
        case 'today_stats':
          return await _todayStats();
        case 'get_attendance_by_project':
          return await _byTeam();
        case 'get_today_attendance':
          return await _board(onBreakOnly: false, filter: (p['filter'] ?? 'present').toString());
        case 'get_break_employees':
          return await _outNow();

        default:
          return _fail('هذه الخدمة غير متاحة في هذا الإصدار');
      }
    } on ApiException catch (e) {
      final msg = _message(e);
      // a repeated request while another one is still waiting / overlapping: a popup, not only a small bar
      final reason = e.details?['reason'];
      if (reason == 'pending_exists' || reason == 'overlap' || reason == 'unit_sold' || reason == 'duplicate_receipt' || reason == 'unit_has_buyer') {
        AlertCenter.instance.popupError('مينفعش تكرر الطلب', msg);
      }
      return {'success': false, 'code': e.code, 'status': e.status, 'message': msg};
    } catch (e) {
      return _fail('حدث خطأ غير متوقع');
    }
  }

  static String _message(ApiException e) {
    if (e.isNetwork) return 'تعذّر الاتصال بالخادم. تأكد من الإنترنت وحاول مرة أخرى\n(${e.message})';
    if (e.status == 401) return 'انتهت الجلسة، سجّل الدخول مرة أخرى';
    if (e.details?['reason'] == 'device_mismatch') return 'الحساب ده متسجل على موبايل تاني. كلّم الإدارة تفك الربط';
    if (e.details?['reason'] == 'selfie_required') return 'لازم صورة سيلفي عشان تسجل حضور';
    if (e.details?['distanceOutsideM'] != null) return 'إنت بعيد عن المكتب بحوالي ${e.details!['distanceOutsideM']} متر';
    if (e.details?['reason'] == 'pending_exists') {
      final what = '${e.details?['what'] ?? 'طلب'}';
      return 'عندك $what لسه مستني الموافقة — استنى الرد عليه أو الغيه الأول وبعدين اطلب تاني';
    }
    if (e.details?['reason'] == 'duplicate_receipt') return 'رقم الإيصال ده اتسجل قبل كده';
    if (e.details?['reason'] == 'batch_exists') return 'الشهر ده ليه دفعة مرتبات بالفعل';
    if (e.details?['reason'] == 'already_deducted') return 'السلفة دي ليها خصم في الشهر ده بالفعل';
    if (e.details?['reason'] == 'max_stages') return 'السلفة بتتخصم على مرحلتين بالكتير';
    if (e.details?['reason'] == 'over_deduct') return 'المبلغ أكبر من الباقي من السلفة (${e.details?['remaining']} جنيه)';
    if (e.details?['reason'] == 'over_pay') return 'المبلغ أكبر من الباقي من المرتب (${e.details?['remaining']} جنيه)';
    if (e.details?['reason'] == 'unit_has_buyer') return 'الوحدة دي عليها بيع شغال لمشتري تاني في نفس المشروع';
    if (e.details?['reason'] == 'over_collect') return 'المبلغ أكبر من الباقي على القسط ده (الباقي ${e.details?['remaining']} جنيه)';
    if (e.details?['reason'] == 'over_refund') return 'المبلغ أكبر من الباقي للاسترداد (${e.details?['remaining']} جنيه)';
    if (e.details?['reason'] == 'split_mismatch') {
      return 'مجموع النسب (${e.details?['sum']}%) لازم يساوي إجمالي العمولة (${e.details?['total']}%)';
    }
    if (e.details?['reason'] == 'unit_sold') return 'الوحدة دي اتباعت واتعتمدت عمولتها قبل كده في نفس المشروع';
    if (e.details?['reason'] == 'project_inactive') return 'المشروع ده مش بيستقبل صفقات دلوقتي';
    if (e.details?['reason'] == 'month_closed') return 'مرتب الشهر ده اتصرف خلاص — اختار شهر بعده';
    if (e.details?['reason'] == 'already_paid') return 'العمولة دي اتصرفت — الغي الصرف الأول';
    if (e.details?['reason'] == 'overlap') return 'الوقت ده متداخل مع إذن أو زيارة تانية ليك';
    if (e.details?['reason'] == 'otp_invalid') return 'الكود غلط أو انتهت صلاحيته';
    if (e.details?['reason'] == 'otp_rate_limited') return 'طلبت أكواد كتير — استنى ربع ساعة وجرب تاني';
    if (e.details?['reason'] == 'reset_expired') return 'الوقت خلص — اطلب كود جديد';
    if (e.details?['reason'] == 'mail_off') return 'الإرسال بالإيميل مش متفعّل — كلّم الموارد البشرية';
    if (e.details?['reason'] == 'no_cash') return 'الرصيد اللي معاك مش كفاية (${e.details?['balance'] ?? 0} جنيه) — اطلب صرف أموال من المدير أو المالك';
    if (e.details?['reason'] == 'no_email') return 'مفيش إيميل مسجّل للحساب ده — كلّم الموارد البشرية تضيفه أو تعيد تعيين كلمة المرور';
    if (e.details?['reason'] == 'mail_failed') return 'ماقدرناش نبعت الكود دلوقتي — جرّب كمان شوية أو كلّم الموارد البشرية';
    if (e.status == 403) return 'ليس لديك صلاحية لهذا الإجراء';
    if (e.status == 404) return 'غير موجود';
    return e.message;
  }

  // ------------------------------------------------------------------ session
  static Future<Map<String, dynamic>> _login(Map<String, dynamic> p) async {
    final id = (p['identifier'] ?? p['uid'] ?? '').toString().trim();
    final pass = (p['pass'] ?? p['password'] ?? '').toString();
    if (id.isEmpty || pass.isEmpty) return _fail('أدخل الكود أو الموبايل وكلمة المرور');
    try {
      await JphBridge.session.login(id, pass);
    } on ApiException catch (e) {
      if (e.status == 401) return _fail('الكود أو كلمة المرور غير صحيحة');
      if (e.status == 423) return _fail('تم إيقاف الدخول مؤقتاً بسبب محاولات خاطئة كثيرة. حاول بعد 15 دقيقة');
      return _fail(_message(e));
    }
    final me = JphBridge.session.me ?? {};
    JphBridge.remember(_s(me['code'], ''), _s(me['id'], ''));
    final role = _s(me['role_key'], 'sales_employee');
    final photo = me['has_photo'] == true ? (await _links(photos: [_s(me['id'])]))['photo:${me['id']}'] ?? '' : '';
    return _ok({
      'uid': me['code'],
      'name': me['full_name'],
      'role': roleAr[role] ?? role,
      'validity': role == 'owner' || _has('attendance.read_all') || _has('attendance.read_team') ? 'admin' : 'موظف',
      'photo': photo,
      'companyId': 'VALUE',
      'companyName': JphBridge.session.company?['company_name_ar'] ?? '',
      'mustChangePassword': JphBridge.session.mustChangePassword,
    });
  }

  static Future<Map<String, dynamic>> _profile(Map<String, dynamic> p) async {
    final id = await _id(p['uid']);
    Map<String, dynamic> e;
    Map<String, dynamic>? company;
    if (id == JphBridge.myId) {
      final r = await _api.get('/me/profile');
      e = (r['profile'] as Map).cast<String, dynamic>();
      company = (r['company'] as Map?)?.cast<String, dynamic>();
    } else {
      e = ((await _api.get('/employees/$id'))['employee'] as Map).cast<String, dynamic>();
    }
    final lf = ((e['legacy_fields'] as Map?) ?? {}).cast<String, dynamic>();
    final wd = ((e['weekend_days'] as List?) ?? const []).map((x) => _weekdaysAr[x] ?? '').where((x) => x.isNotEmpty).join('، ');
    final photo = e['has_photo'] == true ? (await _links(photos: [id]))['photo:$id'] ?? '' : '';
    final role = _s(e['role_key'], 'sales_employee');
    // salary figures from the real salary (own payslip, or salary readers): hour / day / month / start / increase
    Map<String, dynamic> pay = {};
    try {
      final now = DateTime.now();
      pay = (((await _api.get('/payroll/employee/$id', {'month': '${now.year}-${_two(now.month)}'}))['payroll']) as Map).cast<String, dynamic>();
    } catch (_) {}
    String money(Object? v) {
      final n = v is num ? v : num.tryParse('${v ?? ''}');
      if (n == null) return '--';
      return '${n == n.roundToDouble() ? n.round() : n.toStringAsFixed(2)} ج.م';
    }
    final base = pay['baseSalary'] as num?;
    final start = num.tryParse(_s(lf['startSalary'])) ?? base;
    return _ok({
      'hourRate': money(pay['hourWage']),
      'dayRate': money(pay['dayWage']),
      'monthSalary': money(base),
      'startSalaryCalc': money(start),
      'increaseCalc': base == null || start == null ? '--' : money(base - start),
      'source': role == 'owner' ? 'owner' : 'employee',
      'uid': _s(e['code']),
      'employeeId': id,
      'name': _s(e['full_name']),
      'role': roleAr[role] ?? role,
      'email': _s(e['email']),
      'nationalIdNo': _s(lf['nationalIdNo'], ''),
      'birthDate': _s(lf['birthDate'], ''),
      'phone': _s(e['phone']),
      'joinDate': _date(e['joining_date']).isEmpty ? '--' : _date(e['joining_date']),
      'followToName': _s(e['manager_name'] ?? e['sales_manager_name']),
      'payType': _s(lf['accounting'], 'شهرى'),
      'dailyRate': _s(lf['dailyRate']),
      'salary': _s(lf['salary']),
      'startSalary': _s(lf['startSalary']),
      'increment': _s(lf['increase']),
      'dayOff': wd.isEmpty ? _s(lf['leaveDay']) : wd,
      'workHours': e['start_time'] != null ? '${_s(e['start_time']).substring(0, 5)} - ${_s(e['end_time']).substring(0, 5)}' : _s(lf['workHours']),
      'absenceFactor': _s(lf['absenceMultiplier'], '1'),
      'overtimeFactor': _s(lf['overtimeMultiplier'], '1'),
      'bankName': _s(e['bank_name']),
      'accountHolder': _s(e['account_holder']),
      'iban': _s(e['iban']),
      'accountNumber': _s(e['account_number']),
      'level': _s(lf['level'], '0%'),
      'employeeStatus': _s(lf['status'], e['status'] == 'active' ? 'على رأس العمل' : 'موقوف'),
      'status': e['status'] == 'active' ? 'نشط' : 'موقوف',
      'validity': role == 'owner' || _has('attendance.read_all') || _has('attendance.read_team') ? 'admin' : 'موظف',
      'companyName': _s(company?['company_name_ar']),
      'createdAt': _date(e['created_at']),
      'lastModifiedDate': _date(e['updated_at']),
      'notes': _s(e['notes']),
      'team': _s(e['team_name']),
      'jobTitle': _s(e['job_title']),
      'photo': photo,
    });
  }

  static Future<Map<String, dynamic>> _updateProfile(Map<String, dynamic> p) async {
    final body = <String, dynamic>{};
    for (final k in ['email', 'phone', 'bankName', 'accountHolder', 'iban', 'accountNumber']) {
      if (p[k] != null) body[k] = p[k].toString().trim().isEmpty ? null : p[k].toString().trim();
    }
    if (body.isNotEmpty) await _api.patch('/me/profile', body);
    if (p['photo'] != null && p['photo'].toString().isNotEmpty) {
      final r = await _updatePhoto(JphBridge.myId, p['photo']);
      if (r['success'] != true) return r;
      final link = (await _links(photos: [JphBridge.myId]))['photo:${JphBridge.myId}'];
      await JphBridge.session.refreshMe();
      return _ok({'message': 'تم تحديث البيانات بنجاح', 'photo': link ?? ''});
    }
    return _ok({'message': 'تم تحديث البيانات بنجاح'});
  }

  static Future<Map<String, dynamic>> _updatePhoto(String id, Object? image) async {
    var raw = (image ?? '').toString();
    if (raw.isEmpty) return _fail('لا توجد صورة');
    var mime = 'image/jpeg';
    final m = RegExp(r'^data:(image/[a-z]+);base64,').firstMatch(raw);
    if (m != null) {
      mime = m.group(1)!;
      raw = raw.substring(m.end);
    } else if (!RegExp(r'^[A-Za-z0-9+/=\s]+$').hasMatch(raw)) {
      // the original add-employee form sends raw bytes as a char string
      raw = base64Encode(raw.codeUnits.map((c) => c & 0xff).toList());
    }
    if (raw.startsWith('iVBOR')) mime = 'image/png';
    await _api.put('/employees/$id/photo', {'mime': mime, 'data': raw});
    return _ok({'message': 'تم تحديث الصورة'});
  }

  // ------------------------------------------------------------------ attendance (self)
  static Future<Map<String, dynamic>> _today() async {
    final r = await _todayMerged();
    var outMinutes = 0;
    try {
      final o = await _api.get('/outings/today');
      for (final x in _list(o['history'])) {
        if (x['status'] != 'approved' && x['status'] != 'superseded') continue;
        if (x['parent_id'] != null) continue;
        final from = _dt(x['starts_at'] ?? x['requested_at']);
        final to = _dt(x['returned_at']) ?? DateTime.now();
        if (from != null) outMinutes += to.difference(from).inMinutes.clamp(0, 24 * 60);
      }
    } catch (_) {}
    final a = (r['attendance'] as Map?)?.cast<String, dynamic>();
    final b = (r['break'] as Map?)?.cast<String, dynamic>();
    final me = JphBridge.session.me ?? {};
    final photo = me['has_photo'] == true ? (await _links(photos: [JphBridge.myId]))['photo:${JphBridge.myId}'] ?? '' : '';
    final worked = a == null
        ? null
        : a['checkOut'] != null
            ? (a['workedMinutes'] as num?)
            : DateTime.now().difference(_dt(a['checkIn'])!).inMinutes;
    return _ok({
      'checkInTime': a == null ? '--:--' : _time(a['checkIn']),
      'checkInAt': a == null ? '' : '${a['checkIn'] ?? ''}', // the real check-in instant — the live work timer counts from it
      'checkOutTime': a?['checkOut'] == null ? '--:--' : _time(a!['checkOut']),
      'onBreak': false, // the break was replaced by hourly permission / visit
      'outingTime': _hm(outMinutes),
      'breakStartTime': b == null ? '--:--' : _time(b['start']),
      'breakEndTime': b?['end'] == null ? '--:--' : _time(b!['end']),
      'breakTime': _hm(outMinutes),
      'breakMinutesAllowed': b?['allowedMinutes'] ?? r['breakAllowedMinutes'],
      'workTime': worked == null ? '--:--:--' : _hms(worked),
      'lateTime': _hm(a?['lateMinutes'] as num?),
      'photo': photo,
      'selfieRequired': r['selfieRequired'] == true,
      'gpsRequired': r['gpsRequired'] == true,
      'attendanceExempt': r['attendanceExempt'] == true,
    });
  }

  static Future<Map<String, dynamic>> _month() async {
    final now = DateTime.now();
    final r = await _api.get('/attendance', {'month': '${now.year}-${_two(now.month)}', 'employeeId': JphBridge.myId});
    final sm = ((r['summary'] as Map?) ?? {}).cast<String, dynamic>();
    final sick = _list(r['days']).where((d) => d['absenceType'] == 'sick').length;
    return _ok({
      'workDays': '${sm['attendedDays'] ?? 0}',
      'leaveDays': '${sm['approvedAbsenceDays'] ?? 0}',
      'leaveAttendance': '${sm['unpaidAbsenceDays'] ?? 0}',
      'absentDays': '${sm['unapprovedAbsenceDays'] ?? 0}',
      'sickLeave': '$sick',
      'lateTime': _hhmm(sm['lateMinutes'] as num?),
    });
  }

  /// Current GPS fix for checks done on the server (empty when location is off / not allowed).
  static Future<Map<String, dynamic>> _gps() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return {};
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return {};
      final p = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)));
      return {'lat': p.latitude, 'lng': p.longitude, 'accuracyM': p.accuracy};
    } catch (_) {
      return {};
    }
  }

  /// location from the original camera service: "lat,lng" or "lat,lng,accuracy"
  static Map<String, dynamic> _loc(Object? location) {
    final parts = (location ?? '').toString().split(',').map((x) => double.tryParse(x.trim())).toList();
    if (parts.length < 2 || parts[0] == null || parts[1] == null) return {};
    return {'lat': parts[0], 'lng': parts[1], 'accuracyM': parts.length > 2 && parts[2] != null ? parts[2] : 50};
  }

  // ---- offline punches: kept on the phone (with the real time) until the internet is back
  static String _localDate() {
    final n = DateTime.now();
    return '${n.year}-${_two(n.month)}-${_two(n.day)}';
  }

  static Future<Map<String, dynamic>> _offlinePunch() async {
    try {
      final s = (await SharedPreferences.getInstance()).getString('offline_punch');
      return s == null ? {} : (jsonDecode(s) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  static Future<void> _setOfflinePunch(Map<String, dynamic>? v) async {
    final p = await SharedPreferences.getInstance();
    v == null ? await p.remove('offline_punch') : await p.setString('offline_punch', jsonEncode(v));
  }

  /// Today's attendance = the server's (or its offline copy) + any punch still waiting on the phone.
  static Future<Map<String, dynamic>> _todayMerged() async {
    final r = Map<String, dynamic>.from(await _api.get('/attendance/today'));
    final d = _localDate();
    if (r['date'] != null && r['date'] != d) { r['attendance'] = null; r['date'] = d; } // offline copy from another day
    final local = await _offlinePunch();
    if (local['date'] == d) {
      var a = (r['attendance'] as Map?)?.cast<String, dynamic>();
      final serverHasIt = r['_offline'] != true && a != null && (local['out'] == null || a['checkOut'] != null);
      if (serverHasIt) {
        await _setOfflinePunch(null);
      } else {
        a = {...?a};
        a['checkIn'] ??= local['in'];
        if (local['out'] != null) a['checkOut'] = local['out'];
        a['offline'] = true;
        r['attendance'] = a;
      }
    } else if (local.isNotEmpty) {
      await _setOfflinePunch(null);
    }
    return r;
  }

  static Future<Map<String, dynamic>> _checkIn(Map<String, dynamic> p) async {
    Map<String, dynamic> today;
    try {
      today = await _todayMerged();
    } on ApiException catch (e) {
      if (!e.isNetwork) rethrow;
      today = {'attendance': null}; // first use with no internet and nothing saved yet
    }
    if (today['attendanceExempt'] == true) return _fail('حسابك مش محتاج تسجيل حضور وانصراف');
    final a = today['attendance'] as Map?;
    if (a != null && a['checkOut'] != null) return _fail('إنت سجلت انصراف النهارده خلاص');
    if (a != null) return _checkOut(p);
    final body = <String, dynamic>{..._loc(p['location'])};
    final img = (p['image'] ?? '').toString();
    if (img.isNotEmpty) {
      body['selfie'] = img.replaceFirst(RegExp(r'^data:image/[a-z]+;base64,'), '');
      body['selfieMime'] = 'image/jpeg';
    }
    final r = await _api.postOrQueue('/attendance/check-in', body, label: 'تسجيل حضور');
    if (r['queued'] == true) {
      final now = DateTime.now().toUtc().toIso8601String();
      await _setOfflinePunch({'date': _localDate(), 'in': now});
      return _ok({'message': 'اتسجل حضورك ${_time(now)} على الموبايل 📴 — هيتبعت للسيستم أول ما النت يرجع'});
    }
    final at = (r['attendance'] as Map).cast<String, dynamic>();
    final late = (at['lateMinutes'] ?? 0) as num;
    return _ok({'message': late > 0 ? 'اتسجل حضورك ${_time(at['checkIn'])} — متأخر $late دقيقة' : 'تم تسجيل الحضور ${_time(at['checkIn'])} ✅'});
  }

  static Future<Map<String, dynamic>> _checkOut(Map<String, dynamic> p) async {
    final r = await _api.postOrQueue('/attendance/check-out', _loc(p['location']), label: 'تسجيل انصراف');
    if (r['queued'] == true) {
      final now = DateTime.now().toUtc().toIso8601String();
      final local = await _offlinePunch();
      await _setOfflinePunch({'date': _localDate(), 'in': local['date'] == _localDate() ? local['in'] : null, 'out': now});
      return _ok({'message': 'اتسجل انصرافك ${_time(now)} على الموبايل 📴 — هيتبعت للسيستم أول ما النت يرجع'});
    }
    final at = (r['attendance'] as Map).cast<String, dynamic>();
    return _ok({'message': 'تم تسجيل الانصراف ${_time(at['checkOut'])} 👋'});
  }

  // ------------------------------------------------------------------ leave
  static Map<String, dynamic> _leaveItem(Map<String, dynamic> r) {
    final type = _leaveKeyToType[r['absence_type']] ?? 'إجازة';
    final status = _leaveStatus(_s(r['status'], 'pending'));
    return {
      'id': r['id'],
      'requestId': r['id'],
      'employeeId': _s(r['employee_code']),
      'employeeName': _s(r['employee_name']),
      'leaveType': type,
      'fromDate': _date(r['start_date']),
      'toDate': _date(r['end_date']),
      'startDate': _date(r['start_date']),
      'endDate': _date(r['end_date']),
      'days': r['days_count'] ?? 0,
      'daysCount': r['days_count'] ?? 0,
      'reason': _s(r['reason'], 'لا يوجد سبب'),
      'notes': r['status'] == 'pending_hr' ? 'وافق المدير — بانتظار الموارد البشرية' : (r['status'] == 'pending_manager' ? 'بانتظار المدير المباشر / المدير العام' : ''),
      'approvedBy': _s(r['approved_by_names'], ''),
      // approve / reject only for whoever may decide now (never the employee himself)
      'canDecide': (r['can'] is Map) && ((r['can'] as Map)['managerDecide'] == true || (r['can'] as Map)['hrDecide'] == true),
      'status': status,
      'requestDate': _date(r['created_at']),
      'submittedDate': _date(r['created_at']),
      'createdAt': _date(r['created_at']),
      'image': '',
    };
  }

  static Future<Map<String, dynamic>> _leaves({bool mineOnly = false, bool pendingOnly = false}) async {
    final q = <String, String?>{'type': 'full_day_absence'};
    if (mineOnly) q['scope'] = 'mine';
    if (pendingOnly) q['awaitingMe'] = '1';
    final rows = _list((await _api.get('/requests', q))['requests']).map(_leaveItem).toList();
    final st = {'pending': 0, 'approved': 0, 'rejected': 0, 'cancelled': 0};
    for (final r in rows) {
      final k = switch (r['status']) { 'مقبؤل' => 'approved', 'مرفوض' => 'rejected', 'ملغي' => 'cancelled', _ => 'pending' };
      st[k] = st[k]! + 1;
    }
    return _ok({'requests': rows, 'stats': st, 'count': rows.length});
  }

  static Future<Map<String, dynamic>> _submitLeave(Map<String, dynamic> p) async {
    final emp = await _id(p['employeeId'] ?? p['uid']);
    final reason = (p['reason'] ?? '').toString().trim();
    final body = <String, dynamic>{
      'type': 'full_day_absence',
      'startDate': _date(p['fromDate']),
      'endDate': _date(p['toDate']),
      'absenceType': _leaveTypeToKey[p['leaveType']] ?? 'annual',
      'reason': reason.length >= 3 ? reason : 'طلب إجازة',
      if (emp != JphBridge.myId) 'employeeId': emp,
    };
    final rq = await _api.postOrQueue('/requests', body, label: 'طلب إجازة');
    if (rq['queued'] == true) return _ok({'message': 'الطلب اتحفظ على الموبايل 📴 وهيتبعت أول ما النت يرجع'});
    return _ok({'message': emp == JphBridge.myId ? 'تم إرسال طلب الإجازة ✅' : 'تمت إضافة الإجازة للموظف ✅'});
  }

  static Future<Map<String, dynamic>> _decideLeave(Map<String, dynamic> p, bool approve) async {
    final id = Uri.decodeComponent((p['request_id'] ?? p['requestId']).toString());
    await _api.post('/requests/$id/decision',
        approve ? {'decision': 'approve'} : {'decision': 'reject', 'comment': (p['note'] ?? 'مرفوض من الإدارة').toString()});
    return _ok({'message': approve ? 'تمت الموافقة على الطلب' : 'تم رفض الطلب'});
  }

  // ------------------------------------------------------------------ advances / work expenses
  static Future<Map<String, dynamic>> _submitAdvance(Map<String, dynamic> p) async {
    final emp = await _id(p['employeeId'] ?? p['uid']);
    final month = _monthIndex(p['month']);
    final now = DateTime.now();
    final year = month < now.month - 6 ? now.year + 1 : now.year;
    final img = (p['image'] ?? '').toString();
    final ra = await _api.postOrQueue('/advances', {
      'kind': (p['requestType'] ?? '') == 'مصاريف عمل' ? 'work_expense' : 'advance',
      'amount': num.tryParse('${p['amount']}') ?? 0,
      'period': '$year-${_two(month)}-01',
      'note': (p['note'] ?? '').toString(),
      if (emp != JphBridge.myId) 'employeeId': emp,
      if (img.isNotEmpty) 'attachment': img,
    }, label: 'طلب مالي');
    return _ok({'message': ra['queued'] == true ? 'الطلب اتحفظ على الموبايل 📴 وهيتبعت أول ما النت يرجع' : 'تم إرسال الطلب ✅'});
  }

  static Future<Map<String, dynamic>> _advances({bool mineOnly = false, bool pendingOnly = false}) async {
    final r = await _api.get('/advances', mineOnly ? {'scope': 'mine'} : null);
    var rows = _list(r['advances']);
    if (pendingOnly) rows = rows.where((x) => x['status'] == 'pending' && x['canDecide'] == true).toList();
    final items = rows.map((x) {
      final period = _date(x['period']);
      final m = int.tryParse(period.length >= 7 ? period.substring(5, 7) : '') ?? 1;
      final status = _advanceStatus(_s(x['status'], 'pending'));
      return <String, dynamic>{
        'id': x['id'],
        'requestId': x['id'],
        'employeeId': _s(x['employee_code']),
        'employeeName': _s(x['employee_name']),
        'requestType': x['kind'] == 'work_expense' ? 'مصاريف عمل' : 'سلفة',
        'amount': num.tryParse('${x['amount_egp']}') ?? 0,
        'month': _monthsAr[m - 1],
        'note': _s(x['note'], ''),
        'status': status,
        'stageLabel': x['status'] == 'pending' ? 'بانتظار موافقة المدير العام'
            : switch (x['payment']) {
                'unpaid' => 'معتمد — في انتظار الصرف',
                'awaiting_receipt' => 'اتصرف — في انتظار تأكيد الاستلام',
                'received' => 'تم الاستلام ✅',
                _ => '',
              },
        // صرف → تم الاستلام (the HR cashbox pays once the employee confirms)
        'payment': _s(x['payment'], ''),
        'canPay': x['canPay'] == true,
        'canReceive': x['canReceive'] == true,
        'payoutId': _s(x['payout_id'], ''),
        'employeeUuid': _s(x['employee_id'], ''),
        'kind': _s(x['kind'], 'advance'),
        'periodMonth': period.length >= 7 ? period.substring(0, 7) : '',
        'ceoStatus': x['gm_approved_at'] != null ? 'مؤكد' : (x['status'] == 'rejected' ? 'مرفوض' : 'قيد المراجعة'),
        'canDecide': x['canDecide'] == true,
        'stage': _s(x['stage'], ''),
        'gmName': _s(x['gm_name'], ''),
        'recipientStatus': x['status'] == 'confirmed' ? 'مؤكد' : '--',
        'confirmedBy': _s(x['decided_by_name']),
        'requestDate': _date(x['created_at']),
        'createdAt': _date(x['created_at']),
        'day': _date(x['created_at']),
        'image': '',
      };
    }).toList();
    final st = <String, dynamic>{'total': items.length, 'confirmed': 0, 'pending': 0, 'rejected': 0, 'cancelled': 0, 'totalAmount': 0.0};
    for (final x in items) {
      final k = switch (x['status']) { 'مؤكد' => 'confirmed', 'مرفوض' => 'rejected', 'ملغي' => 'cancelled', _ => 'pending' };
      st[k] = (st[k] as int) + 1;
      if (k == 'confirmed') st['totalAmount'] = (st['totalAmount'] as double) + (x['amount'] as num).toDouble();
    }
    return _ok({'requests': items, 'stats': st, 'count': items.length});
  }

  static Future<Map<String, dynamic>> _decideAdvance(Map<String, dynamic> p, bool approve) async {
    final id = Uri.decodeComponent((p['request_id'] ?? p['requestId']).toString());
    if (p['is_cancel'] == true) {
      await _api.post('/advances/$id/cancel', {});
      return _ok({'message': 'تم إلغاء الطلب'});
    }
    await _api.post('/advances/$id/decision', {'decision': approve ? 'confirm' : 'reject'});
    return _ok({'message': approve ? 'تم تأكيد الطلب' : 'تم رفض الطلب'});
  }

  // ------------------------------------------------------------------ employees
  static Future<List<Map<String, dynamic>>> _employees({bool all = true}) async {
    if (!_has('employee.read_all') && !_has('employee.read_team')) {
      final me = JphBridge.session.me ?? {};
      final row = <String, dynamic>{...me};
      JphBridge.remember(_s(me['code'], ''), _s(me['id'], ''));
      return [row];
    }
    final rows = _list((await _api.get('/employees', {'status': all ? 'all' : 'active'}))['employees']);
    for (final e in rows) {
      JphBridge.remember(_s(e['code'], ''), _s(e['id'], ''));
    }
    return rows;
  }

  static Map<String, dynamic> _employeeItem(Map<String, dynamic> e, Map<String, String> links) {
    final lf = ((e['legacy_fields'] as Map?) ?? {}).cast<String, dynamic>();
    final role = _s(e['role_key'], 'sales_employee');
    final salary = e['base_salary'] ?? lf['salary'];
    return {
      ...lf.map((k, v) => MapEntry(k, v?.toString())),
      'id': e['id'],
      'uid': _s(e['code'], ''),
      'name': _s(e['full_name'], ''),
      'role': roleAr[role] ?? role,
      'roleKey': role,
      'position': _s(e['position_name_ar'], roleAr[role] ?? role),
      'positionKey': _s(e['position_key'], role),
      'phone': _s(e['phone'], ''),
      'email': _s(e['email'], ''),
      'nationalIdNo': _s(lf['nationalIdNo'], ''),
      'birthDate': _s(lf['birthDate'], ''),
      'active': e['status'] == 'active',
      'status': _s(lf['status'] ?? e['work_status'], e['status'] == 'active' ? 'على رأس العمل' : 'موقوف'),
      'salary': salary == null ? '0' : '$salary',
      'dailyRate': _s(lf['dailyRate'], '0'),
      'level': _s(lf['level'], '0%'),
      'joinDate': _date(e['joining_date']),
      'photo': links['photo:${e['id']}'] ?? '',
      'team': _s(e['team_name'], ''),
      'jobTitle': _s(e['job_title'], ''),
      'managedBy': _s(e['sales_manager_name'] ?? lf['managedBy'], ''),
      'salesManagerId': _s(e['sales_manager_id'], ''),
      'generalManagerId': _s(e['general_manager_id'], ''),
      'generalManager': _s(e['general_manager_name'], ''),
      'attendanceExempt': e['attendance_exempt'] == true,
      'workStart': _s(e['work_start'], ''),
      'workEnd': _s(e['work_end'], ''),
      'deviceBound': e['device_bound'] == true,
      'deviceLock': e['device_lock'] == true,
      'selfieRequired': e['selfie_required'] == true,
      'deviceLabel': _s(e['device_label'], ''),
    };
  }

  static Future<Map<String, dynamic>> _employeesResponse({required bool activeOnly}) async {
    var rows = await _employees(all: !activeOnly);
    if (activeOnly) rows = rows.where((e) => (e['status'] ?? 'active') == 'active').toList();
    final links = await _links(photos: rows.where((e) => e['has_photo'] == true).map((e) => _s(e['id'])).toList());
    final items = rows.map((e) => _employeeItem(e, links)).toList();
    return _ok({'employees': items, 'count': items.length});
  }

  static Future<Map<String, dynamic>> _employeeDetails(Map<String, dynamic> p) async {
    final id = await _id(p['uid']);
    final e = ((await _api.get('/employees/$id'))['employee'] as Map).cast<String, dynamic>();
    final links = e['has_photo'] == true ? await _links(photos: [id]) : <String, String>{};
    final sal = (e['salary'] as Map?)?['base_salary'];
    return _ok({'employee': {..._employeeItem({...e, if (sal != null) 'base_salary': sal}, links)}});
  }

  static const _legacyKeys = ['nationalIdNo', 'birthDate', 'dailyRate', 'accounting', 'managedBy', 'managedByUid', 'foremanId', 'startSalary', 'increase',
    'leaveDay', 'workHours', 'absenceMultiplier', 'overtimeMultiplier', 'level', 'status', 'salary'];

  static Map<String, dynamic> _legacyOf(Map<String, dynamic> p) => {
        for (final k in _legacyKeys)
          if (p[k] != null) k: p[k].toString(),
      };

  static Future<void> _mergeLegacy(String id, Map<String, dynamic> extra) async {
    final e = ((await _api.get('/employees/$id'))['employee'] as Map).cast<String, dynamic>();
    final lf = ((e['legacy_fields'] as Map?) ?? {}).cast<String, dynamic>();
    await _api.patch('/employees/$id', {'legacyFields': {...lf, ...extra}});
  }

  /// Direct manager / general manager / "no attendance" / personal shift, when the screen sent them.
  static Map<String, dynamic> _orgFields(Map<String, dynamic> p) {
    String? idOrNull(Object? v) => (v == null || v.toString().isEmpty) ? null : v.toString();
    return {
      if (p.containsKey('salesManagerId')) 'salesManagerId': idOrNull(p['salesManagerId']),
      if (p.containsKey('generalManagerId')) 'generalManagerId': idOrNull(p['generalManagerId']),
      if (p.containsKey('attendanceExempt') && _has('employee.attendance_exempt')) 'attendanceExempt': p['attendanceExempt'] == true,
      if (p.containsKey('deviceLock') && _has('employee.manage')) 'deviceLock': p['deviceLock'] == true,
      if (p.containsKey('selfieRequired') && _has('employee.manage')) 'selfieRequired': p['selfieRequired'] == true,
      if (p.containsKey('workStart'))
        ...((p['workStart'] ?? '').toString().isEmpty || (p['workEnd'] ?? '').toString().isEmpty
            ? {'workStart': null, 'workEnd': null}
            : {'workStart': p['workStart'], 'workEnd': p['workEnd']}),
    };
  }

  static Future<Map<String, dynamic>> _addEmployee(Map<String, dynamic> p) async {
    final role = roleKeyOf(p['role']?.toString());
    final body = <String, dynamic>{
      'code': (p['uid'] ?? '').toString().toUpperCase(),
      'fullName': (p['name'] ?? '').toString().trim(),
      if ((p['position'] ?? '').toString().isNotEmpty) 'position': p['position'] else 'role': role,
      if ((p['phone'] ?? '').toString().trim().isNotEmpty) 'phone': p['phone'].toString().trim(),
      if ((p['email'] ?? '').toString().trim().isNotEmpty) 'email': p['email'].toString().trim(),
      if ((p['password'] ?? '').toString().trim().isNotEmpty) 'password': p['password'].toString().trim(),
      if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch((p['joinDate'] ?? '').toString())) 'joiningDate': p['joinDate'],
      'legacyFields': _legacyOf(p),
      if (p['documents'] is Map && (p['documents'] as Map).values.any((v) => v != null)) 'documents': p['documents'],
      ..._orgFields(p),
    };
    final sal = num.tryParse('${p['startSalary'] ?? p['salary'] ?? ''}');
    if (sal != null && sal > 0 && _has('employee.salary_manage')) body['baseSalary'] = sal;
    final r = await _api.post('/employees', body);
    JphBridge.remember(_s(r['code'], ''), _s(r['id'], ''));
    final pw = r['pin'] ?? r['temporaryPassword'];
    return _ok({
      'message': pw != null && (p['password'] ?? '').toString().isEmpty
          ? 'تمت إضافة الموظف ✅ — كلمة الدخول: $pw'
          : 'تمت إضافة الموظف بنجاح ✅',
      'uid': r['code'],
    });
  }

  static Future<Map<String, dynamic>> _updateEmployee(Map<String, dynamic> p) async {
    final id = await _id(p['uid']);
    final cur = ((await _api.get('/employees/$id'))['employee'] as Map).cast<String, dynamic>();
    final lf = ((cur['legacy_fields'] as Map?) ?? {}).cast<String, dynamic>();
    final body = <String, dynamic>{
      if ((p['name'] ?? '').toString().trim().length >= 2) 'fullName': p['name'].toString().trim(),
      if (p['phone'] != null) 'phone': p['phone'].toString().trim().isEmpty ? null : p['phone'].toString().trim(),
      if (p['email'] != null) 'email': p['email'].toString().trim().isEmpty ? null : p['email'].toString().trim(),
      if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch((p['joinDate'] ?? '').toString())) 'joiningDate': p['joinDate'],
      'legacyFields': {...lf, ..._legacyOf(p)},
      ..._orgFields(p),
    };
    final role = p['role'] == null ? null : roleKeyOf(p['role'].toString());
    final pos = (p['position'] ?? '').toString();
    if (pos.isNotEmpty) {
      if (pos != cur['position_key'] && id != JphBridge.myId) body['position'] = pos;
    } else if (role != null && role != cur['role_key'] && id != JphBridge.myId) {
      body['role'] = role;
    }
    await _api.patch('/employees/$id', body);
    // monthly salary = starting salary + increase (the form's "salary" box is read-only)
    final start = num.tryParse('${p['startSalary'] ?? ''}');
    final inc = num.tryParse('${p['increase'] ?? ''}') ?? 0;
    final sal = (start != null && start > 0) ? start + inc : num.tryParse('${p['salary'] ?? ''}');
    final curSal = num.tryParse('${(cur['salary'] as Map?)?['base_salary'] ?? ''}');
    if (sal != null && sal > 0 && sal != curSal && _has('employee.salary_manage') && id != JphBridge.myId) {
      await _api.put('/employees/$id/salary', {'baseSalary': sal});
    }
    return _ok({'message': 'تم تحديث بيانات الموظف بنجاح ✅'});
  }

  // ------------------------------------------------------------------ holidays
  static Map<String, dynamic> _holidayBody(Map<String, dynamic> p) => {
        'fromDate': _date(p['fromDate']),
        'toDate': _date(p['toDate'] ?? p['fromDate']),
        'holidayType': (p['holidayType'] ?? 'عطلة رسمية').toString(),
        'description': (p['description'] ?? '').toString(),
      };

  static Future<List<Map<String, dynamic>>> _holidayRows() async {
    return _list((await _api.get('/holiday-periods'))['periods']).map((h) => <String, dynamic>{
          'id': h['id'],
          'fromDate': _date(h['from_date']),
          'toDate': _date(h['to_date']),
          'holidayType': _s(h['holiday_type'], 'عطلة رسمية'),
          'description': _s(h['description'] ?? h['name'], ''),
          'days': h['days'] ?? 1,
        }).toList();
  }

  static Future<Map<String, dynamic>> _holidays(Object? year) async {
    var rows = await _holidayRows();
    final y = year?.toString();
    if (y != null && y.isNotEmpty) rows = rows.where((h) => h['fromDate'].toString().startsWith(y) || h['toDate'].toString().startsWith(y)).toList();
    return _ok({'holidays': rows, 'count': rows.length});
  }

  static Future<Map<String, dynamic>> _holidayStats() async {
    final rows = await _holidayRows();
    final y = DateTime.now().year;
    final byType = <String, int>{};
    final byMonth = <String, int>{};
    for (final h in rows) {
      byType[h['holidayType']] = (byType[h['holidayType']] ?? 0) + 1;
      final m = h['fromDate'].toString().length >= 7 ? h['fromDate'].toString().substring(5, 7) : '';
      byMonth[m] = (byMonth[m] ?? 0) + 1;
    }
    return _ok({'stats': {
      'total': rows.length,
      'thisYear': rows.where((h) => h['fromDate'].toString().startsWith('$y')).length,
      'nextYear': rows.where((h) => h['fromDate'].toString().startsWith('${y + 1}')).length,
      'byType': byType,
      'byMonth': byMonth,
    }});
  }

  // ------------------------------------------------------------------ notifications
  static Future<Map<String, dynamic>> _notifications() async {
    final r = await _api.get('/notifications');
    for (final n in _list(r['notifications'])) {
      if (n['entity_id'] != null) AlertCenter.entityOf['${n['id']}'] = '${n['entity_id']}';
    }
    final items = _list(r['notifications']).map((n) => <String, dynamic>{
          'id': n['id'],
          'notificationId': n['id'],
          'uid': JphBridge.myCode,
          'title': _s(n['title'], ''),
          'body': _s(n['body'], ''),
          'type': _s(n['type'], 'custom'),
          'read': n['read_at'] != null,
          'timestamp': _s(n['created_at'], DateTime.now().toIso8601String()),
          'createdAt': _s(n['created_at'], DateTime.now().toIso8601String()),
        }).toList();
    return _ok({'notifications': items, 'count': items.length, 'unread': r['unread'] ?? 0});
  }

  static Future<Map<String, dynamic>> _sendNotification(Map<String, dynamic> p) async {
    final raw = (p['recipients'] as List? ?? const []).map((e) => '$e').toList();
    // "الجميع" = everyone the sender may message (the server decides who that is)
    final all = raw.contains('الجميع');
    final ids = <String>[];
    if (!all) {
      for (final u in raw) {
        ids.add(await _id(u));
      }
    }
    final r = await _api.post('/notifications/send', {
      if (all) 'all': true else 'recipientIds': ids,
      'title': (p['title'] ?? '').toString(),
      'content': (p['content'] ?? '').toString(),
      'category': (p['category'] ?? 'عام').toString(),
    });
    return _ok({'message': 'تم إرسال الإشعار إلى ${r['sent']} موظف ✅'});
  }

  static Future<Map<String, dynamic>> _sentNotifications() async {
    final r = await _api.get('/notifications/sent');
    final items = _list(r['sent']).map((n) => <String, dynamic>{
          'id': n['batch'],
          'title': _s(n['title'], ''),
          'content': _s(n['body'], ''),
          'details': _s(n['body'], ''),
          'category': _s(n['category'], 'عام'),
          'sender': JphBridge.session.name,
          'recipient': _s(n['recipient_names'], ''),
          'date': _date(n['created_at']),
          'status': '${n['read']}/${n['recipients']} قرأ',
        }).toList();
    return _ok({'notifications': items, 'count': items.length});
  }

  // ------------------------------------------------------------------ reports
  /// حاضر / متأخر / بدون انصراف — an edited day keeps its real status; "تم التعديل بواسطة …" shows inside the card
  static String _dayStatus(Map<String, dynamic> d) {
    if (d['missingCheckout'] == true) return 'بدون انصراف';
    if (d['isLate'] == true) return 'متأخر';
    return 'حاضر';
  }

  static Future<Map<String, dynamic>> _dailyReport(Map<String, dynamic> p, {required bool expanded}) async {
    final id = await _id(p['uid']);
    final r = await _api.get('/attendance/range', {'employeeId': id, 'from': _date(p['from']), 'to': _date(p['to'])});
    final rows = _list(r['days']);
    final links = expanded ? await _links(selfies: rows.where((d) => d['hasSelfie'] == true).map((d) => _s(d['id'])).toList()) : <String, String>{};
    String loc(Object? lat, Object? lng) => lat == null || lng == null ? '--' : '$lat,$lng';
    final days = rows.map((d) {
      final status = _dayStatus(d);
      if (!expanded) {
        return <String, dynamic>{
          'date': _date(d['workDate']),
          'start': _time(d['checkIn'], '--'),
          'end': _time(d['checkOut'], '--'),
          'work': _hhmm(d['workedMinutes'] as num?),
          'late': _hhmm(d['lateMinutes'] as num?),
          'status': status,
        };
      }
      return <String, dynamic>{
        'date': _date(d['workDate']),
        'startTime': _time(d['checkIn'], '--'),
        'endTime': _time(d['checkOut'], '--'),
        'startImage': links['selfie:${d['id']}'] ?? '--',
        'endImage': '--',
        'startLocation': loc(d['checkInLat'], d['checkInLng']),
        'endLocation': loc(d['checkOutLat'], d['checkOutLng']),
        'workHours': _hhmm(d['workedMinutes'] as num?),
        'lateTime': _hhmm(d['lateMinutes'] as num?),
        'status': status,
        'projectName': (d['geofence'] == 'inside') ? 'داخل المكتب' : '--',
        'projectId': '--',
        'breakStart': _time(d['breakStart'], '--'),
        'breakEnd': _time(d['breakEnd'], '--'),
        'scheduleStart': _s((d['schedule'] as Map?)?['start'], '--').length >= 5 ? _s((d['schedule'] as Map?)?['start']).substring(0, 5) : '--',
        'scheduleEnd': _s((d['schedule'] as Map?)?['end'], '--').length >= 5 ? _s((d['schedule'] as Map?)?['end']).substring(0, 5) : '--',
        'outings': [
          for (final o in _list(d['outings']))
            {
              'kind': o['kind'],
              'label': o['kind'] == 'visit' ? 'زيارة' : 'إذن ساعات',
              'text': 'من ${_time(o['from'], '--')} لـ ${_time(o['expectedReturn'], '--')}'
                  '${o['returnedAt'] != null ? ' — رجع ${_time(o['returnedAt'], '--')}' : ''}',
            },
        ],
        'startForemanName': '--',
        'startForemanId': '--',
        'endForemanName': '--',
        'endForemanId': '--',
        'startCeoConfirm': d['corrected'] == true ? 'تم التعديل بواسطة ${_s(d['correctedByName'], 'الإدارة')}' : 'تلقائي',
        'endCeoConfirm': d['corrected'] == true ? 'تم التعديل بواسطة ${_s(d['correctedByName'], 'الإدارة')}' : 'تلقائي',
        'correctedBy': d['corrected'] == true ? _s(d['correctedByName'], 'الإدارة') : '',
        'workDate': _date(d['workDate']),
        'lateMinutes': '${d['lateMinutes'] ?? 0}',
      };
    }).toList();
    return _ok({'days': days, 'count': days.length});
  }

  static Future<Map<String, dynamic>> _monthlyReport(Map<String, dynamic> p) async {
    final id = await _id(p['uid']);
    final year = int.tryParse('${p['year']}') ?? DateTime.now().year;
    final month = '$year-${_two(_monthIndex(p['month']))}';
    final att = await _api.get('/attendance', {'month': month, 'employeeId': id});
    final sm = ((att['summary'] as Map?) ?? {}).cast<String, dynamic>();
    final days = _list(att['days']);
    Map<String, dynamic> pay = {};
    try {
      pay = (((await _api.get('/payroll/employee/$id', {'month': month}))['payroll']) as Map).cast<String, dynamic>();
    } catch (_) {/* no salary rights: attendance figures only */}
    num amt(String k) => (((pay[k] as Map?)?['amount']) as num?) ?? 0;
    final holidayAttend = days.where((d) => d['status'] == 'present' && d['holidayName'] != null).length;
    return _ok({'report': {
      'workDays': sm['attendedDays'] ?? 0,
      'holidayAttend': holidayAttend,
      'holidays': days.where((d) => d['status'] == 'holiday' || d['status'] == 'weekend').length,
      'sick': days.where((d) => d['absenceType'] == 'sick').length,
      'absent': sm['unapprovedAbsenceDays'] ?? 0,
      'lateHours': _hhmm(sm['lateMinutes'] as num?),
      'lateAmount': amt('late'),
      'attendSalary': pay['attendanceSalary'] ?? pay['baseSalary'] ?? 0,
      'allowance': 0,
      'bonus': pay['bonuses'] ?? 0,
      // عمولة المبيعات: approved deal commissions of this payroll month (salesperson / sales manager share)
      'commissions': pay['commissions'] ?? 0,
      'workExpenses': pay['workExpenses'] ?? 0,
      // خصومات = only what was recorded on the علاوة / خصم page (late / absence have their own boxes)
      'deduction': (pay['adminDeductions'] as num?) ?? 0,
      'absentDeduction': amt('absence') + amt('unpaid'),
      'advance': pay['advances'] ?? 0,
      'received': ((pay['salaryPaid'] as num?) ?? 0) + ((pay['commissionPaid'] as num?) ?? 0),
      'dueSalary': pay['net'] ?? 0,
      'arrears': pay['arrears'] ?? 0, // still owed from earlier months only
    }});
  }

  static Future<List<Map<String, dynamic>>> _boardRows() async {
    final r = await _api.get('/attendance/board');
    return _list(r['board']);
  }

  static Future<Map<String, dynamic>> _todayStats() async {
    final rows = await _boardRows();
    final present = rows.where((x) => x['attendance'] != null).length;
    return _ok({'stats': {
      'totalEmployees': rows.length,
      'presentCount': present,
      'absentCount': rows.length - present,
      'onBreakCount': rows.where((x) => (x['break'] as Map?)?['onBreak'] == true).length,
    }});
  }

  static Future<Map<String, dynamic>> _byTeam() async {
    final rows = await _boardRows();
    final by = <String, int>{};
    for (final x in rows.where((x) => x['attendance'] != null)) {
      final team = _s(x['teamName'], 'بدون فريق');
      by[team] = (by[team] ?? 0) + 1;
    }
    return _ok({'projects': [for (final e in by.entries) {'projectName': e.key, 'attendanceCount': e.value}]});
  }

  /// Employees out right now on an approved permission / visit (replaces "on break").
  static Future<Map<String, dynamic>> _outNow() async {
    final now = DateTime.now();
    final r = await _api.get('/outings', {'status': 'out', 'date': _ymd(now)});
    final out = <Map<String, dynamic>>[];
    for (final x in _list(r['outings'])) {
      final from = _dt(x['starts_at'] ?? x['requested_at']);
      final back = _dt(x['expected_return_at']);
      out.add({
        'id': x['employee_id'],
        'name': _s(x['employee_name']),
        'project': '${x['kind'] == 'visit' ? 'زيارة' : 'إذن ساعات'} — الرجوع ${_time(x['expected_return_at'])}',
        'breakStart': _time(x['starts_at'] ?? x['requested_at']),
        'breakDuration': from == null ? '--' : '${now.difference(from).inMinutes} دقيقة',
        'breakExceeded': back != null && back.isBefore(now),
      });
    }
    return _ok({'employees': out, 'count': out.length});
  }

  /// filter: present (checked in) · late · absent (no check-in yet).
  static Future<Map<String, dynamic>> _board({required bool onBreakOnly, String filter = 'present'}) async {
    final rows = await _boardRows();
    final out = <Map<String, dynamic>>[];
    for (final x in rows) {
      final a = (x['attendance'] as Map?)?.cast<String, dynamic>();
      final b = (x['break'] as Map?)?.cast<String, dynamic>();
      if (filter == 'absent') {
        if (a != null) continue;
        out.add({'id': x['employeeId'], 'name': _s(x['fullName']), 'project': _s(x['teamName'], 'بدون فريق'),
          'checkIn': '--:--', 'checkOut': '--:--', 'status': 'absent', 'breakStart': '--:--', 'breakDuration': '--', 'breakExceeded': false});
        continue;
      }
      if (a == null) continue;
      if (filter == 'late' && a['isLate'] != true) continue;
      if (onBreakOnly && b?['onBreak'] != true) continue;
      out.add({
        'id': x['employeeId'],
        'name': _s(x['fullName']),
        'project': _s(x['teamName'], 'بدون فريق'),
        'checkIn': _time(a['checkIn']),
        'checkOut': a['checkOut'] == null ? '--:--' : _time(a['checkOut']),
        'status': a['checkOut'] == null ? 'present' : 'left',
        'breakStart': b == null ? '--:--' : _time(b['start']),
        'breakDuration': b == null ? '--' : '${b['minutes']} دقيقة',
        'breakExceeded': b?['exceeded'] == true,
      });
    }
    return _ok({'employees': out, 'count': out.length});
  }
}
