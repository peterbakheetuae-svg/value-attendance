import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../pages/cash/cash_page.dart' show cashList;
import '../services/api_service.dart';
import '../services/app_controller.dart';
import '../services/jph_bridge.dart';
import '../widgets/app_background.dart';
import '../widgets/jph_form_ui.dart';
import '../widgets/swipe_tabs.dart';
import 'custody_receipt_pdf.dart';
import 'form_delete.dart';

/// الإعدادات ← استمارات ← استمارات عملاء ← استمارة تعارف.
/// Every employee can fill it. "اسم مسؤول المبيعات" is the employee who fills it (automatic); HR / the management
/// may file it for a sales person they pick. Printed on the approved original (template client_intro v1).
class ClientIntroPage extends StatelessWidget {
  const ClientIntroPage({super.key});

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
                JphUi.header(context, isDark: isDark, isRTL: true, title: 'استمارة تعارف'),
                Expanded(
                  child: SwipeTabs(
                    isDark: isDark,
                    tabs: const [('استمارة جديدة', Icons.note_add_rounded), ('الاستمارات السابقة', Icons.folder_open_rounded)],
                    pages: [_NewForm(isDark: isDark), _History(isDark: isDark)],
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

const clientPropertyTypes = {
  'residential': 'سكني',
  'commercial': 'تجاري',
  'residential_2': 'سكني',
  'administrative': 'إداري',
  'medical': 'طبي',
  'operational': 'تشغيل',
  'other': 'أخرى',
};

String _iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Future<void> _print(BuildContext context, Map<String, dynamic> f) async {
  final data = ((f['data'] as Map?) ?? const {}).cast<String, dynamic>();
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text('استمارة تعارف رقم ${f['number'] ?? ''}')),
        body: PdfPreview(
          build: (_) => buildCustodyReceiptPdf(data, version: (f['templateVersion'] as num?)?.toInt() ?? 1, template: 'client_intro'),
          initialPageFormat: PdfPageFormat.a4,
          canChangePageFormat: false,
          canChangeOrientation: false,
          canDebug: false,
          pdfFileName: 'client-intro-${f['number'] ?? ''}.pdf',
        ),
      ),
    ),
  );
}

class _NewForm extends StatefulWidget {
  final bool isDark;
  const _NewForm({required this.isDark});

  @override
  State<_NewForm> createState() => _NewFormState();
}

class _NewFormState extends State<_NewForm> {
  final _client = TextEditingController(), _phone = TextEditingController(), _whatsapp = TextEditingController(),
      _job = TextEditingController(), _residence = TextEditingController(), _other = TextEditingController();
  DateTime _date = DateTime.now();
  final Set<String> _types = {};
  bool _saving = false;
  // HR / the management may pick the sales person; an employee is always the sales person himself
  bool get _canPick => ApiService.can('documents.manage') || ApiService.can('employee.manage');
  List<Map<String, dynamic>> _employees = [];
  String? _salesId;
  String _salesName = JphBridge.session.name;

