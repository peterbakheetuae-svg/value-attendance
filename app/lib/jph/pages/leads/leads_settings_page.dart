import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import 'leads_api.dart';

/// إعدادات الليدز: the channels (فيسبوك / تيك توك …), the campaigns (with their cost, for the report),
/// the cancel reasons, and after how many minutes a lead nobody acted on rings the manager.
class LeadsSettingsPage extends StatefulWidget {
  const LeadsSettingsPage({super.key});

  @override
  State<LeadsSettingsPage> createState() => _LeadsSettingsPageState();
}

class _LeadsSettingsPageState extends State<LeadsSettingsPage> {
  Map<String, dynamic> _d = {};
  int _tab = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await lget('/leads/config');
    if (!mounted) return;
    setState(() {
      _loading = false;
      _d = r;
    });
    LeadsMeta.clear();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    return LeadsShell(
      isDark: isDark,
      title: 'إعدادات الليدز',
      fab: _tab == 3
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _tab == 1 ? _campaign(isDark) : _simple(isDark, _tab == 0 ? 'channels' : 'cancel-reasons'),
              backgroundColor: JphUi.primary(isDark),
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add_rounded),
              label: Text(['قناة جديدة', 'حملة جديدة', 'سبب جديد'][_tab], style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 100), children: [
          JphUi.tabs(isDark, const [('القنوات', Icons.campaign_rounded), ('الحملات', Icons.ads_click_rounded), ('أسباب الإلغاء', Icons.cancel_rounded), ('التنبيه', Icons.alarm_rounded)],
              _tab, (i) => setState(() => _tab = i)),
          const SizedBox(height: 12),
          if (_loading) const Center(child: CircularProgressIndicator()),
          if (!_loading && _d['success'] == false) Text('${_d['message']}', style: TextStyle(color: JphUi.sub(isDark))),
          if (!_loading && _d['success'] != false) ...(switch (_tab) {
            0 => [for (final c in ll(_d['channels'])) _row(isDark, c, 'channels', Icons.campaign_rounded)],
            1 => [for (final c in ll(_d['campaigns'])) _campaignRow(isDark, c)],
            2 => [for (final c in ll(_d['cancelReasons'])) _row(isDark, c, 'cancel-reasons', Icons.cancel_rounded)],
            _ => [_pending(isDark)],
          }),
        ]),
      ),
    );
  }

  Widget _row(bool isDark, Map<String, dynamic> c, String kind, IconData icon) => Opacity(
        opacity: c['active'] == false ? 0.5 : 1,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: JphUi.box(isDark),
          child: ListTile(
            leading: Icon(icon, color: Ar.accent),
            title: Text('${c['name']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
            subtitle: c['active'] == false ? const Text('موقوفة') : null,
            trailing: Switch(
              value: c['active'] != false,
              onChanged: (v) async {
                final r = await lpost('/leads/$kind/${c['id']}', {'active': v}, method: 'patch');
                if (mounted) JphUi.toast(context, r);
                _load();
              },
            ),
            onTap: () => _simple(isDark, kind, c),
          ),
        ),
      );

  Future<void> _simple(bool isDark, String kind, [Map<String, dynamic>? c]) async {
    final name = TextEditingController(text: '${c?['name'] ?? ''}'), sort = TextEditingController(text: '${c?['sort'] ?? 100}');
    final ok = await leadForm(context, isDark, c == null ? (kind == 'channels' ? 'قناة جديدة' : 'سبب إلغاء جديد') : 'تعديل', (set) => [
          JphUi.input(isDark: isDark, label: 'الاسم', controller: name, icon: Icons.label_rounded),
          JphUi.input(isDark: isDark, label: 'الترتيب (الأصغر الأول)', controller: sort, number: true, icon: Icons.sort_rounded, big: false),
        ], () async {
      final b = {'name': name.text.trim(), 'sort': int.tryParse(sort.text.trim()) ?? 100};
      final r = c == null ? await lpost('/leads/$kind', b, ok: 'اتضاف ✅') : await lpost('/leads/$kind/${c['id']}', b, method: 'patch', ok: 'اتحفظ ✅');
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    });
    if (ok) _load();
  }

  Widget _campaignRow(bool isDark, Map<String, dynamic> c) => Opacity(
        opacity: c['active'] == false ? 0.5 : 1,
        child: GestureDetector(
          onTap: () => _campaign(isDark, c),
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(14),
            decoration: JphUi.box(isDark),
            child: Row(children: [
              JphUi.iconTile(isDark, Icons.ads_click_rounded, Ar.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${c['name']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                  Text([
                    if (c['channelName'] != null) '${c['channelName']}',
                    if (c['projectName'] != null) '${c['projectName']}',
                    if (c['startsOn'] != null) 'من ${c['startsOn']}${c['endsOn'] == null ? '' : ' لـ ${c['endsOn']}'}',
                  ].join(' • '), style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(JphUi.money(c['cost']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                Text('${c['leads']} ليد', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
              ]),
            ]),
          ),
        ),
      );

  Future<void> _campaign(bool isDark, [Map<String, dynamic>? c]) async {
    final meta = await LeadsMeta.load(fresh: true);
    if (!mounted) return;
    final name = TextEditingController(text: '${c?['name'] ?? ''}'), cost = TextEditingController(text: c == null ? '' : '${c['cost']}');
    String? channel = c?['channelId']?.toString(), project = c?['projectId']?.toString();
    DateTime? from = DateTime.tryParse('${c?['startsOn'] ?? ''}'), to = DateTime.tryParse('${c?['endsOn'] ?? ''}');
    bool active = c?['active'] != false;
    String day(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';
    Future<DateTime?> pick(DateTime? v) => showDatePicker(context: context, initialDate: v ?? DateTime.now(), firstDate: DateTime(2024), lastDate: DateTime(2035));
    final ok = await leadForm(context, isDark, c == null ? 'حملة جديدة' : 'تعديل الحملة', (set) => [
          JphUi.input(isDark: isDark, label: 'اسم الحملة', controller: name, icon: Icons.ads_click_rounded),
          refPicker(context, isDark, 'القناة', Icons.campaign_rounded, ll(meta['channels']), channel, (v) => set(() => channel = v)),
          refPicker(context, isDark, 'المشروع', Icons.apartment_rounded, ll(meta['projects']), project, (v) => set(() => project = v)),
          JphUi.input(isDark: isDark, label: 'التكلفة', controller: cost, number: true, suffix: 'جنيه', icon: Icons.payments_rounded),
          JphUi.picker(isDark: isDark, icon: Icons.event_rounded, iconColor: Ar.accent, label: 'من', value: from == null ? 'اختار' : day(from!), onTap: () async {
            final d = await pick(from);
            if (d != null) set(() => from = d);
          }),
          JphUi.picker(isDark: isDark, icon: Icons.event_busy_rounded, iconColor: Ar.accent, label: 'لـ (اختياري)', value: to == null ? 'مفتوحة' : day(to!), onTap: () async {
            final d = await pick(to);
            if (d != null) set(() => to = d);
          }),
          if (c != null) SwitchListTile(value: active, onChanged: (v) => set(() => active = v), title: const Text('شغالة')),
        ], () async {
      final b = {
        'name': name.text.trim(), 'channelId': channel, 'projectId': project, 'cost': num.tryParse(cost.text.replaceAll(',', '')) ?? 0,
        'startsOn': from == null ? null : day(from!), 'endsOn': to == null ? null : day(to!), if (c != null) 'active': active,
      };
      final r = c == null ? await lpost('/leads/campaigns', b, ok: 'اتضافت ✅') : await lpost('/leads/campaigns/${c['id']}', b, method: 'patch', ok: 'اتحفظ ✅');
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    });
    if (ok) _load();
  }

  Widget _pending(bool isDark) {
    final m = TextEditingController(text: '${_d['pendingMinutes'] ?? 25}');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('لو الليد اتوزع على سيلز وماعملش عليه أكشن خلال المدة دي، مديره واللي وزّعه بيجيلهم تنبيه.',
            style: TextStyle(color: JphUi.sub(isDark))),
        const SizedBox(height: 10),
        JphUi.input(isDark: isDark, label: 'بعد كام دقيقة', controller: m, number: true, suffix: 'دقيقة', icon: Icons.alarm_rounded),
        const SizedBox(height: 10),
        leadBtn(isDark, 'حفظ', Icons.check_rounded, () async {
          final r = await lpost('/leads/settings', {'pendingMinutes': int.tryParse(m.text.trim()) ?? 25}, method: 'patch', ok: 'اتحفظ ✅');
          if (mounted) JphUi.toast(context, r);
          _load();
        }),
      ]),
    );
  }
}
