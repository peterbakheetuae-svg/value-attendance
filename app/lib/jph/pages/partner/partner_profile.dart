import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../services/app_controller.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/app_nav.dart';
import '../../widgets/glass_bottom_nav.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/glass_ui_widgets.dart';
import '../../widgets/jph_form_ui.dart';
import '../leads/leads_api.dart';
import '../login/otp_page.dart';
import '../../services/api_service.dart';
import '../notifications/notifications_page.dart';

/// the company's logo (its «صورة الملف الشخصي»), loaded once
class PartnerLogo {
  static Uint8List? bytes;
  static bool _tried = false;
  static Future<Uint8List?> load({bool fresh = false}) async {
    if (_tried && !fresh) return bytes;
    _tried = true;
    final r = await lget('/partner/files/logo');
    bytes = r['data'] == null ? null : base64Decode('${r['data']}');
    return bytes;
  }
}

/// The top of the company's dashboard — the same as the general manager's: the bell on the right, today / the name /
/// «شركة تسويق» in the middle, the photo (its logo) on the left → «الملف الشخصي».
class PartnerTopBar extends StatefulWidget {
  final bool isDark;
  final String name;
  const PartnerTopBar({super.key, required this.isDark, required this.name});

  @override
  State<PartnerTopBar> createState() => _PartnerTopBarState();
}

class _PartnerTopBarState extends State<PartnerTopBar> {
  Uint8List? _logo;

  @override
  void initState() {
    super.initState();
    PartnerLogo.load().then((b) {
      if (mounted) setState(() => _logo = b);
    });
  }

  String _today(BuildContext context) {
    final now = DateTime.now();
    final dayName = AppLocalizations.of(context, 'day_${now.weekday}');
    return "${AppLocalizations.of(context, 'today')} $dayName ${now.day.toString().padLeft(2, '0')} / ${now.month.toString().padLeft(2, '0')} / ${now.year}";
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        // the bell → the same «الإشعارات» page as everyone's
        GestureDetector(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => NotificationsPage(
              uid: AppNav.uid ?? '', name: AppNav.name ?? widget.name, role: AppNav.role ?? 'marketing_partner'))),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDark ? Colors.white.withOpacity(0.15) : AppColors.primary.withOpacity(0.1),
              border: Border.all(color: isDark ? Colors.white.withOpacity(0.2) : AppColors.primary.withOpacity(0.2), width: 1),
            ),
            child: const Icon(Icons.notifications, size: 24, color: Ar.info),
          ),
        ),
        Column(children: [
          Text(_today(context), style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Ar.grey.shade700)),
          Text(widget.name, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
          Text('شركة تسويق', style: TextStyle(fontSize: 12, color: isDark ? Colors.white60 : Ar.grey.shade600)),
        ]),
        GestureDetector(
          onTap: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const PartnerProfilePage()));
            final b = await PartnerLogo.load(fresh: true);
            if (mounted) setState(() => _logo = b);
          },
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDark ? Colors.white.withOpacity(0.15) : Colors.white.withOpacity(0.25),
              border: Border.all(color: isDark ? Colors.white.withOpacity(0.2) : AppColors.primary.withOpacity(0.2), width: 1.5),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 6, spreadRadius: 1, offset: const Offset(0, 2))],
            ),
            child: ClipOval(child: _logo != null ? Image.memory(_logo!, fit: BoxFit.cover) : const DefaultPhoto()),
          ),
        ),
      ]);
  }
}

/// «الملف الشخصي» of the company — the employee's profile page (profile_page.dart) for a company: the same header card,
/// sections and look, with its own data (no salary / attendance / KPIs).
class PartnerProfilePage extends StatefulWidget {
  const PartnerProfilePage({super.key});

  @override
  State<PartnerProfilePage> createState() => _PartnerProfilePageState();
}

class _PartnerProfilePageState extends State<PartnerProfilePage> {
  bool loading = true;
  Map<String, dynamic> data = {};
  Uint8List? _logo;

  static const _docs = {
    'contract': 'عقد التعاقد',
    'financial_plan': 'بلان الاتفاقات المالية',
    'execution_vision': 'رؤية الشركة للتنفيذ',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await lget('/partner/profile');
    final logo = await PartnerLogo.load(fresh: true);
    if (!mounted) return;
    setState(() {
      loading = false;
      data = lm(r['profile']);
      _logo = logo;
    });
  }