  @override
  void initState() {
    super.initState();
    if (_canPick) {
      ApiService.post({'action': 'getActiveEmployees'}).then((r) {
        if (!mounted) return;
        setState(() => _employees = ((r['employees'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList());
      });
    }
  }

  Future<void> _save() async {
    String? err;
    if (_client.text.trim().isEmpty) {
      err = 'اكتب اسم العميل';
    } else if (!RegExp(r'^\+?\d{7,15}$').hasMatch(_phone.text.replaceAll(' ', ''))) {
      err = 'اكتب رقم هاتف صحيح';
    } else if (_whatsapp.text.trim().isNotEmpty && !RegExp(r'^\+?\d{7,15}$').hasMatch(_whatsapp.text.replaceAll(' ', ''))) {
      err = 'اكتب رقم واتساب صحيح';
    } else if (_types.contains('other') && _other.text.trim().isEmpty) {
      err = 'اكتب نوع العقار التاني';
    }
    if (err != null) {
      JphUi.toast(context, {'success': false, 'message': err});
      return;
    }
    setState(() => _saving = true);
    final r = await ApiService.post({
      'action': 'cash_post', 'path': '/forms/client-intros', 'ok': 'اتحفظت الاستمارة ✅',
      'body': {
        if (_salesId != null) 'salesEmployeeId': _salesId,
        'data': {
          'date': _iso(_date), 'clientName': _client.text.trim(), 'phone': _phone.text.replaceAll(' ', ''),
          'whatsapp': _whatsapp.text.replaceAll(' ', ''), 'job': _job.text.trim(), 'residence': _residence.text.trim(),
          'propertyTypes': _types.toList(), 'propertyOther': _other.text.trim(),
        },
      },
    });
    if (!mounted) return;
    setState(() => _saving = false);
    JphUi.toast(context, r);
    if (r['success'] == true) {
      final f = ((r['form'] as Map?) ?? const {}).cast<String, dynamic>();
      for (final c in [_client, _phone, _whatsapp, _job, _residence, _other]) {
        c.clear();
      }
      setState(() => _types.clear());
      if (f.isNotEmpty && mounted) _print(context, f);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    Widget gap() => const SizedBox(height: 14);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 60), children: [
      JphUi.picker(
        isDark: isDark, icon: Icons.event_rounded, iconColor: Colors.indigo, label: 'التاريخ',
        value: '${_date.day.toString().padLeft(2, '0')}/${_date.month.toString().padLeft(2, '0')}/${_date.year}',
        onTap: () async {
          final d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2024), lastDate: DateTime(2100));
          if (d != null) setState(() => _date = d);
        },
      ),
      gap(),
      if (_canPick)
        JphUi.picker(
          isDark: isDark, icon: Icons.support_agent_rounded, iconColor: Colors.teal, label: 'اسم مسؤول المبيعات',
          value: _salesName,
          onTap: _employees.isEmpty
              ? null
              : () async {
                  final v = await JphUi.sheet<String>(context, isDark, 'مسؤول المبيعات',
                      [for (final e in _employees) ('${e['id']}', '${e['name']}', Icons.person_outline_rounded)],
                      selected: _salesId, icon: Icons.support_agent_rounded);
                  if (v == null) return;
                  setState(() {
                    _salesId = v;
                    _salesName = '${_employees.firstWhere((e) => '${e['id']}' == v)['name']}';
                  });
                },
        )
      else
        JphUi.readOnly(isDark: isDark, label: 'اسم مسؤول المبيعات', value: _salesName, icon: Icons.support_agent_rounded, color: Colors.teal),
      gap(),
      Text('بيانات العميل', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
      const SizedBox(height: 10),
      JphUi.input(isDark: isDark, label: 'اسم العميل *', controller: _client, icon: Icons.person_rounded, big: false),
      gap(),
      JphUi.input(isDark: isDark, label: 'رقم الهاتف *', controller: _phone, icon: Icons.phone_rounded, number: true, big: false),
      gap(),
      JphUi.input(isDark: isDark, label: 'رقم الواتساب', controller: _whatsapp, icon: Icons.chat_rounded, number: true, big: false),
      gap(),
      JphUi.input(isDark: isDark, label: 'الوظيفة / مجال العمل', controller: _job, icon: Icons.work_outline_rounded, big: false),
      gap(),
      JphUi.input(isDark: isDark, label: 'محل الإقامة', controller: _residence, icon: Icons.home_rounded, big: false),
      gap(),
      Text('ما نوع العقار الذي تبحث عنه والغرض منه؟', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final e in clientPropertyTypes.entries)
          FilterChip(
            selected: _types.contains(e.key),
            onSelected: (v) => setState(() => v ? _types.add(e.key) : _types.remove(e.key)),
            label: Text(e.value, style: TextStyle(fontWeight: FontWeight.w700, color: _types.contains(e.key) ? Colors.white : JphUi.text(isDark))),
            selectedColor: JphUi.primary(isDark),
            checkmarkColor: Colors.white,
          ),
      ]),
      if (_types.contains('other')) ...[
        gap(),
        JphUi.input(isDark: isDark, label: 'أخرى *', controller: _other, icon: Icons.edit_note_rounded, big: false),
      ],
      const SizedBox(height: 20),
      SizedBox(
        height: 54,
        child: ElevatedButton.icon(
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.save_rounded),
          label: const Text('حفظ وطباعة', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          style: ElevatedButton.styleFrom(backgroundColor: JphUi.primary(isDark), foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
        ),
      ),
    ]);
  }
}

