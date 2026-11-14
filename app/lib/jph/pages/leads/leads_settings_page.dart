import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/api.dart' show kApiBaseUrl;
import '../../services/app_controller.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import '../../services/api_service.dart';
import 'leads_api.dart';
import 'leads_permissions.dart';
import 'leads_stages.dart';

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
      title: tr('إعدادات الليدز'),
      fab: _tab >= 4
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _tab == 1
                  ? _campaign(isDark)
                  : _tab == 3
                      ? _template(isDark)
                      : _simple(isDark, _tab == 0 ? 'channels' : 'cancel-reasons'),
              backgroundColor: JphUi.primary(isDark),
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add_rounded),
              label: Text([tr('قناة جديدة'), tr('حملة جديدة'), tr('سبب جديد'), tr('رسالة جديدة')][_tab], style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 100), children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final (i, t) in [
                (tr('القنوات'), Icons.campaign_rounded), (tr('الحملات'), Icons.ads_click_rounded), (tr('أسباب الإلغاء'), Icons.cancel_rounded),
                (tr('رسايل واتساب'), Icons.chat_rounded), (tr('التنبيه والسحب'), Icons.alarm_rounded), (tr('الصادرات'), Icons.file_download_rounded),
                (tr('المراحل'), Icons.view_week_rounded),
                // الإعدادات / التحكم في الوصول: the owner only
                if (ApiService.can('roles.manage')) (tr('صلاحيات الأدوار'), Icons.admin_panel_settings_rounded),
              ].indexed)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: ChoiceChip(
                    selected: _tab == i,
                    avatar: Icon(t.$2, size: 18),
                    label: Text(t.$1, style: const TextStyle(fontWeight: FontWeight.w800)),
                    onSelected: (_) {
                      setState(() => _tab = i);
                      if (i == 5) _loadExports();
                    },
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 12),
          if (_loading) const Center(child: CircularProgressIndicator()),
          if (!_loading && _d['success'] == false) Text('${_d['message']}', style: TextStyle(color: JphUi.sub(isDark))),
          if (!_loading && _d['success'] != false) ...(switch (_tab) {
            0 => [for (final c in ll(_d['channels'])) _row(isDark, c, 'channels', Icons.campaign_rounded)],
            1 => [for (final c in ll(_d['campaigns'])) _campaignRow(isDark, c)],
            2 => [for (final c in ll(_d['cancelReasons'])) _row(isDark, c, 'cancel-reasons', Icons.cancel_rounded)],
            3 => [
                Text(tr('في الرسالة تقدر تكتب {الاسم} {المشروع} {السيلز} {الشركة} وبيتملوا لوحدهم.'), style: TextStyle(color: JphUi.sub(isDark))),
                const SizedBox(height: 8),
                for (final c in ll(_d['templates'])) _templateRow(isDark, c),
              ],
            4 => [_pending(isDark)],
            5 => _exportsList(isDark),
            6 => [LeadsStagesView(isDark: isDark)],
            _ => [LeadsPermissionsView(isDark: isDark)],
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
            subtitle: c['active'] == false ? Text(tr('موقوفة')) : null,
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
    final ok = await leadForm(context, isDark, c == null ? (kind == 'channels' ? tr('قناة جديدة') : tr('سبب إلغاء جديد')) : tr('تعديل'), (set) => [
          JphUi.input(isDark: isDark, label: tr('الاسم'), controller: name, icon: Icons.label_rounded),
          JphUi.input(isDark: isDark, label: tr('الترتيب (الأصغر الأول)'), controller: sort, number: true, icon: Icons.sort_rounded, big: false),
        ], () async {
      final b = {'name': name.text.trim(), 'sort': int.tryParse(sort.text.trim()) ?? 100};
      final r = c == null ? await lpost('/leads/$kind', b, ok: tr('اتضاف ✅')) : await lpost('/leads/$kind/${c['id']}', b, method: 'patch', ok: tr('اتحفظ ✅'));
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    });
    if (ok) _load();
  }

  List<Map<String, dynamic>> _exports = [];
  Future<void> _loadExports() async {
    final r = await lget('/leads/exports');
    if (mounted) setState(() => _exports = ll(r['exports']));
  }

  List<Widget> _exportsList(bool isDark) => [
        if (_exports.isEmpty) Text(tr('محدش صدّر حاجة لسه'), style: TextStyle(color: JphUi.sub(isDark))),
        for (final e in _exports)
          ListTile(
            leading: const Icon(Icons.file_download_rounded),
            title: Text('${e['byName'] ?? ''} — ${{'leads': 'العملاء المحتملون', 'targets': 'التارجت'}[e['kind']] ?? 'تقرير ${e['kind']}'}',
                style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
            subtitle: Text('${e['rows']} صف — ${whenAr(e['at'])}'),
          ),
      ];

  Widget _templateRow(bool isDark, Map<String, dynamic> c) => Opacity(
        opacity: c['active'] == false ? 0.5 : 1,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: JphUi.box(isDark),
          child: ListTile(
            leading: const Icon(Icons.chat_rounded, color: Color(0xFF25D366)),
            title: Text('${c['name']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
            subtitle: Text('${c['body']}', maxLines: 3, overflow: TextOverflow.ellipsis),
            trailing: Switch(
              value: c['active'] != false,
              onChanged: (v) async {
                final r = await lpost('/leads/templates/${c['id']}', {'active': v}, method: 'patch');
                if (mounted) JphUi.toast(context, r);
                _load();
              },
            ),
            onTap: () => _template(isDark, c),
          ),
        ),
      );

  Future<void> _template(bool isDark, [Map<String, dynamic>? c]) async {
    final name = TextEditingController(text: '${c?['name'] ?? ''}'), body = TextEditingController(text: '${c?['body'] ?? ''}');
    final ok = await leadForm(context, isDark, c == null ? tr('رسالة واتساب جديدة') : tr('تعديل الرسالة'), (set) => [
          JphUi.input(isDark: isDark, label: tr('اسمها'), controller: name, icon: Icons.label_rounded),
          TextField(
            controller: body,
            minLines: 4,
            maxLines: 8,
            decoration: InputDecoration(labelText: tr('الرسالة'), hintText: tr('أهلاً أستاذ {الاسم}…'), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14))),
          ),
          Wrap(spacing: 6, children: [
            for (final k in ['{الاسم}', '{المشروع}', '{السيلز}', '{الشركة}'])
              ActionChip(label: Text(k), onPressed: () => set(() => body.text = '${body.text}$k')),
          ]),
        ], () async {
      final b = {'name': name.text.trim(), 'body': body.text.trim()};
      final r = c == null ? await lpost('/leads/templates', b, ok: tr('اتضافت ✅')) : await lpost('/leads/templates/${c['id']}', b, method: 'patch', ok: tr('اتحفظ ✅'));
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    });
    if (ok) _load();
  }

  /// فورم الحملة: a public link (for the ad / a landing page); its leads go to the chosen salesmen in turn
  Future<void> _form(bool isDark, Map<String, dynamic> c) async {
    final meta = await LeadsMeta.load(fresh: true);
    if (!mounted) return;
    final people = ll(meta['assignees']);
    List<String> to = ((c['formAssignees'] as List?) ?? const []).map((x) => '$x').toList();
    final title = TextEditingController(text: '${c['formTitle'] ?? ''}');
    var enabled = true;
    final link = c['formToken'] == null ? null : '$kApiBaseUrl/f/${c['formToken']}';
    final ok = await leadForm(context, isDark, 'فورم الحملة — ${c['name']}', (set) => [
          Text(tr('لينك تحطه في الإعلان أو صفحة الهبوط: العميل يكتب اسمه ورقمه، والليد يدخل لوحده بالحملة والقناة ويتوزع بالدور على السيلز اللي تختارهم.'),
              style: TextStyle(color: JphUi.sub(isDark))),
          SwitchListTile(value: enabled, onChanged: (v) => set(() => enabled = v), title: Text(tr('صفحة الهبوط شغالة'))),
          JphUi.input(isDark: isDark, label: tr('العنوان اللي يظهر للعميل (اختياري)'), controller: title, icon: Icons.title_rounded, big: false),
          JphUi.picker(
            isDark: isDark, icon: Icons.groups_rounded, iconColor: Ar.accent, label: tr('الليدز تروح لمين'),
            value: to.isEmpty ? tr('من غير (تفضل مش متوزعة)') : '${to.length} سيلز بالدور',
            onTap: () async {
              final v = await pickPeople(context, isDark, tr('الليدز تروح لمين'), people, selected: to);
              if (v != null) set(() => to = v);
            },
          ),
          if (link != null) ...[
            SelectableText(link, textDirection: TextDirection.ltr, style: TextStyle(fontWeight: FontWeight.w700, color: Ar.accent.shade700)),
            Row(children: [
              TextButton.icon(onPressed: () => Clipboard.setData(ClipboardData(text: link)), icon: const Icon(Icons.copy_rounded), label: Text(tr('انسخ اللينك'))),
              TextButton.icon(onPressed: () => openUrl(link), icon: const Icon(Icons.open_in_new_rounded), label: Text(tr('افتحه'))),
            ]),
          ],
        ], () async {
      final r = await lpost('/leads/campaigns/${c['id']}/form', {'enabled': enabled, 'assignees': to, 'title': title.text.trim()}, ok: tr('اتحفظ ✅'));
      if (mounted) JphUi.toast(context, r);
      if (r['success'] == true && r['token'] != null && c['formToken'] == null && mounted) {
        final url = '$kApiBaseUrl/f/${r['token']}';
        await Clipboard.setData(ClipboardData(text: url));
        if (mounted) JphUi.toast(context, {'success': true, 'message': tr('اتعمل اللينك واتنسخ ✅')});
      }
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
              IconButton(
                tooltip: tr('صفحة الهبوط (لينك للإعلان)'),
                onPressed: () => _form(isDark, c),
                icon: Icon(Icons.link_rounded, color: c['formToken'] != null ? Ar.green : JphUi.sub(isDark)),
              ),
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
    final ok = await leadForm(context, isDark, c == null ? tr('حملة جديدة') : tr('تعديل الحملة'), (set) => [
          JphUi.input(isDark: isDark, label: tr('اسم الحملة'), controller: name, icon: Icons.ads_click_rounded),
          refPicker(context, isDark, tr('القناة'), Icons.campaign_rounded, ll(meta['channels']), channel, (v) => set(() => channel = v)),
          refPicker(context, isDark, tr('المشروع'), Icons.apartment_rounded, ll(meta['projects']), project, (v) => set(() => project = v)),
          JphUi.input(isDark: isDark, label: tr('التكلفة'), controller: cost, number: true, suffix: tr('جنيه'), icon: Icons.payments_rounded),
          JphUi.picker(isDark: isDark, icon: Icons.event_rounded, iconColor: Ar.accent, label: tr('من'), value: from == null ? tr('اختار') : day(from!), onTap: () async {
            final d = await pick(from);
            if (d != null) set(() => from = d);
          }),
          JphUi.picker(isDark: isDark, icon: Icons.event_busy_rounded, iconColor: Ar.accent, label: tr('لـ (اختياري)'), value: to == null ? tr('مفتوحة') : day(to!), onTap: () async {
            final d = await pick(to);
            if (d != null) set(() => to = d);
          }),
          if (c != null) SwitchListTile(value: active, onChanged: (v) => set(() => active = v), title: Text(tr('شغالة'))),
        ], () async {
      final b = {
        'name': name.text.trim(), 'channelId': channel, 'projectId': project, 'cost': num.tryParse(cost.text.replaceAll(',', '')) ?? 0,
        'startsOn': from == null ? null : day(from!), 'endsOn': to == null ? null : day(to!), if (c != null) 'active': active,
      };
      final r = c == null ? await lpost('/leads/campaigns', b, ok: tr('اتضافت ✅')) : await lpost('/leads/campaigns/${c['id']}', b, method: 'patch', ok: tr('اتحفظ ✅'));
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    });
    if (ok) _load();
  }

  Widget _pending(bool isDark) {
    final m = TextEditingController(text: '${_d['pendingMinutes'] ?? 25}');
    final auto = TextEditingController(text: _d['autoReassignMinutes'] == null ? '' : '${_d['autoReassignMinutes']}');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('لو الليد اتوزع على سيلز وماعملش عليه أكشن خلال المدة دي، مديره واللي وزّعه بيجيلهم تنبيه.'),
            style: TextStyle(color: JphUi.sub(isDark))),
        const SizedBox(height: 10),
        JphUi.input(isDark: isDark, label: tr('بعد كام دقيقة'), controller: m, number: true, suffix: tr('دقيقة'), icon: Icons.alarm_rounded),
        const SizedBox(height: 16),
        Text(tr('السحب الأوتوماتيك: لو الليد اتوزع على كذا سيلز بالدور وفضل من غير أكشن المدة دي، يتنقل لوحده للي عليه الدور بعده. سيبه فاضي عشان يتقفل.'),
            style: TextStyle(color: JphUi.sub(isDark))),
        const SizedBox(height: 10),
        JphUi.input(isDark: isDark, label: tr('يتسحب بعد كام دقيقة (فاضي = مقفول)'), controller: auto, number: true, suffix: tr('دقيقة'), icon: Icons.move_down_rounded),
        const SizedBox(height: 10),
        leadBtn(isDark, tr('حفظ'), Icons.check_rounded, () async {
          final r = await lpost('/leads/settings', {'pendingMinutes': int.tryParse(m.text.trim()) ?? 25, 'autoReassignMinutes': int.tryParse(auto.text.trim())},
              method: 'patch', ok: tr('اتحفظ ✅'));
          if (mounted) JphUi.toast(context, r);
          _load();
        }),
      ]),
    );
  }
}
