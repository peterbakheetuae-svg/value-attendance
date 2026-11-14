import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../pages/cash/cash_page.dart' show cashList;
import '../services/api_service.dart';
import '../services/app_controller.dart';
import '../widgets/app_background.dart';
import '../widgets/jph_form_ui.dart';
import '../widgets/swipe_tabs.dart';
import 'custody_receipt_pdf.dart';
import 'form_delete.dart';
import '../widgets/glass_ui.dart';

Future<Map<String, dynamic>> _get(String path, [Map<String, dynamic> q = const {}]) =>
    ApiService.post({'action': 'cash_get', 'path': path, 'query': q});
Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body, {String? ok}) =>
    ApiService.post({'action': 'cash_post', 'path': path, 'body': body, 'ok': ok});

String _iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String _show(String iso) {
  final d = DateTime.tryParse(iso);
  return d == null ? '--' : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

/// الإعدادات ← استمارات ← استمارة استلام عهدة.
/// Tabs: استمارة جديدة (the original's fields, employee data filled from the system) | الاستمارات السابقة (reopen / print).
class CustodyReceiptPage extends StatelessWidget {
  /// mobile | laptop — استمارات ← استمارة استلام عهدة ← موبايل / كمبيوتر محمول
  final String device;
  const CustodyReceiptPage({super.key, this.device = 'mobile'});

  String get title => device == 'laptop' ? 'استلام عهدة — كمبيوتر محمول' : 'استلام عهدة — موبايل';

  static bool get canUse => ApiService.can('documents.manage') || ApiService.can('employee.manage');

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(builder: (context, app, _) {
      final isDark = app.isDark;
      return AppBackground(
        child: Directionality(
          textDirection: ui.TextDirection.rtl,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(children: [
                JphUi.header(context, isDark: isDark, isRTL: true, title: title),
                Expanded(
                  child: SwipeTabs(
                    isDark: isDark,
                    tabs: [
                      if (canUse) ('استمارة جديدة', Icons.note_add_rounded),
                      ('الاستمارات السابقة', Icons.folder_open_rounded),
                    ],
                    pages: [
                      if (canUse) _NewReceipt(isDark: isDark, device: device),
                      _History(isDark: isDark, device: device),
                    ],
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
    });
  }
}

// ============================================================================ new receipt
class _NewReceipt extends StatefulWidget {
  final bool isDark;
  final String device;
  const _NewReceipt({required this.isDark, required this.device});

  @override
  State<_NewReceipt> createState() => _NewReceiptState();
}

class _NewReceiptState extends State<_NewReceipt> {
  List<Map<String, dynamic>> _people = [];
  String? _employeeId;
  bool _loadingPrefill = false, _saving = false;
  DateTime _receiptDate = DateTime.now(), _signDate = DateTime.now();
  String _condition = 'new';
  final Set<String> _acc = {};
  /// the employee's custody of this kind (handed from Settings → العهدة)
  List<Map<String, dynamic>> _items = [];
  String? _itemId;
  bool get _laptop => widget.device == 'laptop';

  final _name = TextEditingController(), _code = TextEditingController(), _job = TextEditingController(),
      _dept = TextEditingController(), _manager = TextEditingController(), _brand = TextEditingController(),
      _imei = TextEditingController(), _line = TextEditingController(), _condOther = TextEditingController(),
      _accOther = TextEditingController(), _signName = TextEditingController(), _custodian = TextEditingController(),
      _hr = TextEditingController();

  List<TextEditingController> get _all =>
      [_name, _code, _job, _dept, _manager, _brand, _imei, _line, _condOther, _accOther, _signName, _custodian, _hr];

  @override
  void initState() {
    super.initState();
    _loadPeople();
  }

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadPeople() async {
    final r = await ApiService.post({'action': 'getActiveEmployees'});
    if (!mounted) return;
    setState(() => _people = ((r['employees'] as List?) ?? const []).whereType<Map>()
        .map((m) => <String, dynamic>{'id': '${m['id']}', 'name': '${m['name']}'}).toList());
  }

  Future<void> _pickEmployee() async {
    final v = await JphUi.sheet<String>(context, widget.isDark, 'اختار الموظف',
        [for (final p in _people) ('${p['id']}', '${p['name']}', Icons.person_outline_rounded)],
        selected: _employeeId, icon: Icons.badge_rounded, people: true);
    if (v == null) return;
    setState(() {
      _employeeId = v;
      _loadingPrefill = true;
    });
    final r = await _get('/forms/custody-receipt/prefill/$v', {'device': widget.device});
    if (!mounted) return;
    final p = (r['prefill'] as Map?) ?? const {};
    setState(() {
      _loadingPrefill = false;
      _items = cashList(r, 'items');
      _itemId = null;
      if (_items.length == 1) _useItem(_items.first);
      _name.text = '${p['employeeName'] ?? ''}';
      _code.text = '${p['employeeCode'] ?? ''}';
      _job.text = '${p['jobTitle'] ?? ''}';
      _dept.text = '${p['department'] ?? ''}';
      _manager.text = '${p['directManager'] ?? ''}';
      _signName.text = _name.text;
    });
  }

  /// fills the device part from one of the employee's custody items
  void _useItem(Map<String, dynamic> it) {
    _itemId = '${it['id']}';
    _brand.text = '${it['name'] ?? ''}';
    _imei.text = '${it['serialNo'] ?? ''}';
    if (!_laptop) _line.text = '${it['lineNumber'] ?? ''}';
    final c = '${it['condition'] ?? ''}';
    if (const ['new', 'used_good', 'other'].contains(c)) _condition = c;
    final allowed = _laptop ? const {'charger', 'cable', 'other'} : const {'charger', 'cable', 'case', 'headset', 'other'};
    _acc
      ..clear()
      ..addAll(((it['accessories'] as List?) ?? const []).map((e) => '$e').where(allowed.contains));
    final d = DateTime.tryParse('${it['assignedOn'] ?? ''}');
    if (d != null) _receiptDate = d;
  }

  Future<void> _pickDate(bool receipt) async {
    final d = await showDatePicker(
      context: context,
      initialDate: receipt ? _receiptDate : _signDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2040),
      locale: const Locale('ar'),
    );
    if (d != null) setState(() => receipt ? _receiptDate = d : _signDate = d);
  }

  Map<String, dynamic> get _data => {
        'employeeName': _name.text.trim(), 'employeeCode': _code.text.trim(), 'jobTitle': _job.text.trim(),
        'department': _dept.text.trim(), 'directManager': _manager.text.trim(), 'receiptDate': _iso(_receiptDate),
        if (_laptop) ...{'brand': _brand.text.trim(), 'serialNo': _imei.text.trim()}
        else ...{'phoneBrand': _brand.text.trim(), 'imei': _imei.text.trim(), 'lineNumber': _line.text.trim()},
        'condition': _condition, 'conditionOther': _condition == 'other' ? _condOther.text.trim() : '',
        'accessories': _acc.toList(), 'accessoriesOther': _acc.contains('other') ? _accOther.text.trim() : '',
        'signEmployeeName': _signName.text.trim(), 'signDate': _iso(_signDate),
        'custodianName': _custodian.text.trim(), 'hrName': _hr.text.trim(),
      };

  Future<void> _save() async {
    String? err;
    if (_employeeId == null) {
      err = 'اختار الموظف';
    } else if (_itemId == null) {
      err = 'اختار العهدة المسلَّمة للموظف';
    } else if (_name.text.trim().isEmpty) {
      err = 'اكتب اسم الموظف';
    } else if (_brand.text.trim().isEmpty) {
      err = 'العهدة دي مالهاش نوع / ماركة';
    } else if (_imei.text.trim().isEmpty) {
      err = _laptop ? 'العهدة دي متسجلة من غير سريل / SN — ضيفها تاني في الإعدادات ← العهدة بالسريل' : 'العهدة دي متسجلة من غير IMEI — ضيفها تاني في الإعدادات ← العهدة بالـ IMEI';
    } else if (_condition == 'other' && _condOther.text.trim().isEmpty) {
      err = 'اكتب حالة الجهاز';
    } else if (_acc.contains('other') && _accOther.text.trim().isEmpty) {
      err = 'اكتب الملحقات الأخرى';
    }
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err), backgroundColor: Ar.red));
      return;
    }
    setState(() => _saving = true);
    final r = await _post('/forms/custody-receipts', {'employeeId': _employeeId, 'device': widget.device, 'data': _data},
        ok: 'اتحفظت الاستمارة ✅');
    if (!mounted) return;
    setState(() => _saving = false);
    JphUi.toast(context, r);
    if (r['success'] == true && r['receipt'] is Map) {
      final rec = (r['receipt'] as Map).cast<String, dynamic>();
      for (final c in _all) {
        c.clear();
      }
      setState(() {
        _employeeId = null;
        _acc.clear();
        _condition = 'new';
        _items = [];
        _itemId = null;
      });
      await Navigator.push(context, MaterialPageRoute(builder: (_) => CustodyReceiptPreview(receipt: rec)));
    }
  }

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 10),
        child: Text(t, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(widget.isDark))),
      );

  Widget _gap() => const SizedBox(height: 12);

  Widget _check(String key, String label) {
    final on = _acc.contains(key);
    return FilterChip(
      selected: on,
      onSelected: (v) => setState(() => v ? _acc.add(key) : _acc.remove(key)),
      label: Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: on ? Colors.white : JphUi.text(widget.isDark))),
      selectedColor: JphUi.primary(widget.isDark),
      checkmarkColor: Colors.white,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final who = _people.where((p) => p['id'] == _employeeId).map((p) => '${p['name']}').firstOrNull;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
      _title('أولاً: بيانات الموظف'),
      JphUi.picker(
        isDark: isDark, icon: Icons.badge_rounded, iconColor: Ar.green, label: 'الموظف *',
        value: _loadingPrefill ? 'جاري تحميل بياناته...' : (who ?? 'اختار الموظف — بياناته بتتملي لوحدها'),
        onTap: _pickEmployee,
      ),
      _gap(),
      JphUi.input(isDark: isDark, label: 'اسم الموظف *', controller: _name, icon: Icons.person_rounded, big: false),
      _gap(),
      Row(children: [
        Expanded(child: JphUi.input(isDark: isDark, label: 'الرقم الوظيفي', controller: _code, icon: Icons.tag_rounded, big: false)),
        const SizedBox(width: 12),
        Expanded(child: JphUi.input(isDark: isDark, label: 'المسمى الوظيفي', controller: _job, icon: Icons.work_rounded, big: false)),
      ]),
      _gap(),
      JphUi.input(isDark: isDark, label: 'القسم / الإدارة', controller: _dept, icon: Icons.apartment_rounded, big: false),
      _gap(),
      JphUi.input(isDark: isDark, label: 'المدير المباشر', controller: _manager, icon: Icons.supervisor_account_rounded, big: false),
      _gap(),
      JphUi.picker(isDark: isDark, icon: Icons.event_rounded, iconColor: Ar.amber, label: 'تاريخ استلام العهدة',
          value: _show(_iso(_receiptDate)), onTap: () => _pickDate(true)),
      _title(_laptop ? 'ثانياً: بيانات كمبيوتر محمول' : 'ثانياً: بيانات الهاتف المحمول'),
      if (_employeeId != null) ...[
        JphUi.picker(
          isDark: isDark, icon: Icons.inventory_2_rounded, iconColor: Ar.accent, label: 'العهدة المسلَّمة للموظف',
          value: _items.isEmpty
              ? 'مفيش ${_laptop ? 'لابتوب' : 'موبايل'} مسلَّم له — سلّمه من صفحة الموظف'
              : '${(_items.where((x) => '${x['id']}' == _itemId).firstOrNull ?? const {})['name'] ?? 'اختار العهدة'}',
          onTap: _items.isEmpty
              ? null
              : () async {
                  final v = await JphUi.sheet<String>(context, isDark, 'العهدة', [
                    for (final it in _items)
                      ('${it['id']}', '${it['name']}${'${it['serialNo']}'.isEmpty ? '' : ' — ${it['serialNo']}'}',
                          _laptop ? Icons.laptop_rounded : Icons.phone_android_rounded),
                  ], selected: _itemId, icon: Icons.inventory_2_rounded);
                  if (v != null) setState(() => _useItem(_items.firstWhere((x) => '${x['id']}' == v)));
                },
        ),
        _gap(),
      ],
      // the device data comes from the chosen custody item only (Settings → العهدة) — not typed by hand
      if (_itemId != null) ...[
        JphUi.readOnly(isDark: isDark, label: 'نوع / الماركة', value: _brand.text,
            icon: _laptop ? Icons.laptop_rounded : Icons.phone_android_rounded, color: Ar.accent),
        _gap(),
        JphUi.readOnly(isDark: isDark, label: _laptop ? 'سريل الجهاز / SN' : 'رقم الجهاز / IMEI', value: _imei.text.isEmpty ? '—' : _imei.text,
            icon: Icons.qr_code_rounded, color: Ar.accent),
        _gap(),
        if (!_laptop) ...[
          JphUi.readOnly(isDark: isDark, label: 'رقم الخط', value: _line.text.isEmpty ? '—' : _line.text, icon: Icons.sim_card_rounded, color: Ar.accent),
          _gap(),
        ],
      ],
      Text('حالة الجهاز عند التسليم', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
      const SizedBox(height: 8),
      JphUi.tabs(isDark, const [('جديد', Icons.fiber_new_rounded), ('مستعمل بحالة جيدة', Icons.thumb_up_rounded), ('أخرى', Icons.more_horiz_rounded)],
          ['new', 'used_good', 'other'].indexOf(_condition), (i) => setState(() => _condition = ['new', 'used_good', 'other'][i])),
      if (_condition == 'other') ...[
        _gap(),
        JphUi.input(isDark: isDark, label: 'أخرى: (اكتب الحالة) *', controller: _condOther, icon: Icons.edit_note_rounded, big: false),
      ],
      _gap(),
      Text('الملحقات المسلمة', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _check('charger', 'الشاحن'),
        _check('cable', 'كابل الشحن'),
        if (!_laptop) _check('case', 'جراب'),
        if (!_laptop) _check('headset', 'سماعة'),
        _check('other', 'أخرى'),
      ]),
      if (_acc.contains('other')) ...[
        _gap(),
        JphUi.input(isDark: isDark, label: 'أخرى: (اكتب الملحقات) *', controller: _accOther, icon: Icons.edit_note_rounded, big: false),
      ],
      _title('سادساً: الإقرار والتوقيعات'),
      JphUi.input(isDark: isDark, label: 'اسم الموظف (في الإقرار)', controller: _signName, icon: Icons.person_rounded, big: false),
      _gap(),
      JphUi.picker(isDark: isDark, icon: Icons.event_available_rounded, iconColor: Ar.green, label: 'التاريخ',
          value: _show(_iso(_signDate)), onTap: () => _pickDate(false)),
      _gap(),
      JphUi.input(isDark: isDark, label: 'مسؤول العهدة / IT', controller: _custodian, icon: Icons.computer_rounded, big: false),
      _gap(),
      JphUi.input(isDark: isDark, label: 'HR', controller: _hr, icon: Icons.groups_rounded, big: false),
      _gap(),
      Text('التوقيعات بتتعمل بخط اليد على الورقة بعد الطباعة. بنود "الغرض" و"الالتزامات" و"الأحكام العامة" بتطلع زي الأصل بالظبط.',
          style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
      const SizedBox(height: 16),
      SizedBox(
        height: 58,
        child: ElevatedButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.save_rounded),
          label: const Text('حفظ ومعاينة الطباعة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          style: ElevatedButton.styleFrom(backgroundColor: JphUi.primary(isDark), foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
        ),
      ),
    ]);
  }
}

