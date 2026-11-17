import 'package:flutter/material.dart' hide Text;

import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import 'leads_api.dart';
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';

/// توزيع الليدز اللي بتيجي لوحدها (فاليو عقار، فورم Meta، فورم الحملة): who gets them and how.
///   one    → سيلز واحد ثابت
///   online → بالدور على المتصلين (مفيش حد متصل → يستنى + تنبيه للمدير العام / المسؤول الإداري، وبعدين لأول واحد يفتح)
///   turn   → بالدور على الكل حتى لو مش متصلين
const routeModes = ['one', 'online', 'turn'];

String routeModeName(String? m) => switch (m) {
      'one' => tr('سيلز واحد ثابت'),
      'online' => tr('بالدور على المتصلين'),
      'turn' => tr('بالدور على الكل'),
      _ => tr('مش متحدد'),
    };

String routeModeHelp(String m) => switch (m) {
      'one' => tr('كل الليدز تروح لنفس السيلز.'),
      'online' => tr('بالترتيب على اللي فاتحين التطبيق دلوقتي. لو مفيش حد متصل: المدير العام والمسؤول الإداري يوصلهم تنبيه، ولو محدش وزّعه يروح لأول سيلز يفتح.'),
      _ => tr('بالترتيب على كل اللي اخترتهم، متصلين أو لأ.'),
    };

IconData routeModeIcon(String? m) => switch (m) {
      'one' => Icons.person_pin_rounded,
      'online' => Icons.wifi_tethering_rounded,
      _ => Icons.autorenew_rounded,
    };

/// one line saying what a rule does: «بالدور على المتصلين · أحمد، منى»
String routeSummary(String? mode, List<String> ids, List<Map<String, dynamic>> people) {
  final names = [for (final id in ids) '${people.firstWhere((p) => p['id'] == id, orElse: () => const {'name': '؟'})['name']}'];
  if (names.isEmpty) return tr('مفيش سيلز متحدد — الليدز تنزل من غير سيلز والمدير يتنبّه');
  return '${routeModeName(mode)} · ${names.join('، ')}';
}

/// The sheet that edits a rule: the mode, then the salesmen (one, or several), online ones marked.
/// [header] adds fields above (e.g. which project / property). Returns true when saved.
Future<bool> editRoute(BuildContext context, bool isDark, String title, List<Map<String, dynamic>> people,
    {String? mode, List<String> selected = const [], List<Widget> Function(StateSetter set)? header,
    required Future<bool> Function(String mode, List<String> ids) save}) {
  var m = routeModes.contains(mode) ? mode! : 'online';
  final chosen = <String>[...selected];
  var q = '';
  return leadForm(context, isDark, title, (set) {
    final shown = people.where((p) => q.isEmpty || '${p['name']}'.contains(q)).toList()
      ..sort((a, b) => (b['online'] == true ? 1 : 0) - (a['online'] == true ? 1 : 0));
    final onlineCount = people.where((p) => p['online'] == true).length;
    return [
      ...?header?.call(set),
      Text(tr('طريقة التوزيع'), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
      for (final k in routeModes)
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => set(() {
            m = k;
            if (m == 'one' && chosen.length > 1) chosen.removeRange(1, chosen.length);
          }),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: m == k ? Ar.accent : JphUi.sub(isDark).withValues(alpha: 0.25), width: m == k ? 2 : 1),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(m == k ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, color: m == k ? Ar.accent : JphUi.sub(isDark)),
              const SizedBox(width: 8),
              Icon(routeModeIcon(k), color: Ar.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(routeModeName(k), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                  Text(routeModeHelp(k), style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                ]),
              ),
            ]),
          ),
        ),
      Row(children: [
        Expanded(
          child: Text(m == 'one' ? tr('اختار السيلز') : '${tr('اختار السيلز')} (${chosen.length})',
              style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
        ),
        pill('${tr('متصل دلوقتي')}: $onlineCount', Ar.green),
      ]),
      if (people.length > 8)
        TextField(
          decoration: InputDecoration(hintText: tr('بحث بالاسم'), prefixIcon: const Icon(Icons.search_rounded), isDense: true, border: const OutlineInputBorder()),
          onChanged: (v) => set(() => q = v.trim()),
        ),
      if (people.isEmpty) Text(tr('مفيش سيلز تقدر توزّع عليهم'), style: TextStyle(color: JphUi.sub(isDark))),
      for (final p in shown)
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: chosen.contains(p['id']),
          controlAffinity: ListTileControlAffinity.leading,
          title: Text('${p['name']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
          secondary: p['online'] == true ? pill(tr('متصل'), Ar.green) : pill(tr('مش متصل'), Ar.grey),
          onChanged: (v) => set(() {
            final id = '${p['id']}';
            if (m == 'one') {
              chosen
                ..clear()
                ..add(id);
            } else if (v == true) {
              if (!chosen.contains(id)) chosen.add(id);
            } else {
              chosen.remove(id);
            }
          }),
        ),
    ];
  }, () async {
    if (chosen.isEmpty) {
      JphUi.toast(context, {'success': false, 'message': tr('اختار السيلز اللي هيستقبلوا الليدز')});
      return false;
    }
    return save(m, chosen);
  });
}
