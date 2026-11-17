import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/employee_files.dart' show PickedDoc, pickDocument;
import '../../widgets/glass_ui.dart';
import '../../widgets/glass_ui_widgets.dart';
import '../../widgets/jph_form_ui.dart';

/// شركة تسويق — exactly the employee's form (add_employee_page.dart: same sections, fields and look) without what only an
/// employee has: الرقم القومي، تاريخ الميلاد، الوظيفة، يوم الإجازة، ليس لديه حضور وانصراف، تسجيل الحضور بصورة، ساعات العمل،
/// مضروب الغياب. Its own: المحاسبة (مبلغ ثابت / بالعمولة)، المدير المباشر = مسؤول إداري، الوضع (متعاقد / تم فسخ التعاقد)،
/// المستندات (عقد التعاقد، بلان الاتفاقات المالية، رؤية الشركة للتنفيذ) and the campaigns it runs. The managers are picked
/// with their photo and name. Its sign-in (e-mail / phone + password) is not an employee account.
class MarketingCompanyFormPage extends StatefulWidget {
  final String? id;   // null = a new company
  const MarketingCompanyFormPage({super.key, this.id});

  @override
  State<MarketingCompanyFormPage> createState() => _MarketingCompanyFormPageState();
}

const _docs = {
  'contract': 'عقد التعاقد (PDF)',
  'financial_plan': 'بلان الاتفاقات المالية (PDF)',
  'execution_vision': 'رؤية الشركة للتنفيذ (PDF)',
};
const _accounting = {'fixed': 'مبلغ ثابت', 'commission': 'بالعمولة'};
const _statuses = {'active': 'متعاقد', 'inactive': 'تم فسخ التعاقد'};