// ============================================================================ earlier receipts
class _History extends StatefulWidget {
  final bool isDark;
  final String device;
  const _History({required this.isDark, required this.device});

  @override
  State<_History> createState() => _HistoryState();
}

class _HistoryState extends State<_History> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  bool _canDelete = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _get('/forms/custody-receipts', {'device': widget.device});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = cashList(r, 'receipts');
      _canDelete = r['canDelete'] == true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        if (!_loading && _items.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text('لسه مفيش استمارات', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final x in _items)
          GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CustodyReceiptPreview(receipt: x))),
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: JphUi.box(isDark),
              child: Row(children: [
                JphUi.iconTile(isDark, Icons.description_rounded, Ar.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${x['title']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    Text('${x['employeeName'] ?? ''} • ${(x['data'] as Map?)?['phoneBrand'] ?? (x['data'] as Map?)?['brand'] ?? ''} • ${_show('${(x['data'] as Map?)?['receiptDate'] ?? ''}')}',
                        style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                    Text('سجلها: ${x['createdByName'] ?? ''}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                  ]),
                ),
                Icon(Icons.print_rounded, color: JphUi.primary(isDark)),
                if (_canDelete)
                  formDeleteButton(() async {
                    if (await deleteFormRecord(context, '${x['id']}', '${x['title']}')) _load();
                  }),
              ]),
            ),
          ),
      ]),
    );
  }
}

