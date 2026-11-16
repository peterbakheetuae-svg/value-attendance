import 'package:flutter/material.dart';

import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import 'leads_api.dart';

/// إعدادات الليدز / شركات التسويق: each marketing company's own sign-in (e-mail / mobile + password — not an employee
/// account) and the campaigns it runs. The company then sees only those campaigns' leads (and adds leads to them).
/// The companies themselves (name, fee / %) are added in الإعدادات ← شركات التسويق.
class LeadsPartnersView extends StatefulWidget {
  final bool isDark;
  const LeadsPartnersView({super.key, required this.isDark});

  @override
  State<LeadsPartnersView> createState() => _LeadsPartnersViewState();
}

class _LeadsPartnersViewState extends State<LeadsPartnersView> {
  List<Map<String, dynamic>> _companies = [];
  List<Map<String, dynamic>> _campaigns = [];
  bool _loading = true;
  String? _err;

  bool get isDark => widget.isDark;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await lget('/leads/partners');
    final i = await lget('/integrations');
    if (!mounted) return;
    setState(() {
      _loading = false;
      _err = r['success'] == false ? '${r['message']}' : null;
      _companies = ll(r['companies']);
      _campaigns = ll(i['campaigns']);
    });
  }

  Future<void> _login(Map<String, dynamic> c) async {
    final email = TextEditingController(text: '${c['loginEmail'] ?? ''}');
    final phone = TextEditingController(text: '${c['loginPhone'] ?? ''}');
    final pass = TextEditingController();
    final had = c['hasLogin'] == true;
    final ok = await leadForm(context, isDark, '${tr('بيانات الدخول')} — ${c['name']}', (set) => [
          Text(tr('الشركة تدخل التطبيق بالإيميل أو الموبايل + كلمة المرور. أول مرة هتغيّر كلمة المرور بنفسها.'),
              style: TextStyle(color: JphUi.sub(isDark))),
          JphUi.input(isDark: isDark, label: tr('الإيميل'), controller: email, icon: Icons.alternate_email_rounded, big: false),
          JphUi.input(isDark: isDark, label: tr('الموبايل'), controller: phone, number: true, icon: Icons.phone_rounded, big: false),
          JphUi.input(isDark: isDark, label: had ? tr('كلمة مرور جديدة (سيبها فاضية لو مش هتغيّرها)') : tr('كلمة المرور (أول مرة)'),
              controller: pass, icon: Icons.key_rounded, big: false),
        ], () async {
      final r = await lpost('/leads/partners/${c['id']}/login', {
        'email': email.text.trim(),
        'phone': phone.text.trim(),
        if (pass.text.isNotEmpty) 'password': pass.text,
      }, method: 'patch', ok: tr('اتحفظ ✅'));
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    });
    if (ok) _load();
  }

  Future<void> _off(Map<String, dynamic> c) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('إيقاف دخول الشركة؟')),
        content: Text('${c['name']} — ${tr('هتخرج من كل الأجهزة ومش هتقدر تدخل لحد ما تعمل لها بيانات دخول تاني.')}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('لأ'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('أيوه'))),
        ],
      ),
    );
    if (sure != true) return;
    final r = await lpost('/leads/partners/${c['id']}/login', {'off': true}, method: 'patch', ok: tr('اتوقف'));
    if (mounted) JphUi.toast(context, r);
    _load();
  }

  /// which of our campaigns this company runs (a campaign belongs to one company)
  Future<void> _link(Map<String, dynamic> c) async {
    final mine = {for (final x in _campaigns) if (x['companyId'] == c['id']) '${x['id']}'};
    final chosen = {...mine};
    final ok = await leadForm(context, isDark, '${tr('حملات')} ${c['name']}', (set) => [
          Text(tr('الشركة هتشوف ليدز الحملات دي بس، وتقدر تضيف عليها ليدز. الحملة المربوطة بشركة تانية هتتنقل للشركة دي.'),
              style: TextStyle(color: JphUi.sub(isDark))),
          if (_campaigns.isEmpty) Text(tr('مفيش حملات — اعملها من تاب «الحملات»'), style: TextStyle(color: JphUi.sub(isDark))),
          for (final x in _campaigns)
            CheckboxListTile(
              value: chosen.contains('${x['id']}'),
              onChanged: (v) => set(() => v == true ? chosen.add('${x['id']}') : chosen.remove('${x['id']}')),
              title: Text('${x['name']}', style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: x['companyId'] != null && x['companyId'] != c['id']
                  ? Text('${tr('مربوطة حاليًا بـ')} ${_companies.firstWhere((k) => k['id'] == x['companyId'], orElse: () => {'name': '—'})['name']}')
                  : null,
              controlAffinity: ListTileControlAffinity.leading,
            ),
        ], () async {
      for (final id in {...chosen, ...mine}) {
        if (chosen.contains(id) == mine.contains(id)) continue;
        final r = await lpost('/leads/campaigns/$id/partner', {'companyId': chosen.contains(id) ? c['id'] : null}, method: 'patch');
        if (r['success'] == false) {
          if (mounted) JphUi.toast(context, r);
          return false;
        }
      }
      if (mounted) JphUi.toast(context, {'success': true, 'message': tr('اتحفظ ✅')});
      return true;
    });
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()));
    if (_err != null) return Text(_err!, style: TextStyle(color: JphUi.sub(isDark)));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('شركات التسويق'), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
      Text(tr('لكل شركة بيانات دخول خاصة (مش حساب موظف) والحملات اللي بتشغّلها. الشركة بتشوف لوحة تحكم وليدز حملاتها وتضيف ليدز بس.'),
          style: TextStyle(color: JphUi.sub(isDark))),
      const SizedBox(height: 4),
      Text(tr('الشركات نفسها بتتضاف من الإعدادات ← شركات التسويق.'), style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
      const SizedBox(height: 10),
      if (_companies.isEmpty) Text(tr('لسه مفيش شركات تسويق'), style: TextStyle(color: JphUi.sub(isDark))),
      for (final c in _companies)
        Opacity(
          opacity: c['active'] == true ? 1 : 0.55,
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: JphUi.box(isDark),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                JphUi.iconTile(isDark, Icons.campaign_rounded, Ar.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${c['name']}', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: JphUi.text(isDark))),
                    Text(
                      c['hasLogin'] == true
                          ? [if (c['loginEmail'] != null) '${c['loginEmail']}', if (c['loginPhone'] != null) '${c['loginPhone']}'].join(' · ')
                          : tr('ملهاش دخول على التطبيق'),
                      style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark)),
                    ),
                  ]),
                ),
                if (c['active'] != true) pill(tr('موقوفة'), Ar.grey)
                else if (c['hasLogin'] == true) pill(c['mustChangePassword'] == true ? tr('لسه مدخلتش') : tr('بتدخل'), Ar.green),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final x in ll(c['campaigns'])) pill('${x['name']}', Ar.accent, icon: Icons.ads_click_rounded, dot: false),
                if (ll(c['campaigns']).isEmpty) Text(tr('مفيش حملات مربوطة'), style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                Text('· ${c['leads']} ${tr('ليد')}', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                dirBtn(isDark, c['hasLogin'] == true ? tr('بيانات الدخول') : tr('اعمل دخول'), Icons.key_rounded, () => _login(c),
                    primary: c['hasLogin'] != true),
                dirBtn(isDark, tr('الحملات'), Icons.ads_click_rounded, () => _link(c)),
                if (c['hasLogin'] == true) dirBtn(isDark, tr('إيقاف الدخول'), Icons.block_rounded, () => _off(c), color: Ar.red),
              ]),
            ]),
          ),
        ),
    ]);
  }
}
