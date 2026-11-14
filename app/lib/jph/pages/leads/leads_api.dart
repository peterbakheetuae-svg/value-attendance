import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/api_service.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/side_sheet.dart';
import 'leads_tr.dart';

/// The language of the leads pages (set with the app's language in main.dart): ar / en / hi / ur.
class LeadsTr {
  static String lang = 'ar';
  static bool get rtl => lang == 'ar' || lang == 'ur';
}

/// a leads page's Arabic text in the app's language (Arabic when there is no translation)
String tr(String ar) {
  final i = const {'en': 0, 'hi': 1, 'ur': 2}[LeadsTr.lang];
  if (i == null) return ar;
  return leadsTranslations[ar]?[i] ?? ar;
}

ui.TextDirection get leadsDir => LeadsTr.rtl ? ui.TextDirection.rtl : ui.TextDirection.ltr;

/// نظام الليدز — the shared pieces of its pages (the API, the stages' colours, the forms' sheet).
Map<String, dynamic> lm(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
List<Map<String, dynamic>> ll(Object? v) => ((v as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();

Future<Map<String, dynamic>> lget(String path, [Map<String, String?>? q]) =>
    ApiService.post({'action': 'cash_get', 'path': path, if (q != null) 'query': q});
Future<Map<String, dynamic>> lpost(String path, Map<String, dynamic> body, {String? ok, String? method}) =>
    ApiService.post({'action': 'cash_post', 'path': path, 'body': body, 'ok': ok ?? tr('تم ✅'), if (method != null) 'method': method});

/// who sees the sales dashboard in the menu
bool get seesLeads => ApiService.can('leads.own') || ApiService.can('leads.team') || ApiService.can('leads.read_all') || ApiService.can('leads.distribute');

/// what /leads/meta says (cached for the session; refreshed after the settings change)
class LeadsMeta {
  static Map<String, dynamic>? _m;
  static Future<Map<String, dynamic>> load({bool fresh = false}) async {
    if (_m != null && !fresh) return _m!;
    final r = await lget('/leads/meta');
    if (r['success'] == true) _m = r;
    return r;
  }

  static void clear() => _m = null;
}

Color stageColor(String? s) => switch (s) {
      'new' => Ar.info,
      'no_answer' => Ar.grey,
      'following' => Ar.amber,
      'interested' => Ar.tan,
      'meeting' => Ar.accent,
      'after_meeting' => const Color(0xFFB28DFF),
      'reschedule' => const Color(0xFFE38BC8),
      'cancelled' => Ar.red,
      'reservation' => const Color(0xFF3FC1C9),
      'done_deal' => Ar.green,
      _ => Ar.grey,
    };

IconData stageIcon(String? s) => switch (s) {
      'new' => Icons.fiber_new_rounded,
      'no_answer' => Icons.phone_missed_rounded,
      'following' => Icons.replay_rounded,
      'interested' => Icons.favorite_rounded,
      'meeting' => Icons.handshake_rounded,
      'after_meeting' => Icons.event_repeat_rounded,
      'reschedule' => Icons.update_rounded,
      'cancelled' => Icons.cancel_rounded,
      'reservation' => Icons.bookmark_added_rounded,
      'done_deal' => Icons.verified_rounded,
      _ => Icons.circle_outlined,
    };

Map<String, String> get stageNames => <String, String>{
  'new': tr('جديد'), 'no_answer': tr('أول مكالمة — مردّش'), 'following': tr('متابعة'), 'interested': tr('مهتم'), 'meeting': tr('ميتنج'),
  'after_meeting': tr('متابعة بعد الميتنج'), 'reschedule': tr('تأجيل ميتنج'), 'cancelled': tr('إلغاء'), 'reservation': tr('حجز'), 'done_deal': tr('تم البيع'),
};

String two(int v) => v.toString().padLeft(2, '0');

/// «السبت 14/11 — 3:30 م»
String whenAr(Object? iso, {bool withDay = true}) {
  final d = DateTime.tryParse('${iso ?? ''}')?.toLocal();
  if (d == null) return '--';
  final days = [tr('الاتنين'), tr('التلات'), tr('الأربع'), tr('الخميس'), tr('الجمعة'), tr('السبت'), tr('الحد')];
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final rel = day == today ? tr('النهارده') : day == today.add(const Duration(days: 1)) ? tr('بكرة') : day == today.subtract(const Duration(days: 1)) ? tr('امبارح') : null;
  final date = rel ?? '${withDay ? '${days[d.weekday - 1]} ' : ''}${d.day}/${d.month}${d.year != now.year ? '/${d.year}' : ''}';
  return '$date — $h:${two(d.minute)} ${d.hour < 12 ? 'ص' : 'م'}';
}

String agoAr(Object? iso) {
  final d = DateTime.tryParse('${iso ?? ''}')?.toLocal();
  if (d == null) return '';
  final m = DateTime.now().difference(d).inMinutes;
  if (m < 1) return tr('دلوقتي');
  if (m < 60) return 'من $m دقيقة';
  if (m < 60 * 24) return 'من ${m ~/ 60} ساعة';
  return 'من ${m ~/ (60 * 24)} يوم';
}

String isoUtc(DateTime d) => d.toUtc().toIso8601String();

/// digits → an international number for WhatsApp (Egyptian 01… → 201…)
String waNumber(String phone) {
  var d = phone.replaceAll(RegExp(r'\D'), '');
  if (d.startsWith('00')) d = d.substring(2);
  if (d.startsWith('01') && d.length == 11) d = '2$d';
  return d;
}

Future<void> openUrl(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

Future<void> callPhone(String phone) => launchUrl(Uri.parse('tel:${phone.replaceAll(RegExp(r'[^\d+]'), '')}'));
Future<void> whatsApp(String phone, {String text = ''}) =>
    launchUrl(Uri.parse('https://wa.me/${waNumber(phone)}${text.isEmpty ? '' : '?text=${Uri.encodeComponent(text)}'}'), mode: LaunchMode.externalApplication);

Widget leadBtn(bool isDark, String label, IconData icon, VoidCallback? onTap, {Color? color, bool outline = false}) => SizedBox(
      height: 46,
      child: outline
          ? OutlinedButton.icon(
              onPressed: onTap,
              icon: Icon(icon, size: 20),
              label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
              style: OutlinedButton.styleFrom(foregroundColor: color ?? JphUi.primary(isDark),
                  side: BorderSide(color: (color ?? JphUi.primary(isDark)).withOpacity(0.6)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            )
          : ElevatedButton.icon(
              onPressed: onTap,
              icon: Icon(icon, size: 20),
              label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
              style: ElevatedButton.styleFrom(backgroundColor: color ?? JphUi.primary(isDark), foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            ),
    );

/// A form in a sheet (a side panel on the computer): its fields, and a save button that closes it when [save] is true.
Future<bool> leadForm(BuildContext context, bool isDark, String title, List<Widget> Function(StateSetter set) fields,
    Future<bool> Function() save, {String? saveLabel, IconData saveIcon = Icons.check_rounded}) async {
  var busy = false;
  final r = await showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Directionality(
      textDirection: leadsDir,
      child: StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.92),
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(16),
            decoration: Glass.sheet(isDark, r: 24),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
                  IconButton(onPressed: () => Navigator.pop(ctx, false), icon: Icon(Icons.close_rounded, color: JphUi.sub(isDark))),
                ]),
                const SizedBox(height: 8),
                ...fields(set).expand((w) => [w, const SizedBox(height: 10)]),
                const SizedBox(height: 6),
                leadBtn(isDark, busy ? tr('لحظة…') : saveLabel ?? tr('حفظ'), saveIcon, busy
                    ? null
                    : () async {
                        set(() => busy = true);
                        final done = await save();
                        if (ctx.mounted) set(() => busy = false);
                        if (done && ctx.mounted) Navigator.pop(ctx, true);
                      }),
              ]),
            ),
          ),
        ),
      ),
    ),
  );
  return r == true;
}