// ============================================================================ preview / print / PDF
/// Shows the filled original and prints it at its own page size (Letter), 100% — no browser scaling.
class CustodyReceiptPreview extends StatelessWidget {
  final Map<String, dynamic> receipt;
  const CustodyReceiptPreview({super.key, required this.receipt});

  @override
  Widget build(BuildContext context) {
    final isDark = context.read<AppController>().isDark;
    final data = ((receipt['data'] as Map?) ?? const {}).cast<String, dynamic>();
    final version = (receipt['templateVersion'] as num?)?.toInt() ?? CustodyReceiptTemplate.latestVersion;
    final name = 'استمارة استلام عهدة ${receipt['number'] ?? ''} - ${data['employeeName'] ?? ''}';
    return AppBackground(
      child: Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Column(children: [
              JphUi.header(context, isDark: isDark, isRTL: true, title: '${receipt['title'] ?? 'استمارة استلام عهدة'}'),
              Expanded(
                child: PdfPreview(
                  build: (_) => buildCustodyReceiptPdf(data, version: version,
                      template: '${receipt['template'] ?? 'custody_receipt'}' == 'laptop_receipt' ? 'laptop_receipt' : 'custody_receipt'),
                  initialPageFormat: PdfPageFormat.letter,
                  canChangePageFormat: false,
                  canChangeOrientation: false,
                  canDebug: false,
                  allowSharing: true,
                  allowPrinting: true,
                  pdfFileName: '$name.pdf',
                  dynamicLayout: false,
                  actionBarTheme: PdfActionBarTheme(backgroundColor: JphUi.primary(isDark), iconColor: Colors.white),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
