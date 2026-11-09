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
  const CustodyReceiptPage({super.key});

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
                JphUi.header(context, isDark: isDark, isRTL: true, title: 'استمارة استلام عهدة'),
                Expanded(
                  child: SwipeTabs(
                    isDark: isDark,
                    tabs: [
                      if (canUse) ('استمارة جديدة', Icons.note_add_rounded),
                      ('الاستمارات السابقة', Icons.folder_open_rounded),
                    ],
                    pages: [
                      if (canUse) _NewReceipt(isDark: isDark),
                      _History(isDark: isDark),
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
  const _NewReceipt({required this.isDark});

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
        selected: _employeeId, icon: Icons.badge_rounded);
    if (v == null) return;
    setState(() {
      _employeeId = v;
      _loadingPrefill = true;
    });
    final r = await _get('/forms/custody-receipt/prefill/$v');
    if (!mounted) return;
    final p = (r['prefill'] as Map?) ?? const {};
    setState(() {
      _loadingPrefill = false;
      _name.text = '${p['employeeName'] ?? ''}';
      _code.text = '${p['employeeCode'] ?? ''}';
      _job.text = '${p['jobTitle'] ?? ''}';
      _dept.text = '${p['department'] ?? ''}';
      _manager.text = '${p['directManager'] ?? ''}';
      _signName.text = _name.text;
    });
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
        'phoneBrand': _brand.text.trim(), 'imei': _imei.text.trim(), 'lineNumber': _line.text.trim(),
        'condition': _condition, 'conditionOther': _condition == 'other' ? _condOther.text.trim() : '',
        'accessories': _acc.toList(), 'accessoriesOther': _acc.contains('other') ? _accOther.text.trim() : '',
        'signEmployeeName': _signName.text.trim(), 'signDate': _iso(_signDate),
        'custodianName': _custodian.text.trim(), 'hrName': _hr.text.trim(),
      };

  Future<void> _save() async {
    String? err;
    if (_employeeId == null) {
      err = 'اختار الموظف';
    } else if (_name.text.trim().isEmpty) {
      err = 'اكتب اسم الموظف';
    } else if (_brand.text.trim().isEmpty) {
      err = 'اكتب نوع / ماركة الهاتف';
    } else if (_imei.text.trim().isEmpty) {
      err = 'اكتب رقم الجهاز / IMEI';
    } else if (_condition == 'other' && _condOther.text.trim().isEmpty) {
      err = 'اكتب حالة الجهاز';
    } else if (_acc.contains('other') && _accOther.text.trim().isEmpty) {
      err = 'اكتب الملحقات الأخرى';
    }
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err), backgroundColor: Colors.red));
      return;
    }
    setState(() => _saving = true);
    final r = await _post('/forms/custody-receipts', {'employeeId': _employeeId, 'data': _data}, ok: 'اتحفظت الاستمارة ✅');
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
      _title('أولًا: بيانات الموظف'),
      JphUi.picker(
        isDark: isDark, icon: Icons.badge_rounded, iconColor: Colors.teal, label: 'الموظف *',
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
      JphUi.picker(isDark: isDark, icon: Icons.event_rounded, iconColor: Colors.orange, label: 'تاريخ استلام العهدة',
          value: _show(_iso(_receiptDate)), onTap: () => _pickDate(true)),
      _title('ثانيًا: بيانات الهاتف المحمول'),
      JphUi.input(isDark: isDark, label: 'نوع / الماركة *', controller: _brand, icon: Icons.phone_android_rounded, big: false),
      _gap(),
      JphUi.input(isDark: isDark, label: 'رقم الجهاز / IMEI *', controller: _imei, icon: Icons.qr_code_rounded, number: true, big: false),
      _gap(),
      JphUi.input(isDark: isDark, label: 'رقم الخط', controller: _line, icon: Icons.sim_card_rounded, number: true, big: false),
      _gap(),
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
        _check('case', 'جراب'),
        _check('headset', 'سماعة'),
        _check('other', 'أخرى'),
      ]),
      if (_acc.contains('other')) ...[
        _gap(),
        JphUi.input(isDark: isDark, label: 'أخرى: (اكتب الملحقات) *', controller: _accOther, icon: Icons.edit_note_rounded, big: false),
      ],
      _title('سادسًا: الإقرار والتوقيعات'),
      JphUi.input(isDark: isDark, label: 'اسم الموظف (في الإقرار)', controller: _signName, icon: Icons.person_rounded, big: false),
      _gap(),
      JphUi.picker(isDark: isDark, icon: Icons.event_available_rounded, iconColor: Colors.teal, label: 'التاريخ',
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
  const _History({required this.isDark});

  @override
  State<_History> createState() => _HistoryState();
}

class _HistoryState extends State<_History> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _get('/forms/custody-receipts');
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = cashList(r, 'receipts');
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
                JphUi.iconTile(isDark, Icons.description_rounded, Colors.indigo),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${x['title']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    Text('${x['employeeName'] ?? ''} • ${(x['data'] as Map?)?['phoneBrand'] ?? ''} • ${_show('${(x['data'] as Map?)?['receiptDate'] ?? ''}')}',
                        style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                    Text('سجلها: ${x['createdByName'] ?? ''}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                  ]),
                ),
                Icon(Icons.print_rounded, color: JphUi.primary(isDark)),
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
                  build: (_) => buildCustodyReceiptPdf(data, version: version),
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
