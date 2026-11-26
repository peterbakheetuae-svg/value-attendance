import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../../../core/api.dart' show kApiBaseUrl;
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import 'leads_api.dart';
import 'leads_routing.dart';
import '../login/otp_page.dart';
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';

/// إعدادات الليدز / الربط: Value Aqar (a direct channel: its inquiries come in as leads, given by the rule of their
/// property / project / the default one; its projects and units wait here until the office adopts them as تسويق or
/// حصري) and Meta lead ads (every lead form's answers land on a campaign, given to its salesmen as it says).
/// Keys and tokens are written here and never shown back (only the last 4 characters of the key).
class LeadsIntegrationsView extends StatefulWidget {
  final bool isDark;
  const LeadsIntegrationsView({super.key, required this.isDark});

  @override
  State<LeadsIntegrationsView> createState() => _LeadsIntegrationsViewState();
}

class _LeadsIntegrationsViewState extends State<LeadsIntegrationsView> {
  Map<String, dynamic> _d = {};
  Map<String, dynamic> _oauth = {};
  bool _loading = true;
  String _filter = 'new';

  bool get isDark => widget.isDark;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await lget('/integrations');
    if (!mounted) return;
    setState(() {
      _loading = false;
      _d = r;
    });
    if (r['partner'] != true && r['success'] != false) _loadOauth();
  }

  /// the official Meta connection's state (GET /integrations/meta/oauth/status) — never a token
  Future<void> _loadOauth() async {
    final r = await lget('/integrations/meta/oauth/status');
    if (mounted) setState(() => _oauth = r['success'] == false ? {} : r);
  }

  Future<void> _copy(String text, [String? msg]) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) JphUi.toast(context, {'success': true, 'message': msg ?? tr('اتنسخ ✅')});
  }

  Future<void> _patch(String source, Map<String, dynamic> body) async {
    final r = await lpost('/integrations/$source', body, method: 'patch', ok: tr('اتحفظ ✅'));
    if (mounted) JphUi.toast(context, r);
    _load();
  }

  String _when(Object? iso) {
    final t = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    if (t == null) return tr('لسه موصلش حاجة');
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  Widget _card(String title, IconData icon, Color color, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: JphUi.box(isDark),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(icon, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
          ]),
          const SizedBox(height: 10),
          ...children,
        ]),
      );

  Widget _line(String label, String value, {bool copy = false, bool mono = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          SizedBox(width: 120, child: Text(label, style: TextStyle(color: JphUi.sub(isDark), fontWeight: FontWeight.w700))),
          Expanded(
            child: SelectableText(value,
                style: TextStyle(color: JphUi.text(isDark), fontWeight: FontWeight.w800, fontFamily: mono ? 'monospace' : null, fontSize: mono ? 13 : null)),
          ),
          if (copy) IconButton(tooltip: tr('نسخ'), icon: const Icon(Icons.copy_rounded, size: 18), onPressed: () => _copy(value)),
        ]),
      );

  Widget _campaignPicker(String source, Object? current) {
    final cs = ll(_d['campaigns']);
    final value = cs.any((c) => c['id'] == current) ? '$current' : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: DropdownButtonFormField<String?>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: tr('الحملة اللي الليدز تنزل عليها'), border: const OutlineInputBorder()),
        items: [
          DropdownMenuItem<String?>(value: null, child: Text(tr('من غير حملة'))),
          for (final c in cs) DropdownMenuItem<String?>(value: '${c['id']}', child: Text('${c['name']}', overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (v) => _patch(source, {'campaignId': v}),
      ),
    );
  }

  Widget _status(Map<String, dynamic> x) => Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        pill(x['active'] == true ? tr('شغال') : tr('موقوف'), x['active'] == true ? Ar.green : Ar.grey),
        Text('${tr('آخر استلام')}: ${_when(x['lastAt'])}', style: TextStyle(color: JphUi.sub(isDark))),
        if ('${x['lastError'] ?? ''}'.isNotEmpty) pill('${x['lastError']}', Ar.red, dot: false),
      ]);

  // ------------------------------------------------------------------ Value Aqar
  Future<void> _newKey() async {
    final had = lm(_d['valueaqar'])['hasKey'] == true;
    if (had) {
      final sure = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr('مفتاح جديد؟')),
          content: Text(tr('المفتاح القديم هيقف فورًا، ولازم صاحب فاليو عقار يحط الجديد في الـ Webhooks.')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('لأ'))),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('أيوه'))),
          ],
        ),
      );
      if (sure != true) return;
    }
    final r = await lpost('/integrations/valueaqar/key', {});
    if (!mounted) return;
    if (r['success'] == false) return JphUi.toast(context, r);
    final key = '${r['key']}';
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('المفتاح — بيظهر مرة واحدة بس')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('انسخه وابعته لصاحب فاليو عقار بطريقة آمنة. مش هيظهر تاني؛ لو ضاع اعمل مفتاح جديد.')),
          const SizedBox(height: 10),
          SelectableText(key, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w800)),
        ]),
        actions: [
          FilledButton.icon(
            onPressed: () {
              _copy(key);
              Navigator.pop(c);
            },
            icon: const Icon(Icons.copy_rounded),
            label: Text(tr('نسخ وقفل')),
          ),
        ],
      ),
    );
    _load();
  }

  Future<void> _adopt(Map<String, dynamic> p) async {
    final as = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text('${p['name']}', style: const TextStyle(fontWeight: FontWeight.w900))),
          ListTile(
            leading: const Icon(Icons.campaign_rounded, color: Ar.accent),
            title: Text(tr('اعتمده تسويق')),
            subtitle: Text(tr('بنسب التسويق المعتادة — تقدر تغيرها من المشروع')),
            onTap: () => Navigator.pop(c, 'marketing'),
          ),
          ListTile(
            leading: const Icon(Icons.workspace_premium_rounded, color: Ar.green),
            title: Text(tr('اعتمده حصري')),
            subtitle: Text(tr('بنسب الحصري المعتادة — تقدر تغيرها من المشروع')),
            onTap: () => Navigator.pop(c, 'exclusive'),
          ),
        ]),
      ),
    );
    if (as == null) return;
    final r = await lpost('/integrations/projects/${p['id']}/adopt', {'as': as});
    if (mounted) {
      JphUi.toast(context, r['success'] == false ? r : {'success': true, 'message': '${tr('اتعتمد ✅ — الوحدات')}: ${r['units'] ?? 0}'});
    }
    _load();
  }

  Future<void> _ignore(Map<String, dynamic> p, bool undo) async {
    final r = await lpost('/integrations/projects/${p['id']}/ignore', {'undo': undo}, ok: undo ? tr('رجع للجديد') : tr('اتجاهل'));
    if (mounted) JphUi.toast(context, r);
    _load();
  }

  Widget _project(Map<String, dynamic> p) {
    final st = '${p['status']}';
    final proj = lm(p['project']);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(border: Border.all(color: JphUi.sub(isDark).withValues(alpha: 0.25)), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p['name'] ?? p['externalId']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
            Text(
              [
                if ('${p['developer'] ?? ''}'.isNotEmpty) '${p['developer']}',
                if ('${p['location'] ?? ''}'.isNotEmpty) '${p['location']}',
                '${tr('وحدات')}: ${p['units'] ?? 0}',
              ].join(' · '),
              style: TextStyle(color: JphUi.sub(isDark)),
            ),
            if (st == 'adopted' && proj.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: pill('${proj['kind'] == 'exclusive' ? tr('حصري') : tr('تسويق')} · ${proj['name']}', proj['kind'] == 'exclusive' ? Ar.green : Ar.accent),
              ),
          ]),
        ),
        if (st == 'new') ...[
          dirBtn(isDark, tr('اعتماد'), Icons.check_rounded, () => _adopt(p), primary: true),
          IconButton(tooltip: tr('تجاهل'), icon: const Icon(Icons.visibility_off_rounded), onPressed: () => _ignore(p, false)),
        ],
        if (st == 'ignored') TextButton(onPressed: () => _ignore(p, true), child: Text(tr('رجّعه'))),
      ]),
    );
  }

  // ------------------------------------------------------------------ Meta
  /// «اربط بحساب فيسبوك»: the official Facebook Login dialog opens in the browser; the server finishes the connection
  Future<void> _connectFacebook() async {
    final r = await lpost('/integrations/meta/oauth/start', {});
    if (!mounted) return;
    if (r['success'] == false) return JphUi.toast(context, r);
    if (r['configured'] != true) {
      final missing = ((r['missing'] as List?) ?? const []).join('، ');
      return JphUi.toast(context, {'success': false, 'message': '${tr('ربط فيسبوك مش متجهز على السيرفر — ناقص')}: $missing'});
    }
    await openUrl('${r['url']}');
    if (mounted) JphUi.toast(context, {'success': true, 'message': tr('كمّل في المتصفح، وبعدها ارجع هنا ودوس «حدّث الحالة»')});
  }

  List<Widget> _oauthStatus() {
    if (_oauth.isEmpty) return const [];
    final connected = _oauth['connected'] == true;
    // required permissions block the connection; optional ones (business_management) only limit what it reaches
    final missingRequired = ((_oauth['missingRequired'] as List?) ?? const []).cast<Object?>();
    // ads_read is the Insights feature's own permission (reported on its own line, below)
    final missingOptional = ((_oauth['missingOptional'] as List?) ?? const []).cast<Object?>().where((s) => s != 'ads_read').toList();
    final insights = (_oauth['insights'] as Map?) ?? const {};
    final expires = DateTime.tryParse('${_oauth['expiresAt'] ?? ''}')?.toLocal();
    // the server's one explicit state (GET /integrations/meta/oauth/status → state); older servers send none
    const states = {
      'not_configured': 'مش متجهز على السيرفر',
      'not_connected': 'مش متربط',
      'authorization_pending': 'مستني تكمّل الربط على فيسبوك',
      'connected': 'متربط — لسه ما حصلش سحب بيانات بعد الربط',
      'permission_denied': 'الصلاحيات اترفضت أو ناقصة',
      'token_expired_or_revoked': 'الربط انتهى أو اتلغى',
      'sync_failed': 'آخر سحب بيانات فشل',
      'sync_succeeded': 'آخر سحب بيانات نجح ✅',
    };
    final state = states['${_oauth['state'] ?? ''}'];
    final lines = <String>[
      if (state != null) '${tr('الحالة')}: ${tr(state)}',
      if (_oauth['configured'] != true) '${tr('الربط الرسمي مش متجهز على السيرفر — ناقص')}: ${((_oauth['missing'] as List?) ?? const []).join('، ')}',
      connected ? tr('متربط بحساب فيسبوك ✅') : tr('لسه مش متربط بحساب فيسبوك'),
      if (_oauth['tokenValid'] == false) tr('الربط انتهى أو اتلغى من فيسبوك — اعمل إعادة ربط'),
      if (expires != null) '${tr('صلاحية الربط لحد')}: ${expires.year}-${expires.month.toString().padLeft(2, '0')}-${expires.day.toString().padLeft(2, '0')}',
      if (missingRequired.isNotEmpty) '${tr('صلاحيات مطلوبة ناقصة — اعمل إعادة ربط واسمح بيها')}: ${missingRequired.join('، ')}',
      if (missingOptional.isNotEmpty) '${tr('صلاحية اختيارية مش متاحة (الربط شغال؛ صفحات الـ Business portfolio بس مش هتظهر)')}: ${missingOptional.join('، ')}',
      if (connected && insights['available'] == true) tr('أرقام الإعلانات (الصرف والتكلفة): متاحة ✅'),
      if (connected && insights['available'] == false) tr('أرقام الإعلانات (الصرف والتكلفة) مش متاحة: صلاحية ads_read ما اتسمحتش — الليدز شغالة عادي؛ اعمل إعادة ربط واسمح بيها'),
      if (connected && insights['available'] == null) tr('أرقام الإعلانات: لسه ما اتعرفش لو الصلاحية متاحة (بتتعرف في أول سحب)'),
      '${tr('آخر سحب')}: ${_when(_oauth['lastSyncAt'])}',
      if ('${_oauth['lastError'] ?? ''}'.isNotEmpty) '${tr('آخر مشكلة')}: ${_oauth['lastError']}',
    ];
    return [
      const Divider(height: 26),
      Text(tr('الربط الرسمي مع فيسبوك'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
      for (final l in lines) Text(l, style: TextStyle(color: JphUi.sub(isDark))),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        dirBtn(isDark, connected ? tr('إعادة الربط بفيسبوك') : tr('اربط بحساب فيسبوك'), Icons.facebook_rounded,
            _oauth['configured'] == true ? _connectFacebook : null, primary: !connected),
        dirBtn(isDark, tr('حدّث الحالة'), Icons.refresh_rounded, _load),
      ]),
    ];
  }

  /// one Facebook page (a page token) or all the pages of a user token: each kept with its own token, subscribed to leads
  Future<void> _addPage() async {
    final t = TextEditingController();
    final ok = await leadForm(context, isDark, tr('ربط صفحة فيسبوك'), (set) => [
          Text(tr('الصق توكن الصفحة (Page access token) أو توكن حسابك (User token) وهيتربط كل الصفحات اللي عليه. بيتحفظ عندنا ومش بيظهر تاني.'),
              style: TextStyle(color: JphUi.sub(isDark))),
          JphUi.input(isDark: isDark, label: tr('Access token'), controller: t, icon: Icons.key_rounded, big: false),
        ], () async {
      final r = await lpost('/integrations/meta/pages', {'accessToken': t.text.trim()}, ok: tr('اتربطت ✅'));
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    });
    if (ok) _load();
  }

  Future<void> _removePage(Map<String, dynamic> p) async {
    final r = await lpost('/integrations/meta/pages/${p['id']}/remove', {}, ok: tr('اتشالت'));
    if (mounted) JphUi.toast(context, r);
    _load();
  }

  Future<void> _syncNow() async {
    final r = await lpost('/integrations/meta/sync', {});
    if (!mounted) return;
    JphUi.toast(context, r['success'] == false ? r : {'success': true, 'message': '${tr('دخل')} ${r['added'] ?? 0} ${tr('ليد جديد من Meta')}'});
    _load();
  }

  List<Widget> _pages() {
    final pages = ll(_d['metaPages']);
    return [
      ..._oauthStatus(),
      const Divider(height: 26),
      Text(tr('صفحات فيسبوك المربوطة'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
      Text(tr('كل صفحة بتوكن بتاعها، والليدز بتنزل لوحدها من فورمات الصفحة على الحملة المربوطة (كل 10 دقايق وكمان لحظة ما الليد يتعمل).'),
          style: TextStyle(color: JphUi.sub(isDark))),
      if (pages.isEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(tr('لسه مفيش صفحات'), style: TextStyle(color: JphUi.sub(isDark)))),
      for (final p in pages)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.flag_rounded, color: Color(0xFF1877F2)),
          title: Text('${p['name']}'.isEmpty ? '${p['id']}' : '${p['name']}', style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text([
            p['subscribed'] == true ? tr('مشترك في الليدز ✅') : tr('مش مشترك'),
            if ('${p['lastError'] ?? ''}'.isNotEmpty) '${p['lastError']}',
          ].join(' — ')),
          trailing: IconButton(tooltip: tr('شيل الصفحة'), icon: const Icon(Icons.link_off_rounded), onPressed: () => _removePage(p)),
        ),
      Wrap(spacing: 8, runSpacing: 8, children: [
        // pasting a token stays for backward compatibility; the official way is the button above
        dirBtn(isDark, tr('ربط بتوكن (متقدم)'), Icons.add_link_rounded, _addPage, primary: pages.isEmpty && _oauth['configured'] != true),
        dirBtn(isDark, tr('اسحب الليدز دلوقتي'), Icons.sync_rounded, _syncNow),
      ]),
    ];
  }

  /// a new Verify token: Meta's webhook settings must then get the new one — so only after the code e-mailed to you
  Future<void> _newVerifyToken() async {
    if ('${lm(_d['meta'])['verifyToken'] ?? ''}'.isEmpty) return _patch('meta', {'newVerifyToken': true});
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Verify token جديد؟')),
        content: Text(tr('القديم هيقف: لو حد عدّل إعدادات الـ Webhooks في تطبيقات Meta لازم يحط الجديد. هيوصلك كود على إيميلك للتأكيد.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('لأ'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('ابعت الكود'))),
        ],
      ),
    );
    if (sure != true) return;
    final r = await lpost('/integrations/meta/verify-token/code', {});
    if (!mounted) return;
    if (r['success'] == false) return JphUi.toast(context, r);
    final done = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => OtpPage(
          identifier: '',
          sentTo: '${r['sentTo'] ?? ''}',
          verify: (code) => lpost('/integrations/meta', {'newVerifyToken': true, 'code': code}, method: 'patch'),
          resend: () => lpost('/integrations/meta/verify-token/code', {}, ok: tr('اتبعت كود جديد ✅')),
        )));
    if (done == true && mounted) JphUi.toast(context, {'success': true, 'message': tr('اتعمل Verify token جديد ✅')});
    _load();
  }

  Future<void> _token() async {
    final t = TextEditingController();
    final ok = await leadForm(context, isDark, tr('توكن Meta'), (set) => [
          Text(tr('الصق هنا الـ Page / System User access token. بيتحفظ عندنا ومش بيظهر تاني.'), style: TextStyle(color: JphUi.sub(isDark))),
          JphUi.input(isDark: isDark, label: tr('Access token'), controller: t, icon: Icons.key_rounded, big: false),
        ], () async {
      final r = await lpost('/integrations/meta', {'accessToken': t.text.trim()}, method: 'patch', ok: tr('اتحفظ ✅'));
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    });
    if (ok) _load();
  }

  Future<void> _form(Map<String, dynamic> c) async {
    final f = TextEditingController(text: '${c['metaFormId'] ?? ''}');
    final ok = await leadForm(context, isDark, '${tr('فورم Meta للحملة')}: ${c['name']}', (set) => [
          Text(tr('رقم الـ Lead Form من Meta (Ads Manager ← Forms library). سيبه فاضي عشان تشيل الربط.'), style: TextStyle(color: JphUi.sub(isDark))),
          JphUi.input(isDark: isDark, label: tr('Form ID'), controller: f, number: true, icon: Icons.dynamic_form_rounded, big: false),
        ], () async {
      final r = await lpost('/integrations/meta/forms', {'campaignId': c['id'], 'formId': f.text.trim()}, method: 'patch', ok: tr('اتحفظ ✅'));
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    });
    if (ok) _load();
  }

  // ------------------------------------------------------------------ توزيع ليدز فاليو عقار
  List<Map<String, dynamic>> get _people => ll(_d['people']);

  Future<void> _editRoute({Map<String, dynamic>? rule, String target = 'default'}) async {
    final r = rule ?? const <String, dynamic>{};
    var t = '${r['target'] ?? target}';
    String? ext = r['externalId'] == null ? null : '${r['externalId']}';
    final projects = ll(_d['projects']).where((p) => p['status'] != 'deleted').toList();
    final props = ll(_d['properties']);
    final title = t == 'default' ? tr('التوزيع الافتراضي لفاليو عقار') : rule == null ? tr('قاعدة توزيع جديدة') : '${tr('توزيع')}: ${r['label']}';
    final ok = await editRoute(context, isDark, title, _people,
        mode: '${r['mode'] ?? 'online'}',
        selected: [for (final x in (r['assignees'] as List? ?? const [])) '$x'],
        header: rule != null || t == 'default'
            ? null
            : (set) => [
                  Wrap(spacing: 6, children: [
                    ChoiceChip(selected: t == 'project', label: Text(tr('مشروع')), onSelected: (_) => set(() { t = 'project'; ext = null; })),
                    ChoiceChip(selected: t == 'property', label: Text(tr('عقار')), onSelected: (_) => set(() { t = 'property'; ext = null; })),
                  ]),
                  refPicker(
                    context,
                    isDark,
                    t == 'project' ? tr('المشروع على فاليو عقار') : tr('العقار على فاليو عقار'),
                    t == 'project' ? Icons.apartment_rounded : Icons.home_work_rounded,
                    t == 'project'
                        ? [for (final p in projects) {'id': '${p['externalId']}', 'name': '${p['name'] ?? p['externalId']}'}]
                        : [for (final p in props) {'id': '${p['externalId']}', 'name': [p['name'], if ('${p['location'] ?? ''}'.isNotEmpty) p['location']].join(' · ')}],
                    ext,
                    (v) => set(() => ext = v),
                    allowNone: false,
                  ),
                  if ((t == 'project' ? projects : props).isEmpty)
                    Text(t == 'project' ? tr('لسه مفيش مشاريع واصلة من فاليو عقار') : tr('لسه مفيش عقارات واصلة من فاليو عقار'),
                        style: TextStyle(color: JphUi.sub(isDark))),
                ],
        save: (mode, ids) async {
          if (t != 'default' && (ext == null || ext!.isEmpty)) {
            JphUi.toast(context, {'success': false, 'message': tr('اختار المشروع / العقار')});
            return false;
          }
          final res = await lpost('/integrations/routes', {'target': t, 'externalId': t == 'default' ? '' : ext, 'mode': mode, 'assignees': ids},
              method: 'put', ok: tr('اتحفظ ✅'));
          if (mounted) JphUi.toast(context, res);
          return res['success'] != false;
        });
    if (ok) _load();
  }

  Future<void> _removeRoute(Map<String, dynamic> r) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('تشيل القاعدة دي؟')),
        content: Text('${r['label']} — ${tr('ليدزه هتمشي على التوزيع الافتراضي')}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('لأ'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('أيوه'))),
        ],
      ),
    );
    if (sure != true) return;
    final res = await lpost('/integrations/routes/${r['id']}/remove', {}, ok: tr('اتشالت'));
    if (mounted) JphUi.toast(context, res);
    _load();
  }

  Widget _routeTile(Map<String, dynamic> r, {bool isDefault = false}) {
    final ids = [for (final x in (r['assignees'] as List? ?? const [])) '$x'];
    final t = '${r['target'] ?? 'default'}';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(color: (isDefault ? Ar.accent : JphUi.sub(isDark)).withValues(alpha: isDefault ? 0.6 : 0.25)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: Icon(isDefault ? Icons.alt_route_rounded : t == 'project' ? Icons.apartment_rounded : Icons.home_work_rounded, color: Ar.accent),
        title: Text(isDefault ? tr('التوزيع الافتراضي (أي استفسار ملوش قاعدة)') : '${t == 'project' ? tr('مشروع') : tr('عقار')}: ${r['label']}',
            style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
        subtitle: Text(r.isEmpty ? tr('مش متحدد — الليدز تنزل من غير سيلز والمدير يتنبّه') : routeSummary('${r['mode']}', ids, _people)),
        trailing: isDefault || r.isEmpty
            ? const Icon(Icons.edit_rounded, size: 18)
            : IconButton(tooltip: tr('شيل'), icon: const Icon(Icons.delete_outline_rounded), onPressed: () => _removeRoute(r)),
        onTap: () => _editRoute(rule: r.isEmpty ? null : r, target: t),
      ),
    );
  }

  List<Widget> _routes() {
    final rs = ll(_d['routes']);
    final def = rs.firstWhere((r) => r['target'] == 'default', orElse: () => <String, dynamic>{});
    final rest = rs.where((r) => r['target'] != 'default').toList();
    return [
      Text(tr('توزيع الليدز'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
      Text(tr('حدد لكل مشروع أو عقار السيلز اللي يستقبل ليدزه: سيلز واحد، أو بالدور على المتصلين، أو بالدور على الكل. أي استفسار ملوش قاعدة بيمشي على التوزيع الافتراضي.'),
          style: TextStyle(color: JphUi.sub(isDark))),
      const SizedBox(height: 8),
      _routeTile(def, isDefault: true),
      for (final r in rest) _routeTile(r),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: dirBtn(isDark, tr('قاعدة لمشروع / عقار'), Icons.add_rounded, () => _editRoute(target: 'project')),
      ),
    ];
  }

  Future<void> _campaignRoute(Map<String, dynamic> c) async {
    final ok = await editRoute(context, isDark, '${tr('توزيع ليدز الحملة')}: ${c['name']}', _people,
        mode: '${c['mode'] ?? 'turn'}',
        selected: [for (final x in (c['assignees'] as List? ?? const [])) '$x'],
        save: (mode, ids) async {
          final res = await lpost('/integrations/campaigns/${c['id']}', {'mode': mode, 'assignees': ids}, method: 'patch', ok: tr('اتحفظ ✅'));
          if (mounted) JphUi.toast(context, res);
          return res['success'] != false;
        });
    if (ok) _load();
  }

  // ------------------------------------------------------------------ Meta campaigns → our campaigns
  List<Map<String, dynamic>> _metaList = [];
  String? _metaErr;

  String _metaName(String id) {
    for (final m in [..._metaList, ...ll(_d['metaSeen'])]) {
      if ('${m['id']}' == id && '${m['name'] ?? ''}'.isNotEmpty) return '${m['name']}';
    }
    return id;
  }

  /// Meta campaigns leads came from that are linked to none of ours (their leads were not added)
  List<Widget> _unlinkedSeen() {
    final linked = {for (final c in ll(_d['campaigns'])) for (final m in (c['metaCampaignIds'] as List? ?? const [])) '$m'};
    final rows = ll(_d['metaSeen']).where((m) => !linked.contains('${m['id']}') && (m['skipped'] as num? ?? 0) > 0).toList();
    if (rows.isEmpty) return const [];
    return [
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: Ar.amber.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('حملات Meta وصل منها ليدز ومش مربوطة (الليدز دي مدخلتش):'), style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
          for (final m in rows)
            Text('• ${'${m['name']}'.isEmpty ? m['id'] : m['name']} (${m['id']}) — ${m['skipped']} ${tr('ليد')}', style: TextStyle(color: JphUi.sub(isDark))),
        ]),
      ),
    ];
  }

  Future<void> _metaLink(Map<String, dynamic> c) async {
    if (_metaList.isEmpty && _metaErr == null) {
      final r = await lget('/integrations/meta/campaigns');
      _metaList = ll(r['campaigns']);
      _metaErr = '${r['error'] ?? ''}'.isEmpty ? null : '${r['error']}';
    }
    if (!mounted) return;
    final chosen = {for (final m in (c['metaCampaignIds'] as List? ?? const [])) '$m'};
    final options = <String, String>{};
    for (final m in [..._metaList, ...ll(_d['metaSeen'])]) {
      final id = '${m['id']}';
      options.putIfAbsent(id, () => '${m['name'] ?? ''}'.isEmpty ? id : '${m['name']}${m['account'] != null ? ' · ${m['account']}' : ''}');
    }
    for (final id in chosen) {
      options.putIfAbsent(id, () => id);
    }
    final manual = TextEditingController();
    final ok = await leadForm(context, isDark, '${tr('حملات Meta لـ')} ${c['name']}', (set) => [
          Text(tr('اختار حملات Meta اللي ليدزها تنزل على الحملة دي. حملة Meta بتتربط بحملة واحدة بس من حملاتنا.'),
              style: TextStyle(color: JphUi.sub(isDark))),
          if (_metaErr != null)
            Text('${tr('مقدرناش نجيب الحملات من Meta')}: $_metaErr — ${tr('تقدر تكتب رقم الحملة بإيدك')}',
                style: const TextStyle(fontSize: 12.5, color: Ar.red)),
          for (final e in options.entries)
            CheckboxListTile(
              dense: true,
              value: chosen.contains(e.key),
              onChanged: (v) => set(() => v == true ? chosen.add(e.key) : chosen.remove(e.key)),
              title: Text(e.value, style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(e.key),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          Row(children: [
            Expanded(child: JphUi.input(isDark: isDark, label: tr('رقم حملة Meta (Campaign ID)'), controller: manual, number: true, icon: Icons.tag_rounded, big: false)),
            IconButton(
              icon: const Icon(Icons.add_circle_rounded),
              onPressed: () {
                final id = manual.text.replaceAll(RegExp(r'\D'), '');
                if (id.length < 3) return;
                set(() {
                  options.putIfAbsent(id, () => id);
                  chosen.add(id);
                  manual.clear();
                });
              },
            ),
          ]),
        ], () async {
      final r = await lpost('/leads/campaigns/${c['id']}/partner', {'metaCampaignIds': chosen.toList()}, method: 'patch', ok: tr('اتحفظ ✅'));
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    });
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()));
    if (_d['success'] == false) return Text('${_d['message']}', style: TextStyle(color: JphUi.sub(isDark)));
    final va = lm(_d['valueaqar']);
    final meta = lm(_d['meta']);
    final projects = ll(_d['projects']);
    final shown = projects.where((p) => p['status'] == _filter).toList();
    final counts = {for (final s in ['new', 'adopted', 'ignored']) s: projects.where((p) => p['status'] == s).length};
    // a marketing company: only Meta, and on its own campaigns only the choice of their Meta campaigns
    final ro = _d['partner'] == true;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('الربط'), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
      Text(tr('الليدز من فاليو عقار وإعلانات Meta بتنزل لوحدها، والمشاريع الواردة تختار منها اللي تسوقه أو حصري.'), style: TextStyle(color: JphUi.sub(isDark))),
      const SizedBox(height: 10),
      if (!ro) _card(tr('فاليو عقار'), Icons.apartment_rounded, Ar.accent, [
        _status(va),
        const SizedBox(height: 8),
        _line(tr('رابط الـ Webhook'), '$kApiBaseUrl/public/hooks/valueaqar', copy: true, mono: true),
        _line(tr('الهيدر'), 'x-value-key', copy: true, mono: true),
        _line(tr('المفتاح'), va['hasKey'] == true ? '${va['keyHint']}' : tr('لسه متعملش')),
        _line(tr('القناة'), tr('فاليو عقار — قناة مباشرة (من غير حملة)')),
        Wrap(spacing: 8, runSpacing: 8, children: [
          dirBtn(isDark, va['hasKey'] == true ? tr('مفتاح جديد') : tr('اعمل مفتاح'), Icons.key_rounded, _newKey, primary: va['hasKey'] != true),
          dirBtn(isDark, va['active'] == true ? tr('إيقاف') : tr('تشغيل'), Icons.power_settings_new_rounded, () => _patch('valueaqar', {'active': va['active'] != true})),
        ]),
        const Divider(height: 26),
        ..._routes(),
        const Divider(height: 26),
        Text(tr('المشاريع الواردة'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
        const SizedBox(height: 6),
        Wrap(spacing: 6, children: [
          for (final (k, l) in [('new', tr('جديدة')), ('adopted', tr('معتمدة')), ('ignored', tr('متجاهلة'))])
            ChoiceChip(selected: _filter == k, label: Text('$l (${counts[k]})'), onSelected: (_) => setState(() => _filter = k)),
        ]),
        const SizedBox(height: 8),
        if (shown.isEmpty) Text(tr('مفيش'), style: TextStyle(color: JphUi.sub(isDark))),
        for (final p in shown) _project(p),
      ]),
      _card(tr('إعلانات Meta (فيسبوك وإنستجرام)'), Icons.facebook_rounded, const Color(0xFF1877F2), [
        _status(meta),
        const SizedBox(height: 8),
        if (!ro) ...[
          _line(tr('Callback URL'), '$kApiBaseUrl/public/hooks/meta', copy: true, mono: true),
          _line(tr('Verify token'), '${meta['verifyToken'] ?? ''}', copy: true, mono: true),
        ],
        _line(tr('Access token'), meta['hasToken'] == true ? tr('متحفظ ✅') : tr('لسه متحطش')),
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0xFF1877F2).withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
          child: Text(tr('بيدخل بس ليدز حملات Meta اللي انت ربطتها بحملة من حملاتنا (تحت). أي حملة تانية على حافظة الأعمال مش بتدخل.'),
              style: TextStyle(fontWeight: FontWeight.w700, color: JphUi.text(isDark))),
        ),
        if (!ro) Wrap(spacing: 8, runSpacing: 8, children: [
          dirBtn(isDark, meta['hasToken'] == true ? tr('غيّر التوكن') : tr('حط التوكن'), Icons.key_rounded, _token, primary: meta['hasToken'] != true),
          dirBtn(isDark, tr('Verify token جديد'), Icons.refresh_rounded, _newVerifyToken),
          dirBtn(isDark, meta['active'] == true ? tr('إيقاف') : tr('تشغيل'), Icons.power_settings_new_rounded, () => _patch('meta', {'active': meta['active'] != true})),
        ]),
        if (!ro) ..._pages(),
        const Divider(height: 26),
        Text(tr('كل حملة: حملات Meta اللي بتغذيها والسيلز اللي بيستقبلوا'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
        Text(tr('الليد بينزل على الحملة اللي حملة Meta بتاعته (أو فورمه) مربوطة بيها، ويتوزع على السيلز بتوع الحملة بالطريقة اللي تختارها.'),
            style: TextStyle(color: JphUi.sub(isDark))),
        ..._unlinkedSeen(),
        const SizedBox(height: 6),
        for (final c in ll(_d['campaigns']))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.ads_click_rounded),
            title: Text('${c['name']}', style: const TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Text([
              (c['metaCampaignIds'] as List? ?? const []).isEmpty
                  ? tr('حملات Meta: مش مربوطة')
                  : '${tr('حملات Meta')}: ${[for (final m in (c['metaCampaignIds'] as List)) _metaName('$m')].join('، ')}',
              if (c['metaFormId'] != null) 'Form ${c['metaFormId']}',
              if (!ro) routeSummary('${c['mode']}', [for (final x in (c['assignees'] as List? ?? const [])) '$x'], _people),
            ].join('\n')),
            isThreeLine: !ro,
            trailing: Wrap(children: [
              if (!ro) IconButton(tooltip: tr('التوزيع على السيلز'), icon: const Icon(Icons.group_rounded, size: 20), onPressed: () => _campaignRoute(c)),
              IconButton(tooltip: tr('حملات Meta'), icon: const Icon(Icons.facebook_rounded, size: 20, color: Color(0xFF1877F2)), onPressed: () => _metaLink(c)),
              if (!ro) IconButton(tooltip: tr('فورم Meta'), icon: const Icon(Icons.edit_rounded, size: 18), onPressed: () => _form(c)),
            ]),
            onTap: () => ro ? _metaLink(c) : _campaignRoute(c),
          ),
      ]),
    ]);
  }
}