/// pick one or more people (the salesmen to give leads to)
Future<List<String>?> pickPeople(BuildContext context, bool isDark, String title, List<Map<String, dynamic>> people,
    {List<String> selected = const [], bool multi = true}) {
  final chosen = {...selected};
  final search = TextEditingController();
  return showAppSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Directionality(
      textDirection: leadsDir,
      child: StatefulBuilder(builder: (ctx, set) {
        final q = search.text.trim();
        final shown = people.where((p) => q.isEmpty || '${p['name']}'.contains(q) || '${p['code'] ?? ''}'.contains(q)).toList();
        return Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.all(16),
          decoration: Glass.sheet(isDark, r: 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
              if (multi) Text('${chosen.length} مختار', style: TextStyle(color: JphUi.sub(isDark), fontWeight: FontWeight.w700)),
              IconButton(onPressed: () => Navigator.pop(ctx), icon: Icon(Icons.close_rounded, color: JphUi.sub(isDark))),
            ]),
            if (multi)
              Text(tr('لو اخترت أكتر من واحد الليدز بتتوزع عليهم بالدور'), style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
            const SizedBox(height: 8),
            TextField(
              controller: search,
              onChanged: (_) => set(() {}),
              decoration: InputDecoration(hintText: tr('دوّر بالاسم'), prefixIcon: const Icon(Icons.search_rounded),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)), isDense: true),
            ),
            const SizedBox(height: 8),
            if (multi)
              Row(children: [
                TextButton(onPressed: () => set(() => chosen.addAll(shown.map((p) => '${p['id']}'))), child: Text(tr('اختار الكل'))),
                TextButton(onPressed: () => set(chosen.clear), child: Text(tr('شيل الكل'))),
              ]),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final p in shown)
                  CheckboxListTile(
                    value: chosen.contains('${p['id']}'),
                    onChanged: (v) => set(() {
                      if (!multi) chosen.clear();
                      v == true ? chosen.add('${p['id']}') : chosen.remove('${p['id']}');
                      if (!multi && v == true) Navigator.pop(ctx, chosen.toList());
                    }),
                    title: Text('${p['name']}', style: TextStyle(fontWeight: FontWeight.w700, color: JphUi.text(isDark))),
                    subtitle: p['code'] == null ? null : Text('${p['code']}'),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
              ]),
            ),
            if (multi) ...[
              const SizedBox(height: 8),
              leadBtn(isDark, tr('تمام'), Icons.check_rounded, () => Navigator.pop(ctx, chosen.toList())),
            ],
          ]),
        );
      }),
    ),
  );
}