  Future<void> _openDoc(String kind) async {
    final r = await lget('/partner/files/$kind');
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

  Widget _section(String title, List<Widget> rows, Color textColor) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textColor)),
        const SizedBox(height: 12),
        GlassCard(radius: 24, padding: const EdgeInsets.all(16), child: Column(children: rows)),
        const SizedBox(height: 24),
      ]);

  Widget _row(IconData icon, String label, String value, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text('$label : $value', style: TextStyle(fontSize: 14, color: color))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(builder: (context, appController, _) {
      final isDark = appController.isDark;
      final primaryColor = isDark ? AppColors.primaryLight : AppColors.primary;
      final textColor = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
      final sub = isDark ? AppColors.onSurfaceVariantDark : AppColors.onSurfaceVariantLight;
      final files = lm(data['files']);
      final fixed = data['kind'] == 'fixed';
      return AppBackground(
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            extendBody: true,
            backgroundColor: Colors.transparent,
            bottomNavigationBar: GlassBottomNav(
              currentIndex: 4,
              onTap: (i) => AppNav.go(context, i, current: 4, uid: AppNav.uid ?? '', name: AppNav.name ?? '', role: AppNav.role ?? ''),
            ),
            body: loading
                ? Center(child: CircularProgressIndicator(color: primaryColor))
                : SafeArea(
                    bottom: false,
                    child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 120), children: [
                      Row(children: [
                        IconButton(icon: Icon(Icons.arrow_back, color: textColor), onPressed: () => Navigator.pop(context)),
                        Text(AppLocalizations.of(context, 'profile'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: textColor)),
                      ]),
                      const SizedBox(height: 16),
                      GlassCard(
                        radius: 24,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${data['name'] ?? ''}', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: textColor)),
                              const SizedBox(height: 6),
                              Text('شركة تسويق', style: TextStyle(color: sub, fontSize: 14)),
                              const SizedBox(height: 14),
                              SizedBox(
                                height: 46,
                                child: ElevatedButton.icon(
                                  // «تعديل الحساب» like the employee's: name, mobile, e-mail (by a code) and the password
                                  onPressed: () async {
                                    final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => PartnerEditAccountPage(data: data)));
                                    if (changed == true) _load();
                                  },
                                  icon: const Icon(Icons.edit_outlined, size: 18, color: Colors.white),
                                  label: Text(AppLocalizations.of(context, 'edit_account'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white)),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: primaryColor,
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                                    padding: const EdgeInsets.symmetric(horizontal: 18),
                                  ),
                                ),
                              ),
                            ]),
                          ),
                          const SizedBox(width: 14),
                          Container(
                            width: 108,
                            height: 108,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: data['status'] == 'active' ? Ar.green : Ar.red, width: 6),
                            ),
                            child: ClipOval(child: _logo != null ? Image.memory(_logo!, fit: BoxFit.cover) : const DefaultPhoto()),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 24),
                      _section('معلومات الشركة', [
                        _row(Icons.email, AppLocalizations.of(context, 'email'), '${data['email'] ?? '--'}', sub),
                        _row(Icons.phone, AppLocalizations.of(context, 'phone'), '${data['phone'] ?? '--'}', sub),
                        _row(Icons.event, 'تاريخ التعاقد', '${data['contractDate'] ?? '--'}', sub),
                        _row(Icons.supervisor_account, 'المدير المباشر', '${data['manager'] ?? '--'}', sub),
                        _row(Icons.account_tree, 'المدير العام', '${data['generalManager'] ?? '--'}', sub),
                        _row(Icons.info, 'الوضع', data['status'] == 'active' ? 'متعاقد' : 'تم فسخ التعاقد', sub),
                      ], textColor),
                      _section('المحاسبة', [
                        _row(Icons.account_balance, 'المحاسبه', fixed ? 'مبلغ ثابت' : 'بالعمولة', sub),
                        fixed
                            ? _row(Icons.money, 'المبلغ الشهري', JphUi.money(data['monthlyFee']), sub)
                            : _row(Icons.percent_rounded, 'نسبة العمولة', JphUi.pct(data['defaultPct']), sub),
                      ], textColor),
                      _section('الحملات', [
                        if (ll(data['campaigns']).isEmpty) _row(Icons.ads_click_rounded, 'الحملات', 'مفيش حملات مربوطة', sub),
                        for (final c in ll(data['campaigns']))
                          _row(Icons.ads_click_rounded, '${c['name']}', c['active'] == true ? 'شغالة' : 'موقوفة', sub),
                      ], textColor),
                      _section('المستندات', [
                        for (final e in _docs.entries)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(files[e.key] != null ? Icons.check_circle_rounded : Icons.description_outlined,
                                color: files[e.key] != null ? Ar.green : sub),
                            title: Text(e.value, style: TextStyle(color: textColor, fontWeight: FontWeight.w700)),
                            subtitle: Text(files[e.key] != null ? '${lm(files[e.key])['fileName']}' : 'لسه مترفعش', style: TextStyle(color: sub)),
                            trailing: files[e.key] != null
                                ? IconButton(tooltip: 'عرض', icon: const Icon(Icons.visibility_rounded), onPressed: () => _openDoc(e.key))
                                : null,
                          ),
                      ], textColor),
                    ]),
                  ),
          ),
        ),
      );
    });
  }
}

