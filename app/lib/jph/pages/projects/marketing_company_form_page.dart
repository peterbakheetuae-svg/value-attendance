import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/employee_files.dart' show PickedDoc, pickDocument;
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';

/// شركة تسويق — its file, like an employee's (add_employee_page) but without what only an employee has (national ID, birth
/// date, job, day off, attendance, selfie, working hours, absence multiplier, the employee documents):
///   البيانات + الدخول على التطبيق (e-mail / mobile + password — not an employee account; it sees only its campaigns' leads)
///   المحاسبة: مبلغ ثابت / بالعمولة · المدير المباشر (مسؤول إداري) · المدير العام · تاريخ التعاقد · الوضع: متعاقد / تم فسخ التعاقد
///   الحملات اللي بتشغّلها · المستندات: عقد التعاقد، بلان الاتفاقات المالية، رؤية الشركة للتنفيذ
class MarketingCompanyFormPage extends StatefulWidget {
  final String? id;   // null = a new company
  const MarketingCompanyFormPage({super.key, this.id});

  @override
  State<MarketingCompanyFormPage> createState() => _MarketingCompanyFormPageState();
}

const _docs = {
  'contract': ('عقد التعاقد', Icons.handshake_rounded),
  'financial_plan': ('بلان الاتفاقات المالية', Icons.request_quote_rounded),
  'execution_vision': ('رؤية الشركة للتنفيذ', Icons.lightbulb_rounded),
};