/// a choice from a list of maps ({id, name}); null = «من غير»
Widget refPicker(BuildContext context, bool isDark, String label, IconData icon, List<Map<String, dynamic>> items, String? value,
    ValueChanged<String?> onPick, {bool allowNone = true}) {
  final cur = items.firstWhere((x) => '${x['id']}' == value, orElse: () => const {});
  return JphUi.picker(
    isDark: isDark, icon: icon, iconColor: Ar.accent, label: label, value: cur.isEmpty ? tr('اختار') : '${cur['name']}',
    onTap: () async {
      final v = await JphUi.sheet<String>(context, isDark, label, [
        if (allowNone) ('', tr('من غير'), Icons.remove_circle_outline_rounded),
        for (final x in items) ('${x['id']}', '${x['name']}', icon),
      ], selected: value ?? '');
      if (v != null) onPick(v.isEmpty ? null : v);
    },
  );
}

/// date + time: the quick buttons (بعد ساعة / ساعتين / بكرة / الأسبوع الجاي) and a picker
class WhenField extends StatelessWidget {
  final bool isDark;
  final DateTime? value;
  final ValueChanged<DateTime> onPick;
  final String label;
  WhenField({super.key, required this.isDark, required this.value, required this.onPick, String? label}) : label = label ?? 'معاد المتابعة الجاية';

  @override
  Widget build(BuildContext context) {
    DateTime at(int days, int h) {
      final n = DateTime.now().add(Duration(days: days));
      return DateTime(n.year, n.month, n.day, h);
    }

    final quick = <(String, DateTime Function())>[
      (tr('بعد ساعة'), () => DateTime.now().add(const Duration(hours: 1))),
      (tr('بعد ساعتين'), () => DateTime.now().add(const Duration(hours: 2))),
      (tr('بكرة'), () => at(1, 11)),
      (tr('الأسبوع الجاي'), () => at(7, 11)),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      JphUi.picker(
        isDark: isDark, icon: Icons.event_rounded, iconColor: Ar.accent, label: tr(label),
        value: value == null ? tr('اختار المعاد') : whenAr(value!.toIso8601String()),
        onTap: () async {
          final now = DateTime.now();
          final d = await showDatePicker(context: context, initialDate: value ?? now, firstDate: DateTime(now.year, now.month, now.day),
              lastDate: DateTime(now.year + 2));
          if (d == null || !context.mounted) return;
          final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(value ?? now.add(const Duration(hours: 1))));
          if (t == null) return;
          onPick(DateTime(d.year, d.month, d.day, t.hour, t.minute));
        },
      ),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final q in quick)
          ActionChip(label: Text(q.$1, style: const TextStyle(fontWeight: FontWeight.w700)), onPressed: () => onPick(q.$2())),
      ]),
    ]);
  }
}

/// the little coloured stage chip
Widget stageChip(String? stage, {String? label}) => JphUi.chip(label ?? stageNames[stage] ?? '$stage', stageColor(stage));