/// «تعديل الحساب» of the company — the employee's edit page (edit_profile_page.dart): the same frame, card and fields,
/// for its name, mobile and e-mail (a new e-mail is kept after the code sent to it, on the same OTP page as «نسيت كلمة
/// المرور»), and its password on the same page.
class PartnerEditAccountPage extends StatefulWidget {
  final Map<String, dynamic> data;
  const PartnerEditAccountPage({super.key, required this.data});

  @override
  State<PartnerEditAccountPage> createState() => _PartnerEditAccountPageState();
}

class _PartnerEditAccountPageState extends State<PartnerEditAccountPage> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: '${widget.data['name'] ?? ''}');
  late final _phone = TextEditingController(text: '${widget.data['phone'] ?? ''}');
  late final _email = TextEditingController(text: '${widget.data['email'] ?? ''}');
  final _current = TextEditingController(), _next = TextEditingController(), _confirm = TextEditingController();
  bool _loading = false;
  /// a new photo (its logo) picked here, sent with «حفظ»
  Uint8List? _newLogo;

  Future<void> _pickLogo() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 80, maxWidth: 1024, maxHeight: 1024);
    if (x == null) return;
    final b = await x.readAsBytes();
    if (b.length > 3 * 1024 * 1024) return _say('الصورة أكبر من 3 ميجا');
    setState(() => _newLogo = b);
  }

  /// the type from the content (the server checks the same signatures)
  static String _mimeOf(Uint8List b) {
    if (b.length > 4 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return 'image/png';
    if (b.length > 12 && String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' && String.fromCharCodes(b.sublist(8, 12)) == 'WEBP') return 'image/webp';
    return 'image/jpeg';
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _email, _current, _next, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  void _say(Object? m, {bool ok = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${m ?? ''}'), backgroundColor: ok ? Ar.green : Ar.red));
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    var changed = false;
    try {
      // 0) its photo (logo)
      if (_newLogo != null) {
        final mime = _mimeOf(_newLogo!);
        final r = await lpost('/partner/files/logo',
            {'fileName': 'logo.${mime.split('/').last}', 'mime': mime, 'data': base64Encode(_newLogo!)}, method: 'put');
        if (r['success'] == false) return _say(r['message']);
        PartnerLogo.bytes = _newLogo;
        _newLogo = null;
        changed = true;
      }
      // 1) name / mobile
      final body = <String, dynamic>{
        if (_name.text.trim() != '${widget.data['name'] ?? ''}') 'name': _name.text.trim(),
        if (_phone.text.trim() != '${widget.data['phone'] ?? ''}') 'phone': _phone.text.trim(),
      };
      if (body.isNotEmpty) {
        final r = await lpost('/partner/account', body, method: 'patch');
        if (r['success'] == false) return _say(r['message']);
        changed = true;
        if (body['name'] != null) AppNav.name = '${body['name']}';
      }
      // 2) a new e-mail: the code goes to it, entered on the OTP page
      final email = _email.text.trim().toLowerCase();
      if (email.isNotEmpty && email != '${widget.data['email'] ?? ''}'.toLowerCase()) {
        final r = await lpost('/partner/account/email', {'email': email});
        if (r['success'] == false) return _say(r['message']);
        if (!mounted) return;
        final done = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => OtpPage(
              identifier: email,
              sentTo: '${r['sentTo'] ?? email}',
              verify: (code) => lpost('/partner/account/email/verify', {'code': code}),
              resend: () => lpost('/partner/account/email', {'email': email}, ok: 'اتبعت كود جديد ✅'),
            )));
        if (done != true) return _say('الإيميل متغيرش — لازم تدخل الكود');
        changed = true;
      }
      // 3) the password, on the same page
      if (_next.text.isNotEmpty) {
        final r = await ApiService.changePassword(uid: AppNav.uid ?? '', oldPass: _current.text, newPass: _next.text);
        if (r['success'] == false) return _say(r['message']);
        changed = true;
      }
      if (!mounted) return;
      if (!changed) return _say('مفيش تغيير');
      _say('اتحفظ ✅', ok: true);
      Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  InputDecoration _deco(String label, IconData icon, Color primaryColor) => InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: primaryColor),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      );

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<AppController>(context).isDark;
    final primaryColor = isDark ? AppColors.primaryLight : AppColors.primary;
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(AppLocalizations.of(context, 'edit_account')),
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context)),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: Column(children: [
              // its photo (logo) — like the employee's «تعديل الملف الشخصي»
              GestureDetector(
                onTap: _loading ? null : _pickLogo,
                child: Stack(children: [
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: primaryColor, width: 2),
                      color: isDark ? AppColors.surfaceVariantDark : Ar.grey[200],
                      image: (_newLogo ?? PartnerLogo.bytes) != null
                          ? DecorationImage(image: MemoryImage((_newLogo ?? PartnerLogo.bytes)!), fit: BoxFit.cover)
                          : null,
                    ),
                    child: (_newLogo ?? PartnerLogo.bytes) == null
                        ? Icon(Icons.business_rounded, size: 40, color: isDark ? Colors.white54 : Colors.black45)
                        : null,
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(color: primaryColor, shape: BoxShape.circle),
                      child: const Icon(Icons.camera_alt, color: Colors.white, size: 20),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 8),
              Text('اضغط على الصورة لتغييرها', style: TextStyle(fontSize: 12.5, color: isDark ? Colors.white60 : Colors.black54)),
              const SizedBox(height: 16),
              GlassCard(
                radius: 24,
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  TextFormField(
                    controller: _name,
                    decoration: _deco('اسم الشركة', Icons.business_rounded, primaryColor),
                    validator: (v) => (v ?? '').trim().length < 2 ? 'اكتب اسم الشركة' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _phone,
                    decoration: _deco(AppLocalizations.of(context, 'phone'), Icons.phone, primaryColor),
                    keyboardType: TextInputType.phone,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _email,
                    decoration: _deco(AppLocalizations.of(context, 'email'), Icons.email, primaryColor),
                    keyboardType: TextInputType.emailAddress,
                    validator: (v) => (v ?? '').isNotEmpty && !(v ?? '').contains('@') ? 'Enter a valid email' : null,
                  ),
                ]),
              ),
              const SizedBox(height: 16),
              GlassCard(
                radius: 24,
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text('تغيير كلمة المرور (اختياري)', style: TextStyle(fontWeight: FontWeight.w800, color: isDark ? Colors.white : Colors.black87)),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _current,
                    obscureText: true,
                    decoration: _deco('كلمة المرور الحالية', Icons.lock_outline_rounded, primaryColor),
                    validator: (v) => _next.text.isNotEmpty && (v ?? '').isEmpty ? 'اكتب كلمة المرور الحالية' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _next,
                    obscureText: true,
                    decoration: _deco('كلمة المرور الجديدة', Icons.lock_reset_rounded, primaryColor),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _confirm,
                    obscureText: true,
                    decoration: _deco('تأكيد كلمة المرور الجديدة', Icons.lock_rounded, primaryColor),
                    validator: (v) => (v ?? '') != _next.text ? 'كلمتين المرور مش زي بعض' : null,
                  ),
                ]),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _loading ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _loading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : Text(AppLocalizations.of(context, 'save_changes'),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