Map<String, dynamic> _m(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
List<Map<String, dynamic>> _l(Object? v) => ((v as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();

Future<Map<String, dynamic>> _get(String path) => ApiService.post({'action': 'cash_get', 'path': path});
Future<Map<String, dynamic>> _send(String path, Map<String, dynamic> body, {String method = 'post'}) =>
    ApiService.post({'action': 'cash_post', 'path': path, 'body': body, if (method != 'post') 'method': method});

class _MarketingCompanyFormPageState extends State<MarketingCompanyFormPage> {
  bool _isLoading = true;
  Map<String, dynamic> _c = {}, _opt = {};
  final _nameController = TextEditingController(), _phoneController = TextEditingController(), _emailController = TextEditingController(),
      _passwordController = TextEditingController(), _confirmPasswordController = TextEditingController(),
      _feeController = TextEditingController(), _pctController = TextEditingController();
  String _kind = 'commission', _status = 'active';
  String? _gm, _mgr;
  DateTime? _contract;
  bool _deviceLock = true, _isActive = true, _resetDevice = false;
  Set<String> _campaigns = {};
  final Map<String, PickedDoc?> _picked = {for (final k in [..._docs.keys, 'logo']) k: null};
  Uint8List? _logo;
  Map<String, String> _photos = {};

  bool get _isNew => widget.id == null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_isNew) {
      final o = await _get('/marketing-companies/options');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _opt = _m(o['options']);
      });
      _loadPhotos();
      return;
    }
    final r = await _get('/marketing-companies/${widget.id}');
    if (!mounted) return;
    final c = _m(r['company']);
    setState(() {
      _isLoading = false;
      _c = c;
      _opt = _m(r['options']);
      _nameController.text = '${c['name'] ?? ''}';
      _phoneController.text = '${c['loginPhone'] ?? c['phone'] ?? ''}';
      _emailController.text = '${c['loginEmail'] ?? ''}';
      _kind = '${c['kind'] ?? 'commission'}';
      _status = '${c['status'] ?? 'active'}';
      _pctController.text = '${c['defaultPct'] ?? ''}';
      _feeController.text = '${c['monthlyFee'] ?? ''}';
      _gm = _m(c['generalManager'])['id']?.toString();
      _mgr = _m(c['manager'])['id']?.toString();
      _contract = DateTime.tryParse('${c['contractDate'] ?? ''}');
      _deviceLock = c['deviceLock'] != false;
      _isActive = c['loginActive'] != false;
      _campaigns = {for (final x in (c['campaignIds'] as List? ?? const [])) '$x'};
    });
    _loadPhotos();
    if (_m(_m(c['files'])['logo']).isNotEmpty) {
      final l = await _get('/marketing-companies/${widget.id}/files/logo');
      if (mounted && l['data'] != null) setState(() => _logo = base64Decode('${l['data']}'));
    }
  }

  Future<void> _loadPhotos() async {
    final ids = [for (final k in ['managers', 'generalManagers']) for (final e in _l(_opt[k])) '${e['id']}'];
    if (ids.isEmpty || JphUi.photosOf == null) return;
    final p = await JphUi.photosOf!(ids);
    if (mounted) setState(() => _photos = p);
  }

  Future<void> _pickImage() async {
    final d = await pickDocument(context, 'national_id');
    if (d == null) return;
    if (d.bytes.length > 3 * 1024 * 1024) return _snack('الصورة أكبر من 3 ميجا', Ar.red);
    setState(() {
      _picked['logo'] = d;
      _logo = d.bytes;
    });
  }

  void _snack(String m, Color c) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: c));

  Future<void> _selectContractDate() async {
    final d = await showDatePicker(context: context, initialDate: _contract ?? DateTime.now(), firstDate: DateTime(2015), lastDate: DateTime(2100));
    if (d != null) setState(() => _contract = d);
  }

  String? _validateForm() {
    if (_nameController.text.trim().length < 2) return 'الاسم مطلوب';
    if (_phoneController.text.trim().isEmpty) return 'رقم الهاتف مطلوب';
    if (_isNew && _passwordController.text.isEmpty) return 'كلمة المرور مطلوبة';
    if (_passwordController.text != _confirmPasswordController.text) return 'كلمة المرور وتأكيدها غير متطابقين';
    if (_kind == 'fixed' && _feeController.text.trim().isEmpty) return 'المبلغ الثابت مطلوب';
    if (_kind == 'commission' && _pctController.text.trim().isEmpty) return 'نسبة العمولة مطلوبة';
    return null;
  }

  Future<void> _save() async {
    final err = _validateForm();
    if (err != null) return _snack(err, Ar.red);
    setState(() => _isLoading = true);
    try {
      final base = {
        'name': _nameController.text.trim(), 'phone': _phoneController.text.trim(),
        if (_kind == 'commission') 'defaultPct': num.tryParse(_pctController.text) ?? 0,
        if (_kind == 'fixed') 'monthlyFee': num.tryParse(_feeController.text.replaceAll(',', '')) ?? 0,
      };
      var id = widget.id;
      final r1 = _isNew
          ? await _send('/marketing-companies', {...base, 'kind': _kind})
          : await _send('/marketing-companies/$id', {...base, 'status': _status}, method: 'patch');
      if (r1['success'] == false) throw r1;
      id ??= '${_m(r1['company'])['id']}';
      if (_isNew && _status != 'active') await _send('/marketing-companies/$id', {'status': _status}, method: 'patch');
      // the sign-in: e-mail and / or the phone + password
      final changed = _emailController.text.trim() != '${_c['loginEmail'] ?? ''}' || _phoneController.text.trim() != '${_c['loginPhone'] ?? ''}';
      if (_isNew || changed || _passwordController.text.isNotEmpty) {
        final r2 = await _send('/leads/partners/$id/login', {
          'email': _emailController.text.trim(), 'phone': _phoneController.text.trim(),
          if (_passwordController.text.isNotEmpty) 'password': _passwordController.text,
        }, method: 'patch');
        if (r2['success'] == false) throw r2;
      }
      final r3 = await _send('/marketing-companies/$id/profile', {
        'generalManagerId': _gm, 'managerId': _mgr,
        'contractDate': _contract?.toIso8601String().substring(0, 10),
        'campaignIds': _campaigns.toList(),
        'deviceLock': _deviceLock, 'loginActive': _isActive, if (_resetDevice) 'resetDevice': true,
      }, method: 'patch');
      if (r3['success'] == false) throw r3;
      for (final e in _picked.entries) {
        final d = e.value;
        if (d == null) continue;
        final r4 = await _send('/marketing-companies/$id/files/${e.key}', {'fileName': d.fileName, 'mime': d.mime, 'data': d.base64}, method: 'put');
        if (r4['success'] == false) throw r4;
      }
      if (!mounted) return;
      _snack(_isNew ? 'تم إضافة شركة التسويق بنجاح' : 'تم الحفظ ✅', Ar.green);
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) _snack(e is Map ? '${e['message'] ?? 'حصل خطأ'}' : '$e', Ar.red);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _openDoc(String kind) async {
    final r = await _get('/marketing-companies/${widget.id}/files/$kind');
    if (!mounted || r['data'] == null) return;
    final bytes = base64Decode('${r['data']}');
    await Navigator.push(context, MaterialPageRoute(builder: (_) => AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, title: Text('${r['fileName']}')),
        body: PdfPreview(build: (_) async => bytes, pdfFileName: '${r['fileName']}', canChangePageFormat: false, canChangeOrientation: false, canDebug: false),
      ),
    )));
  }

  Widget _title(bool isDark, String t) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 16),
        child: Text(t, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
      );

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(builder: (context, appController, _) {
      final isDark = appController.isDark;
      final files = _m(_c['files']);
      return AppBackground(
        child: Directionality(
          textDirection: appController.isRTL ? TextDirection.rtl : TextDirection.ltr,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(children: [
                    IconButton(icon: Icon(Icons.arrow_back, color: isDark ? Colors.white : Colors.black), onPressed: () => Navigator.pop(context)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_isNew ? 'إضافة شركة تسويق جديدة' : 'شركة التسويق — ${_c['name'] ?? ''}',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
                    ),
                    IconButton(icon: Icon(Icons.close, color: isDark ? Colors.white70 : Colors.black54), onPressed: () => Navigator.pop(context)),
                  ]),
                ),
                Expanded(
                  child: _isLoading
                      ? Center(child: CircularProgressIndicator(color: AppColors.primary))
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            // لوجو الشركة
                            Center(
                              child: GestureDetector(
                                onTap: _pickImage,
                                child: Stack(children: [
                                  Container(
                                    width: 120,
                                    height: 120,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: isDark ? Colors.white.withOpacity(0.2) : Ar.grey[200],
                                      border: Border.all(color: _isActive ? Ar.green : Ar.red, width: 3),
                                    ),
                                    child: ClipOval(
                                      child: _logo != null
                                          ? Image.memory(_logo!, fit: BoxFit.cover, width: 120, height: 120)
                                          : Center(child: Icon(Icons.add_business_rounded, size: 40, color: isDark ? Colors.white70 : Ar.grey[700])),
                                    ),
                                  ),
                                  Positioned(
                                    bottom: 0,
                                    right: 0,
                                    child: Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        color: AppColors.primary,
                                        shape: BoxShape.circle,
                                        border: Border.all(color: isDark ? Colors.black : Colors.white, width: 3),
                                      ),
                                      child: const Icon(Icons.camera_alt, size: 20, color: Colors.white),
                                    ),
                                  ),
                                ]),
                              ),
                            ),
                            const SizedBox(height: 8),

                            _title(isDark, 'معلومات الشركة'),
                            _buildInfoField(label: 'الاسم *', value: _nameController, icon: Icons.business, isDark: isDark),
                            _buildInfoField(label: 'رقم الهاتف *', value: _phoneController, icon: Icons.phone, keyboardType: TextInputType.phone, isDark: isDark),
                            _buildInfoField(label: 'البريد الإلكتروني', value: _emailController, icon: Icons.email, keyboardType: TextInputType.emailAddress, isDark: isDark),
                            _buildInfoField(label: _isNew ? 'كلمة المرور *' : 'كلمة مرور جديدة (سيبها فاضية لو مش هتغيّرها)',
                                value: _passwordController, icon: Icons.lock, isPassword: true, isDark: isDark),
                            _buildInfoField(label: _isNew ? 'تأكيد كلمة المرور *' : 'تأكيد كلمة المرور', value: _confirmPasswordController,
                                icon: Icons.lock_outline, isPassword: true, isDark: isDark),

                            _title(isDark, 'المعلومات الإدارية'),
                            _buildDropdownField(
                              label: 'المحاسبه *',
                              value: _accounting[_kind],
                              items: _accounting.values.toList(),
                              icon: Icons.account_balance,
                              enabled: _isNew,
                              onChanged: (v) => setState(() => _kind = _accounting.entries.firstWhere((e) => e.value == v).key),
                              isDark: isDark,
                            ),
                            _personField(isDark, 'المدير المباشر (مسؤول إداري)', 'managers', _mgr, Icons.supervisor_account, (v) => setState(() => _mgr = v),
                                'مفيش موظف بوظيفة «مسؤول إداري»'),
                            _personField(isDark, 'المدير العام', 'generalManagers', _gm, Icons.account_tree_rounded, (v) => setState(() => _gm = v), 'مفيش مدير عام'),

                            _title(isDark, 'المعلومات المالية'),
                            if (_kind == 'fixed')
                              _buildInfoField(label: 'المبلغ الثابت الشهري *', value: _feeController, icon: Icons.money, keyboardType: TextInputType.number, isDark: isDark)
                            else
                              _buildInfoField(label: 'نسبة العمولة ٪ من سعر الوحدة *', value: _pctController, icon: Icons.percent_rounded,
                                  keyboardType: TextInputType.number, isDark: isDark),

                            _title(isDark, 'معلومات العمل'),
                            _buildDateField(isDark),
                            Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              decoration: Glass.tile(isDark, r: 12),
                              child: Column(children: [
                                SwitchListTile(
                                  value: _deviceLock,
                                  onChanged: (v) => setState(() => _deviceLock = v),
                                  title: Text('ربط الحساب بالجهاز', style: TextStyle(fontSize: 16, color: isDark ? Colors.white : Colors.black)),
                                  subtitle: Text(_deviceLock ? 'يدخل من أول جهاز يسجّل منه بس' : 'يقدر يدخل من أي جهاز'),
                                  secondary: Icon(Icons.phonelink_lock_rounded, color: _deviceLock ? Ar.green : Ar.grey),
                                ),
                                if (_deviceLock && _c['deviceLabel'] != null)
                                  ListTile(
                                    leading: const Icon(Icons.smartphone_rounded),
                                    title: Text(_resetDevice ? 'هيتفك الربط مع الحفظ' : 'مربوط بـ: ${_c['deviceLabel']}'),
                                    trailing: TextButton(
                                      onPressed: () => setState(() => _resetDevice = !_resetDevice),
                                      child: Text(_resetDevice ? 'تراجع' : 'فك الربط'),
                                    ),
                                  ),
                              ]),
                            ),

                            _title(isDark, 'معلومات إضافية'),
                            _buildDropdownField(
                              label: 'الوضع',
                              value: _statuses[_status],
                              items: _statuses.values.toList(),
                              icon: Icons.work,
                              onChanged: (v) => setState(() => _status = _statuses.entries.firstWhere((e) => e.value == v).key),
                              isDark: isDark,
                            ),
                            Container(
                              padding: const EdgeInsets.all(16),
                              margin: const EdgeInsets.only(bottom: 12),
                              decoration: Glass.tile(isDark, r: 12),
                              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                                Row(children: [
                                  Icon(_isActive ? Icons.check_circle : Icons.remove_circle,
                                      color: _isActive ? (isDark ? Ar.green[300] : Ar.green) : (isDark ? Ar.red[300] : Ar.red)),
                                  const SizedBox(width: 12),
                                  Text('حالة تسجيل الدخول', style: TextStyle(fontSize: 16, color: isDark ? Colors.white : Colors.black)),
                                ]),
                                Switch(value: _isActive, onChanged: (v) => setState(() => _isActive = v), activeColor: Ar.green),
                              ]),
                            ),
                            // the campaigns it runs (it sees only their leads)
                            Container(
                              padding: const EdgeInsets.all(14),
                              margin: const EdgeInsets.only(bottom: 12),
                              decoration: Glass.tile(isDark, r: 12),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Row(children: [
                                  Icon(Icons.ads_click_rounded, color: isDark ? Colors.white70 : Ar.grey[600]),
                                  const SizedBox(width: 12),
                                  Text('الحملات اللي بتشغّلها', style: TextStyle(fontSize: 16, color: isDark ? Colors.white : Colors.black)),
                                ]),
                                const SizedBox(height: 4),
                                Text('الشركة بتشوف ليدز الحملات دي بس، وتقدر تضيف عليها ليدز.', style: TextStyle(fontSize: 12.5, color: isDark ? Colors.white60 : Ar.grey[600])),
                                const SizedBox(height: 8),
                                if (_l(_opt['campaigns']).isEmpty)
                                  Text('مفيش حملات — اعملها من إعدادات الليدز ← الحملات', style: TextStyle(color: isDark ? Colors.white60 : Ar.grey[600]))
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
                            ),

                            const SizedBox(height: 12),
                            Text('المستندات (اختياري)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
                            const SizedBox(height: 12),
                            GlassCard(
                              child: Column(children: [
                                for (final k in _docs.keys)
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(_picked[k] == null && files[k] == null ? Icons.upload_file_rounded : Icons.check_circle_rounded,
                                        color: _picked[k] == null && files[k] == null ? Ar.amber : Ar.green),
                                    title: Text(_docs[k]!),
                                    subtitle: Text(_picked[k]?.fileName ?? (files[k] != null ? '${_m(files[k])['fileName']}' : 'ملف PDF'),
                                        maxLines: 1, overflow: TextOverflow.ellipsis),
                                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                      if (files[k] != null && _picked[k] == null)
                                        IconButton(tooltip: 'عرض', icon: const Icon(Icons.visibility_rounded), onPressed: () => _openDoc(k)),
                                      TextButton(
                                        onPressed: () async {
                                          final f = await pickDocument(context, 'pdf');
                                          if (f == null) return;
                                          if (f.bytes.length > 3 * 1024 * 1024) return _snack('الملف أكبر من 3 ميجا', Ar.red);
                                          setState(() => _picked[k] = f);
                                        },
                                        child: Text(_picked[k] == null && files[k] == null ? 'اختيار' : 'تغيير'),
                                      ),
                                    ]),
                                  ),
                              ]),
                            ),

                            const SizedBox(height: 32),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: _save,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primary,
                                  padding: const EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                child: Text(_isNew ? 'إضافة شركة التسويق' : 'حفظ التعديلات',
                                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                              ),
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton(
                                onPressed: () => Navigator.pop(context),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  side: BorderSide(color: isDark ? Colors.white70 : Ar.grey),
                                ),
                                child: Text('إلغاء', style: TextStyle(fontSize: 16, color: isDark ? Colors.white70 : Ar.grey[700])),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: isDark ? Ar.info.withOpacity(0.1) : Ar.info.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: isDark ? Ar.info.withOpacity(0.3) : Ar.info.withOpacity(0.2)),
                              ),
                              child: Row(children: [
                                Icon(Icons.info, color: isDark ? Ar.info[300] : Ar.info[700], size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'الحقول التي تحمل علامة (*) إلزامية\nالشركة تدخل التطبيق برقم الهاتف أو البريد الإلكتروني + كلمة المرور، وتغيّر كلمة المرور أول مرة',
                                    style: TextStyle(fontSize: 14, color: isDark ? Ar.info[300] : Ar.info[700]),
                                  ),
                                ),
                              ]),
                            ),
                          ]),
                        ),
                ),
              ]),
            ),
          ),
        ),
      );
    });
  }

  Widget _labelled(bool isDark, String label, Widget child) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 14, color: isDark ? Colors.white70 : Ar.grey[700])),
          const SizedBox(height: 4),
          Container(decoration: Glass.tile(isDark, r: 12), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: child)),
        ]),
      );

  Widget _buildInfoField({required String label, required TextEditingController value, required IconData icon, required bool isDark,
      bool isPassword = false, TextInputType keyboardType = TextInputType.text}) =>
      _labelled(isDark, label, Row(children: [
        Icon(icon, color: isDark ? Colors.white70 : Ar.grey[600]),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            controller: value,
            keyboardType: keyboardType,
            obscureText: isPassword,
            style: TextStyle(fontSize: 16, color: isDark ? Colors.white : Colors.black),
            decoration: const InputDecoration(border: InputBorder.none, contentPadding: EdgeInsets.symmetric(vertical: 16)),
          ),
        ),
      ]));

  Widget _buildDateField(bool isDark) => _labelled(isDark, 'تاريخ التعاقد', Row(children: [
        Icon(Icons.calendar_today, color: isDark ? Colors.white70 : Ar.grey[600]),
        const SizedBox(width: 12),
        Expanded(
          child: InkWell(
            onTap: _selectContractDate,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                _contract == null ? 'اختر تاريخ التعاقد'
                    : '${_contract!.year}-${_contract!.month.toString().padLeft(2, '0')}-${_contract!.day.toString().padLeft(2, '0')}',
                style: TextStyle(fontSize: 16, color: isDark ? Colors.white : Colors.black),
              ),
            ),
          ),
        ),
      ]));

  Widget _buildDropdownField({required String label, required String? value, required List<String> items, required IconData icon,
      required ValueChanged<String?> onChanged, required bool isDark, bool enabled = true}) =>
      _labelled(isDark, label, Row(children: [
        Icon(icon, color: isDark ? Colors.white70 : Ar.grey[600]),
        const SizedBox(width: 12),
        Expanded(
          child: DropdownButton<String>(
            value: items.contains(value) ? value : null,
            items: [for (final i in items) DropdownMenuItem(value: i, child: Text(i))],
            onChanged: enabled ? onChanged : null,
            isExpanded: true,
            underline: const SizedBox(),
            style: TextStyle(fontSize: 16, color: isDark ? Colors.white : Colors.black),
            dropdownColor: isDark ? Ar.grey[800] : Colors.white,
            hint: Text('اختر $label'),
            disabledHint: value == null ? null : Text(value, style: TextStyle(fontSize: 16, color: isDark ? Colors.white : Colors.black)),
          ),
        ),
      ]));

  /// المدير المباشر / المدير العام: the chosen person with photo and name; the list opens with everyone's photo
  Widget _personField(bool isDark, String label, String key, String? value, IconData icon, ValueChanged<String?> onPick, String empty) {
    final list = _l(_opt[key]);
    final chosen = list.where((e) => '${e['id']}' == value).firstOrNull;
    return _labelled(isDark, label, InkWell(
      onTap: () async {
        if (list.isEmpty) return _snack(empty, Ar.red);
        final v = await JphUi.sheet<String>(context, isDark, label,
            [('', 'بدون', Icons.remove_circle_outline_rounded), for (final e in list) ('${e['id']}', '${e['name']}', Icons.person_rounded)],
            selected: value ?? '', people: true);
        if (v != null) onPick(v.isEmpty ? null : v);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          chosen == null
              ? Icon(icon, color: isDark ? Colors.white70 : Ar.grey[600])
              : JphUi.personAvatar('${chosen['name']}', _photos['${chosen['id']}'], size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Text(chosen == null ? 'اختر $label' : '${chosen['name']}',
                style: TextStyle(fontSize: 16, fontWeight: chosen == null ? FontWeight.w400 : FontWeight.w700,
                    color: chosen == null ? (isDark ? Colors.white60 : Ar.grey[600]) : (isDark ? Colors.white : Colors.black))),
          ),
          Icon(Icons.arrow_drop_down, color: isDark ? Colors.white70 : Ar.grey[600]),
        ]),
      ),
    ));
  }
}