class _History extends StatefulWidget {
  final bool isDark;
  const _History({required this.isDark});

  @override
  State<_History> createState() => _HistoryState();
}

class _HistoryState extends State<_History> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  bool _canDelete = false;
  bool _canFilterEmployees = false;
  DateTimeRange? _range; // filter: days (everyone)
  String? _empId; // filter: sales person (HR / المدير / المالك)

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'cash_get', 'path': '/forms/client-intros'});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = cashList(r, 'forms');
      _canDelete = r['canDelete'] == true;
      _canFilterEmployees = r['canFilterEmployees'] == true;
    });
  }

  String _d(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  String _show(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  /// sales people that appear on the loaded forms (id → name)
  Map<String, String> get _people {
    final m = <String, String>{};
    for (final f in _items) {
      final id = '${f['employeeId'] ?? ''}';
      if (id.isNotEmpty) m[id] = '${(f['data'] as Map?)?['salesName'] ?? ''}';
    }
    return m;
  }

  List<Map<String, dynamic>> get _shown => _items.where((f) {
        final day = '${(f['data'] as Map?)?['date'] ?? ''}';
        if (_range != null && (day.compareTo(_d(_range!.start)) < 0 || day.compareTo(_d(_range!.end)) > 0)) return false;
        if (_empId != null && '${f['employeeId']}' != _empId) return false;
        return true;
      }).toList();

  List<Widget> _filters(BuildContext context, bool isDark) {
    final people = _people;
    return [
      JphUi.picker(
        isDark: isDark, icon: Icons.date_range_rounded, iconColor: Colors.indigo, label: 'الأيام',
        value: _range == null ? 'كل الأيام' : '${_show(_range!.start)} - ${_show(_range!.end)}',
        onTap: () async {
          final now = DateTime.now();
          final r = await JphUi.pickRange(context, isDark, _range?.start ?? DateTime(now.year, now.month, 1), _range?.end ?? now);
          if (r != null && mounted) setState(() => _range = r);
        },
      ),
      if (_range != null)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(onPressed: () => setState(() => _range = null), icon: const Icon(Icons.close_rounded, size: 18), label: const Text('كل الأيام')),
        ),
      if (_canFilterEmployees) ...[
        const SizedBox(height: 10),
        JphUi.picker(
          isDark: isDark, icon: Icons.person_rounded, iconColor: Colors.teal, label: 'الموظف',
          value: _empId == null ? 'كل الموظفين' : (people[_empId] ?? ''),
          onTap: () async {
            final v = await JphUi.sheet<String>(context, isDark, 'الموظف',
                [('', 'كل الموظفين', Icons.groups_rounded), for (final e in people.entries) (e.key, e.value, Icons.person_rounded)],
                selected: _empId ?? '');
            if (v != null && mounted) setState(() => _empId = v.isEmpty ? null : v);
          },
        ),
      ],
      const SizedBox(height: 12),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 60), children: [
        if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        if (!_loading && _items.isNotEmpty) ..._filters(context, isDark),
        if (!_loading && _shown.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text(_items.isEmpty ? 'لسه مفيش استمارات' : 'مفيش استمارات بالفلتر ده',
              textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final f in _shown)
          GestureDetector(
            onTap: () => _print(context, f),
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: JphUi.box(isDark),
              child: Row(children: [
                JphUi.iconTile(isDark, Icons.person_search_rounded, Colors.indigo),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${(f['data'] as Map?)?['clientName'] ?? ''} • رقم ${f['number'] ?? ''}',
                        style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    Text('${(f['data'] as Map?)?['phone'] ?? ''} • ${(f['data'] as Map?)?['date'] ?? ''} • ${(f['data'] as Map?)?['salesName'] ?? ''}',
                        style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                  ]),
                ),
                Icon(Icons.print_rounded, color: JphUi.sub(isDark)),
                if (_canDelete)
                  formDeleteButton(() async {
                    if (await deleteFormRecord(context, '${f['id']}', '${(f['data'] as Map?)?['clientName'] ?? ''} • رقم ${f['number'] ?? ''}')) _load();
                  }),
              ]),
            ),
          ),
      ]),
    );
  }
}
