import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import 'leads_api.dart';
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';

/// لوحة التسويق الموحدة (GET /marketing/overview — leads.read_all): the leads of a period by quality and source,
/// every campaign with its company, its leads and — only when Meta's insights are stored — its spend and cost per lead,
/// the salesmen, the Meta connection and how many KPI results are automatic / manual.
/// A value the server does not know (spend without insights, mixed currencies) is shown as «—», never as 0.
class MarketingOverviewPage extends StatefulWidget {
  const MarketingOverviewPage({super.key});

  @override
  State<MarketingOverviewPage> createState() => _MarketingOverviewPageState();
}

const qualityNames = {
  'unreviewed': 'لسه متصنفش',
  'qualified': 'مؤهل',
  'not_qualified': 'غير مؤهل',
  'invalid_contact': 'رقم غلط',
  'duplicate': 'مكرر',
  'unreachable': 'مبيردش',
};

Color qualityColor(String q) => switch (q) {
      'qualified' => Ar.green,
      'unreviewed' => Ar.grey,
      'duplicate' || 'unreachable' => Ar.amber,
      _ => Ar.red,
    };

const sourceNames = {'meta_webhook': 'ميتا (لحظي)', 'meta_sync': 'ميتا (مزامنة)', 'manual': 'يدوي', 'unknown': 'غير معروف'};

class _MarketingOverviewPageState extends State<MarketingOverviewPage> {
  late DateTime _from = DateTime(DateTime.now().year, DateTime.now().month, 1), _to = DateTime.now();
  Map<String, dynamic> _d = {};
  String? _quality, _source;
  bool _loading = true;
  int _seq = 0;