/// a page's frame: the background, RTL, the header and a centred, width-limited body
class LeadsShell extends StatelessWidget {
  final bool isDark;
  final String title;
  final Widget child;
  final Widget? action;
  final Widget? fab;
  /// the phone's bottom bar, when the page is one of its tabs
  final Widget? bottomBar;
  const LeadsShell({super.key, required this.isDark, required this.title, required this.child, this.action, this.fab, this.bottomBar});

  @override
  Widget build(BuildContext context) => AppBackground(
        child: Directionality(
        textDirection: leadsDir,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          floatingActionButton: fab,
          extendBody: bottomBar != null,
          bottomNavigationBar: bottomBar,
          body: SafeArea(
            child: Column(children: [
              JphUi.header(context, isDark: isDark, isRTL: true, title: title, action: action),
              Expanded(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1200), child: child))),
            ]),
          ),
        ),
      ),
      );
}

// ==================================================================== the «directory» look (the leads list and a lead's panel)
String initials(String name) {
  final w = name.trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
  if (w.isEmpty) return '?';
  return w.length == 1 ? w.first.characters.take(2).toString() : '${w[0].characters.first}${w[1].characters.first}';
}

/// a soft pastel per person (the same name always gets the same colour)
Color avatarColor(String seed) {
  const c = [Color(0xFFDCE7F7), Color(0xFFF8DED3), Color(0xFFE9E1D6), Color(0xFFDDEFE3), Color(0xFFEDE0F5), Color(0xFFF7E8C9), Color(0xFFD9EEF0)];
  return c[seed.codeUnits.fold<int>(0, (a, b) => a + b) % c.length];
}

Widget leadAvatar(String name, {double size = 38}) => Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: avatarColor(name), shape: BoxShape.circle),
      child: Text(initials(name),
          style: TextStyle(fontSize: size * 0.36, fontWeight: FontWeight.w800, color: const Color(0xFF2B2A28))),
    );

/// a rounded pill: a dot (or an icon) and its text
Widget pill(String text, Color color, {IconData? icon, bool dot = true}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withOpacity(0.14), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null)
          Icon(icon, size: 14, color: color)
        else if (dot)
          Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        if (icon != null || dot) const SizedBox(width: 6),
        Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color.lerp(color, Colors.black, 0.35))),
      ]),
    );

Widget sectionLabel(String text, bool isDark) => Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Text(text, style: TextStyle(fontSize: 12, letterSpacing: 0.6, fontWeight: FontWeight.w800, color: JphUi.sub(isDark))),
    );

/// a filter chip of the directory: black when chosen, with its count
Widget dirChip(bool isDark, String label, bool on, VoidCallback onTap, {int? count, Color? dot}) => Padding(
      padding: const EdgeInsetsDirectional.only(end: 6, bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: on ? (isDark ? Colors.white : const Color(0xFF1C1B19)) : (isDark ? Colors.white.withOpacity(0.07) : const Color(0xFFF1F0EE)),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: on ? Colors.transparent : (isDark ? Colors.white12 : const Color(0xFFE4E2DE))),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (dot != null) ...[Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)), const SizedBox(width: 7)],
            Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                color: on ? (isDark ? Colors.black : Colors.white) : JphUi.text(isDark))),
            if (count != null) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: on ? Colors.white24 : (isDark ? Colors.white12 : Colors.white), borderRadius: BorderRadius.circular(8)),
                child: Text('$count', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800,
                    color: on ? (isDark ? Colors.black : Colors.white) : JphUi.sub(isDark))),
              ),
            ],
          ]),
        ),
      ),
    );

/// a filled (primary) or outlined button of the panel
Widget dirBtn(bool isDark, String label, IconData icon, VoidCallback? onTap, {bool primary = false, Color? color}) => Padding(
      padding: const EdgeInsetsDirectional.only(end: 8, bottom: 8),
      child: SizedBox(
        height: 42,
        child: primary
            ? ElevatedButton.icon(
                onPressed: onTap,
                icon: Icon(icon, size: 18),
                label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
                style: ElevatedButton.styleFrom(backgroundColor: color ?? Ar.accent.shade700, foregroundColor: Colors.white, elevation: 3,
                    shadowColor: (color ?? Ar.accent).withOpacity(0.4), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              )
            : OutlinedButton.icon(
                onPressed: onTap,
                icon: Icon(icon, size: 18, color: color ?? JphUi.text(isDark)),
                label: Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: color ?? JphUi.text(isDark))),
                style: OutlinedButton.styleFrom(
                    side: BorderSide(color: isDark ? Colors.white24 : const Color(0xFFDAD8D4)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              ),
      ),
    );