Map<String, dynamic> _m(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
List<Map<String, dynamic>> _l(Object? v) => ((v as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();

Future<Map<String, dynamic>> _get(String path) => ApiService.post({'action': 'cash_get', 'path': path});
Future<Map<String, dynamic>> _send(String path, Map<String, dynamic> body, {String method = 'post'}) =>
    ApiService.post({'action': 'cash_post', 'path': path, 'body': body, if (method != 'post') 'method': method});

class _MarketingCompanyFormPageState extends State<MarketingCompanyFormPage> {
  bool _loading = true, _saving = false;
  Map<String, dynamic> _c = {}, _opt = {};
  final _name = TextEditingController(), _phone = TextEditingController(), _email = TextEditingController(),
      _loginPhone = TextEditingController(), _pass = TextEditingController(), _pass2 = TextEditingController(),
      _pct = TextEditingController(), _fee = TextEditingController();
  String _kind = 'commission', _status = 'active';
  String? _gm, _mgr;
  DateTime? _contract;
  Set<String> _campaigns = {};
  final Map<String, PickedDoc?> _picked = {for (final k in [..._docs.keys, 'logo']) k: null};
  Uint8List? _logo;

  bool get _isNew => widget.id == null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_isNew) {
      // a new company: only the choices (managers / campaigns)
      final o = await _get('/marketing-companies/options');
      if (mounted) setState(() {
        _loading = false;
        _opt = _m(o['options']);
      });
      return;
    }
    final r = await _get('/marketing-companies/${widget.id}');
    if (!mounted) return;
    final c = _m(r['company']);
    setState(() {
      _loading = false;
      _c = c;
      _opt = _m(r['options']);
      _name.text = '${c['name'] ?? ''}';
      _phone.text = '${c['phone'] ?? ''}';
      _email.text = '${c['loginEmail'] ?? ''}';
      _loginPhone.text = '${c['loginPhone'] ?? ''}';
      _kind = '${c['kind'] ?? 'commission'}';
      _status = '${c['status'] ?? 'active'}';
      _pct.text = '${c['defaultPct'] ?? ''}';
      _fee.text = '${c['monthlyFee'] ?? ''}';
      _gm = _m(c['generalManager'])['id']?.toString();
      _mgr = _m(c['manager'])['id']?.toString();
      _contract = DateTime.tryParse('${c['contractDate'] ?? ''}');
      _campaigns = {for (final x in (c['campaignIds'] as List? ?? const [])) '$x'};
    });
    if (_m(_m(c['files'])['logo']).isNotEmpty) {
      final l = await _get('/marketing-companies/${widget.id}/files/logo');
      if (mounted && l['data'] != null) setState(() => _logo = base64Decode('${l['data']}'));
    }
  }

  Future<void> _openDoc(String kind) async {
    final r = await _get('/marketing-companies/${widget.id}/files/$kind');
    if (!mounted) return;
    if (r['data'] == null) return JphUi.toast(context, r);
    final bytes = base64Decode('${r['data']}');
    await Navigator.push(context, MaterialPageRoute(builder: (_) => AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, title: Text('${r['fileName']}')),
        body: PdfPreview(build: (_) async => bytes, pdfFileName: '${r['fileName']}', canChangePageFormat: false, canChangeOrientation: false, canDebug: false),
      ),
    )));
  }

  Future<void> _pick(String kind) async {
    final d = await pickDocument(context, kind == 'logo' ? 'national_id' : 'pdf');
    if (d == null) return;
    if (d.bytes.length > 3 * 1024 * 1024) {
      if (mounted) JphUi.toast(context, {'success': false, 'message': 'الملف أكبر من 3 ميجا'});
      return;
    }
    setState(() {
      _picked[kind] = d;
      if (kind == 'logo') _logo = d.bytes;
    });
  }

  Future<void> _save() async {
    final name = _name.text.trim(), phone = _phone.text.trim();
    String? err;
    if (name.length < 2) err = 'اكتب اسم الشركة';
    if (phone.isEmpty) err ??= 'اكتب رقم الهاتف';
    if (_pass.text.isNotEmpty && _pass.text != _pass2.text) err ??= 'كلمة المرور وتأكيدها مش زي بعض';
    final wantsLogin = _email.text.trim().isNotEmpty || _loginPhone.text.trim().isNotEmpty;
    if (wantsLogin && _c['hasLogin'] != true && _pass.text.isEmpty) err ??= 'اكتب كلمة مرور للدخول على التطبيق';
    if (_pass.text.isNotEmpty && !wantsLogin) err ??= 'اكتب إيميل أو موبايل الدخول';
    if (err != null) return JphUi.toast(context, {'success': false, 'message': err});
    setState(() => _saving = true);
    try {
      // 1) the company itself (name / phone / المحاسبة / الوضع)
      final base = {
        'name': name, 'phone': phone,
        if (_kind == 'commission') 'defaultPct': num.tryParse(_pct.text) ?? 0,
        if (_kind == 'fixed') 'monthlyFee': num.tryParse(_fee.text.replaceAll(',', '')) ?? 0,
      };
      var id = widget.id;
      final r1 = _isNew
          ? await _send('/marketing-companies', {...base, 'kind': _kind})
          : await _send('/marketing-companies/$id', {...base, 'status': _status}, method: 'patch');
      if (r1['success'] == false) throw r1;
      id ??= '${_m(r1['company'])['id']}';
      if (_isNew && _status != 'active') await _send('/marketing-companies/$id', {'status': _status}, method: 'patch');
      // 2) الدخول على التطبيق
      final emailChanged = _email.text.trim() != '${_c['loginEmail'] ?? ''}' || _loginPhone.text.trim() != '${_c['loginPhone'] ?? ''}';
      if (wantsLogin && (emailChanged || _pass.text.isNotEmpty)) {
        final r2 = await _send('/leads/partners/$id/login', {
          'email': _email.text.trim(), 'phone': _loginPhone.text.trim(), if (_pass.text.isNotEmpty) 'password': _pass.text,
        }, method: 'patch');
        if (r2['success'] == false) throw r2;
      } else if (!wantsLogin && _c['hasLogin'] == true) {
        await _send('/leads/partners/$id/login', {'off': true}, method: 'patch');
      }
      // 3) المدير العام / المدير المباشر / تاريخ التعاقد / الحملات
      final r3 = await _send('/marketing-companies/$id/profile', {
        'generalManagerId': _gm, 'managerId': _mgr,
        'contractDate': _contract == null ? null : _contract!.toIso8601String().substring(0, 10),
        'campaignIds': _campaigns.toList(),
      }, method: 'patch');
      if (r3['success'] == false) throw r3;
      // 4) المستندات
      for (final e in _picked.entries) {
        final d = e.value;
        if (d == null) continue;
        final r4 = await _send('/marketing-companies/$id/files/${e.key}', {'fileName': d.fileName, 'mime': d.mime, 'data': d.base64}, method: 'put');
        if (r4['success'] == false) throw r4;
      }
      if (!mounted) return;
      JphUi.toast(context, {'success': true, 'message': 'اتحفظ ✅'});
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) JphUi.toast(context, e is Map<String, dynamic> ? e : {'success': false, 'message': '$e'});
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _section(bool isDark, String title, IconData icon, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: JphUi.box(isDark),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(icon, color: JphUi.primary(isDark)),
            const SizedBox(width: 8),
            Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
          ]),
          const SizedBox(height: 12),
          for (final (i, w) in children.indexed) ...[if (i > 0) const SizedBox(height: 10), w],
        ]),
      );

  Widget _personPicker(bool isDark, String label, String key, String? value, ValueChanged<String?> onPick, String empty) {
    final list = _l(_opt[key]);
    final name = list.where((e) => '${e['id']}' == value).map((e) => '${e['name']}').firstOrNull;
    return JphUi.picker(
      isDark: isDark,
      icon: Icons.person_rounded,
      iconColor: Ar.accent,
      label: label,
      value: name ?? 'اختار',
      onTap: () async {
        if (list.isEmpty) return JphUi.toast(context, {'success': false, 'message': empty});
        final v = await JphUi.sheet<String>(context, isDark, label, [('', 'بدون', Icons.remove_circle_outline_rounded),
            for (final e in list) ('${e['id']}', '${e['name']}', Icons.person_rounded)], selected: value ?? '', people: true);
        if (v != null) onPick(v.isEmpty ? null : v);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final files = _m(_c['files']);
    return AppBackground(
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Column(children: [
              JphUi.header(context, isDark: isDark, isRTL: true, title: _isNew ? 'شركة تسويق جديدة' : '${_c['name'] ?? 'شركة تسويق'}'),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 820),
                          child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 120), children: [
                            // اللوجو
                            Center(
                              child: GestureDetector(
                                onTap: () => _pick('logo'),
                                child: Stack(children: [
                                  CircleAvatar(
                                    radius: 52,
                                    backgroundColor: JphUi.primary(isDark).withOpacity(0.15),
                                    backgroundImage: _logo == null ? null : MemoryImage(_logo!),
                                    child: _logo == null ? Icon(Icons.campaign_rounded, size: 46, color: JphUi.primary(isDark)) : null,
                                  ),
                                  PositionedDirectional(
                                    bottom: 0,
                                    end: 0,
                                    child: CircleAvatar(radius: 16, backgroundColor: JphUi.primary(isDark),
                                        child: const Icon(Icons.camera_alt_rounded, size: 16, color: Colors.white)),
                                  ),
                                ]),
                              ),
                            ),
                            const SizedBox(height: 16),
                            _section(isDark, 'البيانات', Icons.badge_rounded, [
                              JphUi.input(isDark: isDark, label: 'اسم الشركة *', controller: _name, icon: Icons.campaign_rounded),
                              JphUi.input(isDark: isDark, label: 'رقم الهاتف *', controller: _phone, number: true, icon: Icons.phone_rounded),
                            ]),
                            _section(isDark, 'الدخول على التطبيق', Icons.lock_rounded, [
                              Text('الشركة تدخل بالإيميل أو الموبايل + كلمة المرور، وتشوف لوحة تحكم وليدز حملاتها بس وتضيف ليدز. أول مرة هتغيّر كلمة المرور بنفسها.',
                                  style: TextStyle(color: JphUi.sub(isDark))),
                              JphUi.input(isDark: isDark, label: 'البريد الإلكتروني', controller: _email, icon: Icons.alternate_email_rounded),
                              JphUi.input(isDark: isDark, label: 'موبايل الدخول', controller: _loginPhone, number: true, icon: Icons.phone_iphone_rounded),
                              JphUi.input(isDark: isDark, label: _c['hasLogin'] == true ? 'كلمة مرور جديدة (سيبها فاضية لو مش هتغيّرها)' : 'كلمة المرور',
                                  controller: _pass, icon: Icons.key_rounded),
                              JphUi.input(isDark: isDark, label: 'تأكيد كلمة المرور', controller: _pass2, icon: Icons.key_rounded),
                            ]),
                            _section(isDark, 'المحاسبة', Icons.payments_rounded, [
                              SegmentedButton<String>(
                                segments: const [
                                  ButtonSegment(value: 'fixed', label: Text('مبلغ ثابت')),
                                  ButtonSegment(value: 'commission', label: Text('بالعمولة')),
                                ],
                                selected: {_kind},
                                onSelectionChanged: _isNew ? (s) => setState(() => _kind = s.first) : null,
                              ),
                              if (_kind == 'commission')
                                JphUi.input(isDark: isDark, label: 'نسبتها ٪ من سعر الوحدة (بتتخصم من نصيب المكتب)', controller: _pct, number: true, icon: Icons.percent_rounded)
                              else
                                JphUi.input(isDark: isDark, label: 'المبلغ الشهري', controller: _fee, number: true, suffix: 'جنيه', icon: Icons.payments_rounded),
                            ]),
                            _section(isDark, 'الإدارة والتعاقد', Icons.account_tree_rounded, [
                              _personPicker(isDark, 'المدير المباشر (مسؤول إداري)', 'managers', _mgr, (v) => setState(() => _mgr = v), 'مفيش موظف بوظيفة «مسؤول إداري»'),
                              _personPicker(isDark, 'المدير العام', 'generalManagers', _gm, (v) => setState(() => _gm = v), 'مفيش مدير عام'),
                              JphUi.picker(
                                isDark: isDark,
                                icon: Icons.event_rounded,
                                iconColor: Ar.accent,
                                label: 'تاريخ التعاقد',
                                value: _contract == null ? 'اختار' : '${_contract!.year}-${_contract!.month.toString().padLeft(2, '0')}-${_contract!.day.toString().padLeft(2, '0')}',
                                onTap: () async {
                                  final d = await showDatePicker(context: context, initialDate: _contract ?? DateTime.now(),
                                      firstDate: DateTime(2015), lastDate: DateTime(2100));
                                  if (d != null) setState(() => _contract = d);
                                },
                              ),
                              SegmentedButton<String>(
                                segments: const [
                                  ButtonSegment(value: 'active', label: Text('متعاقد'), icon: Icon(Icons.verified_rounded)),
                                  ButtonSegment(value: 'inactive', label: Text('تم فسخ التعاقد'), icon: Icon(Icons.cancel_rounded)),
                                ],
                                selected: {_status},
                                onSelectionChanged: (s) => setState(() => _status = s.first),
                              ),
                            ]),
                            _section(isDark, 'الحملات اللي بتشغّلها', Icons.ads_click_rounded, [
                              Text('الشركة بتشوف ليدز الحملات دي بس. الحملة المربوطة بشركة تانية هتتنقل للشركة دي.', style: TextStyle(color: JphUi.sub(isDark))),
                              if (_l(_opt['campaigns']).isEmpty)
                                Text('مفيش حملات — اعملها من إعدادات الليدز ← الحملات', style: TextStyle(color: JphUi.sub(isDark)))
                              else
                                Wrap(spacing: 8, runSpacing: 8, children: [
                                  for (final x in _l(_opt['campaigns']))
                                    FilterChip(
                                      selected: _campaigns.contains('${x['id']}'),
                                      label: Text('${x['name']}${x['active'] == false ? ' (موقوفة)' : ''}'),
                                      onSelected: (v) => setState(() => v ? _campaigns.add('${x['id']}') : _campaigns.remove('${x['id']}')),
                                    ),
                                ]),
                            ]),
                            _section(isDark, 'المستندات', Icons.folder_rounded, [
                              for (final e in _docs.entries)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: (isDark ? Colors.white : Colors.black).withOpacity(0.04),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Row(children: [
                                    Icon(e.value.$2, color: Ar.accent),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                        Text(e.value.$1, style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                                        Text(
                                          _picked[e.key] != null
                                              ? '${_picked[e.key]!.fileName} (هيترفع مع الحفظ)'
                                              : files[e.key] != null ? '${_m(files[e.key])['fileName']}' : 'ملف PDF — لسه مترفعش',
                                          style: TextStyle(fontSize: 12, color: JphUi.sub(isDark)),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ]),
                                    ),
                                    if (files[e.key] != null && _picked[e.key] == null)
                                      IconButton(tooltip: 'عرض', icon: const Icon(Icons.visibility_rounded), onPressed: () => _openDoc(e.key)),
                                    IconButton(tooltip: files[e.key] != null ? 'تغيير' : 'رفع', icon: const Icon(Icons.upload_file_rounded), onPressed: () => _pick(e.key)),
                                  ]),
                                ),
                            ]),
                            SizedBox(
                              height: 54,
                              child: FilledButton.icon(
                                onPressed: _saving ? null : _save,
                                icon: _saving
                                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                    : const Icon(Icons.check_rounded),
                                label: Text(_isNew ? 'إضافة الشركة' : 'حفظ', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                              ),
                            ),
                          ]),
                        ),
                      ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