  String _day(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';
  String _n(dynamic v, {int digits = 0}) => v == null ? '—' : (v as num).toStringAsFixed(digits);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() => _loading = true);
    final r = await lget('/marketing/overview', {'from': _day(_from), 'to': _day(_to), 'quality': _quality, 'source': _source});
    if (!mounted || seq != _seq) return;
    setState(() {
      _loading = false;
      _d = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    return LeadsShell(
      isDark: isDark,
      title: tr('لوحة التسويق'),
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 60), children: [
          JphUi.picker(
            isDark: isDark, icon: Icons.date_range_rounded, iconColor: Ar.accent, label: tr('الفترة'),
            value: '${_from.day}/${_from.month}/${_from.year}  ←  ${_to.day}/${_to.month}/${_to.year}',
            onTap: () async {
              final r = await JphUi.pickRange(context, isDark, _from, _to);
              if (r == null) return;
              _from = r.start;
              _to = r.end;
              _load();
            },
          ),
          const SizedBox(height: 10),
          _filters(isDark),
          const SizedBox(height: 10),
          if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
          if (!_loading && _d['success'] == false) _message(isDark, '${_d['message'] ?? tr('حصل خطأ')}'),
          if (!_loading && _d['success'] != false) ..._body(isDark),
        ]),
      ),
    );
  }

  Widget _message(bool isDark, String text) => Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
      );

  Widget _filters(bool isDark) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final (k, label) in [(null, tr('كل الجودة')), ...qualityNames.entries.map((e) => (e.key, tr(e.value)))])
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 6),
              child: ChoiceChip(
                selected: _quality == k,
                label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
                onSelected: (_) {
                  _quality = k;
                  _load();
                },
              ),
            ),
          const SizedBox(width: 10),
          for (final (k, label) in [(null, tr('كل المصادر')), ...sourceNames.entries.map((e) => (e.key, tr(e.value)))])
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 6),
              child: ChoiceChip(
                selected: _source == k,
                label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
                onSelected: (_) {
                  _source = k;
                  _load();
                },
              ),
            ),
        ]),
      );

  List<Widget> _body(bool isDark) {
    final totals = lm(_d['totals']);
    final byQuality = lm(totals['byQuality']);
    final bySource = lm(totals['bySource']);
    final campaigns = ll(_d['campaigns']);
    final employees = ll(_d['employees']);
    final it = lm(_d['integration']);
    final kpi = lm(_d['kpi']);
    if ((totals['leads'] ?? 0) == 0 && campaigns.isEmpty) {
      return [_integration(isDark, it), _message(isDark, tr('مفيش ليدز في الفترة دي بالفلاتر دي'))];
    }
    return [
      _integration(isDark, it),
      sectionLabel(tr('الليدز (${totals['leads'] ?? 0})'), isDark),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final e in byQuality.entries) pill('${tr(qualityNames[e.key] ?? e.key)}: ${e.value}', qualityColor(e.key)),
      ]),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final e in bySource.entries) pill('${tr(sourceNames[e.key] ?? e.key)}: ${e.value}', Ar.info, dot: false),
      ]),
      sectionLabel(tr('الحملات'), isDark),
      if (campaigns.isEmpty) _message(isDark, tr('مفيش حملات')),
      for (final c in campaigns.map(lm)) _campaign(isDark, c),
      sectionLabel(tr('السيلز'), isDark),
      if (employees.isEmpty) _message(isDark, tr('مفيش ليدز متوزعة')),
      for (final e in employees.map(lm))
        _row(isDark, '${e['name']}', [
          '${tr('ليدز')} ${e['leads']}',
          '${tr('مؤهل')} ${e['qualified']}',
          '${tr('صفقات')} ${e['won']}',
        ]),
      sectionLabel(tr('مؤشرات الأداء (${kpi['period'] ?? ''})'), isDark),
      Wrap(spacing: 6, runSpacing: 6, children: [
        pill('${tr('تلقائي')}: ${kpi['auto'] ?? 0}', Ar.info),
        pill('${tr('يدوي')}: ${kpi['manual'] ?? 0}', Ar.accent),
        pill('${tr('لسه مدخلش')}: ${kpi['empty'] ?? 0}', Ar.grey),
      ]),
    ];
  }

  Widget _integration(bool isDark, Map<String, dynamic> it) {
    final connected = it['connected'] == true && it['active'] == true;
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(12),
      decoration: Glass.tile(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          pill(connected ? tr('ميتا متوصلة') : tr('ميتا مش متوصلة'), connected ? Ar.green : Ar.red),
          const SizedBox(width: 8),
          Text('${tr('صفحات')} ${it['subscribedPages'] ?? 0}/${it['pages'] ?? 0}', style: TextStyle(color: JphUi.sub(isDark), fontSize: 12.5)),
        ]),
        const SizedBox(height: 6),
        Text([
          '${tr('آخر ليد')}: ${it['lastWebhookAt'] == null ? '—' : agoAr(it['lastWebhookAt'])}',
          '${tr('آخر مزامنة')}: ${it['lastSyncAt'] == null ? '—' : agoAr(it['lastSyncAt'])}',
          '${tr('الصرف متسجل لحد')}: ${it['insightsThrough'] ?? '—'}',
        ].join(' · '), style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
        if (connected && it['insightsAvailable'] == false)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(tr('أرقام الإعلانات (الصرف والتكلفة) مش متاحة: صلاحية ads_read ما اتسمحتش. الأرقام اللي تحت (لو فيه) قديمة ومش بتتحدث.'),
                style: TextStyle(fontSize: 12.5, color: Ar.amber.shade800)),
          ),
        if ('${it['lastError'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('${it['lastError']}', style: TextStyle(fontSize: 12.5, color: Ar.red.shade700)),
          ),
      ]),
    );
  }

  Widget _campaign(bool isDark, Map<String, dynamic> c) {
    final cur = c['currency'] == null ? '' : ' ${c['currency']}';
    final spend = c['mixedCurrencies'] == true ? tr('عملات مختلفة') : (c['spend'] == null ? '—' : '${_n(c['spend'], digits: 2)}$cur');
    return _row(isDark, '${c['name']}', [
      c['officeDirect'] == true ? tr('المكتب مباشرة') : '${c['company'] ?? '—'}',
      '${tr('ليدز')} ${c['leads']}',
      '${tr('مؤهل')} ${c['qualified']}',
      '${tr('حجز')} ${c['reservations']}',
      '${tr('صفقات')} ${c['won']}',
      '${tr('الصرف')} $spend',
      '${tr('تكلفة الليد')} ${c['costPerLead'] == null ? '—' : '${_n(c['costPerLead'], digits: 2)}$cur'}',
      '${tr('تكلفة المؤهل')} ${c['costPerQualified'] == null ? '—' : '${_n(c['costPerQualified'], digits: 2)}$cur'}',
    ]);
  }

  Widget _row(bool isDark, String title, List<String> facts) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: Glass.tile(isDark),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
          const SizedBox(height: 4),
          Text(facts.join(' · '), style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
        ]),
      );
}
