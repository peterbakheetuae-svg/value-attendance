import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/api.dart' show kApiBaseUrl;
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import 'leads_api.dart';

/// إعدادات الليدز / الربط: Value Aqar (its inquiries come in as leads; its projects and units wait here until the office
/// adopts them as تسويق or حصري) and Meta lead ads (every lead form's answers land on a campaign by themselves).
/// Keys and tokens are written here and never shown back (only the last 4 characters of the key).
class LeadsIntegrationsView extends StatefulWidget {
  final bool isDark;
  const LeadsIntegrationsView({super.key, required this.isDark});

  @override
  State<LeadsIntegrationsView> createState() => _LeadsIntegrationsViewState();
}

class _LeadsIntegrationsViewState extends State<LeadsIntegrationsView> {
  Map<String, dynamic> _d = {};
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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()));
    if (_d['success'] == false) return Text('${_d['message']}', style: TextStyle(color: JphUi.sub(isDark)));
    final va = lm(_d['valueaqar']);
    final meta = lm(_d['meta']);
    final projects = ll(_d['projects']);
    final shown = projects.where((p) => p['status'] == _filter).toList();
    final counts = {for (final s in ['new', 'adopted', 'ignored']) s: projects.where((p) => p['status'] == s).length};
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('الربط'), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
      Text(tr('الليدز من فاليو عقار وإعلانات Meta بتنزل لوحدها، والمشاريع الواردة تختار منها اللي تسوقه أو حصري.'), style: TextStyle(color: JphUi.sub(isDark))),
      const SizedBox(height: 10),
      _card(tr('فاليو عقار'), Icons.apartment_rounded, Ar.accent, [
        _status(va),
        const SizedBox(height: 8),
        _line(tr('رابط الـ Webhook'), '$kApiBaseUrl/public/hooks/valueaqar', copy: true, mono: true),
        _line(tr('الهيدر'), 'x-value-key', copy: true, mono: true),
        _line(tr('المفتاح'), va['hasKey'] == true ? '${va['keyHint']}' : tr('لسه متعملش')),
        _campaignPicker('valueaqar', va['campaignId']),
        Wrap(spacing: 8, runSpacing: 8, children: [
          dirBtn(isDark, va['hasKey'] == true ? tr('مفتاح جديد') : tr('اعمل مفتاح'), Icons.key_rounded, _newKey, primary: va['hasKey'] != true),
          dirBtn(isDark, va['active'] == true ? tr('إيقاف') : tr('تشغيل'), Icons.power_settings_new_rounded, () => _patch('valueaqar', {'active': va['active'] != true})),
        ]),
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
        _line(tr('Callback URL'), '$kApiBaseUrl/public/hooks/meta', copy: true, mono: true),
        _line(tr('Verify token'), '${meta['verifyToken'] ?? ''}', copy: true, mono: true),
        _line(tr('Access token'), meta['hasToken'] == true ? tr('متحفظ ✅') : tr('لسه متحطش')),
        _campaignPicker('meta', meta['campaignId']),
        Wrap(spacing: 8, runSpacing: 8, children: [
          dirBtn(isDark, meta['hasToken'] == true ? tr('غيّر التوكن') : tr('حط التوكن'), Icons.key_rounded, _token, primary: meta['hasToken'] != true),
          dirBtn(isDark, tr('Verify token جديد'), Icons.refresh_rounded, () => _patch('meta', {'newVerifyToken': true})),
          dirBtn(isDark, meta['active'] == true ? tr('إيقاف') : tr('تشغيل'), Icons.power_settings_new_rounded, () => _patch('meta', {'active': meta['active'] != true})),
        ]),
        const Divider(height: 26),
        Text(tr('كل حملة وفورم Meta بتاعها'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
        Text(tr('الليد بينزل على الحملة اللي فورمها اتربط، وإلا على الحملة الافتراضية فوق.'), style: TextStyle(color: JphUi.sub(isDark))),
        const SizedBox(height: 6),
        for (final c in ll(_d['campaigns']))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.ads_click_rounded),
            title: Text('${c['name']}', style: const TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Text(c['metaFormId'] == null ? tr('مش مربوطة') : 'Form ${c['metaFormId']}'),
            trailing: const Icon(Icons.edit_rounded, size: 18),
            onTap: () => _form(c),
          ),
      ]),
    ]);
  }
}
