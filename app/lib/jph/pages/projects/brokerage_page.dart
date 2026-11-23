import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text;
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';

/// «التسويق» → إعادة بيع / إيجار (server: /brokerage, proposed migration 087 — nothing shows until it runs).
/// The sales employee registers the deal and proposes the commission; the general manager approves its distribution
/// (never his own deal); the cashbox collects each side's commission. The server enforces every one of these rules.

Future<Map<String, dynamic>> _get(String path, [Map<String, dynamic> query = const {}]) =>
    ApiService.post({'action': 'cash_get', 'path': path, 'query': query});
Future<Map<String, dynamic>> _send(String path, Map<String, dynamic> body, {String? ok, bool patch = false}) =>
    ApiService.post({'action': 'cash_post', 'path': path, 'body': body, 'ok': ok, if (patch) 'method': 'patch'});
List<Map<String, dynamic>> _rows(dynamic v) => ((v as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
Map<String, dynamic> _map(dynamic v) => (v is Map) ? v.cast<String, dynamic>() : <String, dynamic>{};
num _n(dynamic v) => v is num ? v : num.tryParse('$v') ?? 0;
String _egp(dynamic v) => '${_n(v).toStringAsFixed(_n(v) == _n(v).roundToDouble() ? 0 : 2)} ج';

const _arrangements = [
  ('owner_month', 'شهر من المالك'),
  ('client_month', 'شهر من المستأجر'),
  ('half_each', 'نص شهر من كل طرف'),
  ('fixed', 'مبلغ ثابت متفق عليه'),
];
(String, Color) _status(String? s) => switch (s) {
      'approved' => ('معتمدة — مستنية التحصيل', Glass.blue),
      'collected' => ('اتحصلت بالكامل', Colors.green),
      'rejected' => ('مرفوضة', Colors.red),
      'cancelled' => ('ملغية', Colors.grey),
      _ => ('مستنية اعتماد المدير', Colors.orange),
    };

class BrokeragePage extends StatefulWidget {
  final String kind; // resale | rental
  /// inside «المشاريع»'s bar (المشاريع / إعادة بيع / إيجار): no own background / header
  final bool embedded;
  const BrokeragePage({super.key, required this.kind, this.embedded = false});
  @override
  State<BrokeragePage> createState() => _BrokeragePageState();
}

class _BrokeragePageState extends State<BrokeragePage> {
  bool _loading = true, _installed = false;
  Map<String, dynamic> _can = {};
  List<Map<String, dynamic>> _deals = [];
  List<Map<String, dynamic>> _people = [];
  bool get _resale => widget.kind == 'resale';
  String get _title => _resale ? 'إعادة بيع' : 'إيجار';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final st = await _get('/brokerage/status');
    _installed = st['installed'] == true;
    _can = _map(st['can']);
    if (_installed) {
      final r = await _get('/brokerage/deals', {'kind': widget.kind});
      _deals = _rows(r['deals']);
      if (_people.isEmpty && (_can['propose'] == true || _can['approve'] == true)) _people = _rows((await _get('/brokerage/people'))['people']);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final fab = _installed && _can['propose'] == true
              ? FloatingActionButton.extended(
                  backgroundColor: Glass.blue, foregroundColor: Colors.white,
                  onPressed: () => _propose(isDark), icon: const Icon(Icons.add_rounded), label: const Text('صفقة جديدة'))
              : null;
    final Widget content = _loading
                    ? const Center(child: CircularProgressIndicator())
                    : !_installed
                        ? _empty(isDark, '$_title هتشتغل بعد تحديث قاعدة البيانات (087) — مستنية موافقة المالك')
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: _deals.isEmpty
                                ? ListView(children: [_empty(isDark, 'مفيش صفقات $_title لسه')])
                                : ListView.separated(
                                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 90),
                                    itemCount: _deals.length,
                                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                                    itemBuilder: (_, i) => _card(isDark, _deals[i]),
                                  ),
                          );
    if (widget.embedded) return Scaffold(backgroundColor: Colors.transparent, floatingActionButton: fab, body: content);
    return AppBackground(
      child: Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          floatingActionButton: fab,
          body: SafeArea(
            child: Column(children: [
              JphUi.header(context, isDark: isDark, isRTL: true, title: _title),
              Expanded(child: content),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _empty(bool isDark, String t) => Padding(
        padding: const EdgeInsets.all(32),
        child: Center(child: Text(t, textAlign: TextAlign.center, style: TextStyle(color: Glass.muted(isDark), fontSize: 14))),
      );

  Widget _card(bool isDark, Map<String, dynamic> d) {
    final cm = _map(d['commission']);
    final (label, color) = _status(d['status'] as String?);
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _open(isDark, d),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: Glass.tile(isDark, r: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('${d['property']}', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: Glass.ink(isDark)))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(99)),
              child: Text(label, style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 6),
          Text('${_map(d['owner'])['name']} ← ${_map(d['client'])['name']} · ${_resale ? 'السعر' : 'الإيجار'} ${_egp(d['price'])}',
              style: TextStyle(fontSize: 12.5, color: Glass.muted(isDark))),
          const SizedBox(height: 6),
          Text('العمولة ${_egp(cm['total'])} · اتحصل ${_egp(cm['collected'])} · باقي ${_egp(cm['receivable'])}',
              style: TextStyle(fontSize: 13, color: Glass.ink(isDark))),
        ]),
      ),
    );
  }

  // ----------------------------------------------------------------- a new deal (the sales employee's proposal)
  Future<void> _propose(bool isDark) async {
    final property = TextEditingController(), owner = TextEditingController(), ownerPhone = TextEditingController();
    final client = TextEditingController(), clientPhone = TextEditingController(), price = TextEditingController();
    final rate = TextEditingController(text: '2'), ownerAmount = TextEditingController(), clientAmount = TextEditingController();
    final notes = TextEditingController();
    String paidBy = 'both', arrangement = 'owner_month';
    String? closer, manager;
    await showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        Widget pick(String title, String? value, ValueChanged<String?> on) => ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(title, style: TextStyle(color: Glass.muted(isDark), fontSize: 12.5)),
              subtitle: Text(value == null ? 'أنا' : '${_people.firstWhere((p) => p['id'] == value, orElse: () => {'name': '—'})['name']}',
                  style: TextStyle(color: Glass.ink(isDark), fontSize: 14.5)),
              trailing: const Icon(Icons.expand_more_rounded),
              onTap: () async {
                final v = await JphUi.sheet<String?>(ctx, isDark, title, [
                  (null, 'أنا', Icons.person_rounded),
                  for (final p in _people) (p['id'] as String, '${p['name']}', Icons.badge_rounded),
                ]);
                set(() => on(v));
              },
            );
        return _sheet(isDark, ctx, 'صفقة $_title جديدة', [
          JphUi.input(isDark: isDark, label: _resale ? 'العقار (الوصف والعنوان) *' : 'الوحدة المؤجرة *', controller: property, icon: Icons.home_work_rounded, big: false),
          JphUi.input(isDark: isDark, label: _resale ? 'المالك (البائع) *' : 'المالك (المؤجر) *', controller: owner, icon: Icons.person_rounded, big: false),
          JphUi.input(isDark: isDark, label: 'تليفون المالك', controller: ownerPhone, icon: Icons.phone_rounded, big: false),
          JphUi.input(isDark: isDark, label: _resale ? 'المشتري *' : 'المستأجر *', controller: client, icon: Icons.person_outline_rounded, big: false),
          JphUi.input(isDark: isDark, label: _resale ? 'تليفون المشتري' : 'تليفون المستأجر', controller: clientPhone, icon: Icons.phone_rounded, big: false),
          JphUi.input(isDark: isDark, label: _resale ? 'سعر البيع *' : 'الإيجار الشهري *', controller: price, number: true, icon: Icons.payments_rounded, big: false),
          if (_resale) ...[
            JphUi.input(isDark: isDark, label: 'نسبة العمولة ٪ (من 1 لـ 2.5)', controller: rate, number: true, icon: Icons.percent_rounded, big: false),
            _choice(isDark, 'مين بيدفع العمولة', paidBy, const [('owner', 'البائع'), ('client', 'المشتري'), ('both', 'الاتنين')], (v) => set(() => paidBy = v)),
            if (paidBy == 'both') JphUi.input(isDark: isDark, label: 'نصيب البائع من العمولة (والباقي على المشتري)', controller: ownerAmount, number: true, icon: Icons.call_split_rounded, big: false),
          ] else ...[
            _choice(isDark, 'العمولة', arrangement, _arrangements, (v) => set(() => arrangement = v)),
            if (arrangement == 'fixed') ...[
              JphUi.input(isDark: isDark, label: 'على المالك', controller: ownerAmount, number: true, icon: Icons.person_rounded, big: false),
              JphUi.input(isDark: isDark, label: 'على المستأجر', controller: clientAmount, number: true, icon: Icons.person_outline_rounded, big: false),
            ],
          ],
          pick('اللي قفل الصفقة', closer, (v) => closer = v),
          pick('مدير المبيعات (اختياري)', manager, (v) => manager = v),
          JphUi.input(isDark: isDark, label: 'ملاحظات', controller: notes, icon: Icons.notes_rounded, big: false),
        ], 'إرسال للاعتماد', () async {
          final r = await _send('/brokerage/deals', {
            'kind': widget.kind, 'property': property.text.trim(), 'ownerName': owner.text.trim(), 'ownerPhone': ownerPhone.text.trim(),
            'clientName': client.text.trim(), 'clientPhone': clientPhone.text.trim(), 'price': num.tryParse(price.text.trim()),
            if (_resale) ...{'ratePct': num.tryParse(rate.text.trim()), 'paidBy': paidBy, if (paidBy == 'both') 'ownerAmount': num.tryParse(ownerAmount.text.trim()) ?? 0},
            if (!_resale) ...{'arrangement': arrangement, if (arrangement == 'fixed') ...{'ownerAmount': num.tryParse(ownerAmount.text.trim()) ?? 0, 'clientAmount': num.tryParse(clientAmount.text.trim()) ?? 0}},
            if (closer != null) 'closerId': closer, if (manager != null) 'salesManagerId': manager, 'notes': notes.text.trim(),
          }, ok: 'اتبعتت للمدير ✅');
          if (!ctx.mounted) return;
          JphUi.toast(ctx, r);
          if (r['success'] == true) Navigator.pop(ctx);
        });
      }),
    );
    _load();
  }

  Widget _choice(bool isDark, String title, String value, List<(String, String)> items, ValueChanged<String> on) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(color: Glass.muted(isDark), fontSize: 12.5)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final (k, l) in items) ChoiceChip(label: Text(l), selected: value == k, onSelected: (_) => on(k)),
          ]),
        ]),
      );

  Widget _sheet(bool isDark, BuildContext ctx, String title, List<Widget> children, String action, Future<void> Function() onAction) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.9, maxWidth: 640),
          decoration: BoxDecoration(color: isDark ? const Color(0xFF111827) : Colors.white, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
          child: Directionality(
            textDirection: ui.TextDirection.rtl,
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(16), children: [
              Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Glass.ink(isDark))),
              const SizedBox(height: 12),
              for (final w in children) Padding(padding: const EdgeInsets.only(bottom: 8), child: w),
              const SizedBox(height: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Glass.blue, foregroundColor: Colors.white, minimumSize: const Size.fromHeight(46), shape: const StadiumBorder()),
                onPressed: onAction, child: Text(action)),
            ]),
          ),
        ),
      );

  // ----------------------------------------------------------------- one deal: details, approval, collection, cancel
  Future<void> _open(bool isDark, Map<String, dynamic> d) async {
    final cm = _map(d['commission']);
    final o = _map(cm['owner']), c = _map(cm['client']);
    final shares = _rows(d['shares']);
    const roleAr = {'contributor': 'جايب العقار', 'closer': 'اللي قفل الصفقة', 'sales_manager': 'مدير المبيعات', 'other': 'مستفيد آخر'};
    await showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (ctx) => _sheet(isDark, ctx, '${d['property']}', [
        _line(isDark, 'الحالة', _status(d['status'] as String?).$1),
        _line(isDark, _resale ? 'سعر البيع' : 'الإيجار الشهري', _egp(d['price'])),
        if (d['ratePct'] != null) _line(isDark, 'النسبة', '${d['ratePct']}٪'),
        _line(isDark, 'جايب العقار', '${_map(d['contributor'])['name']}'),
        _line(isDark, 'اللي قفل الصفقة', '${_map(d['closer'])['name']}'),
        if (d['salesManager'] != null) _line(isDark, 'مدير المبيعات', '${_map(d['salesManager'])['name']}'),
        const Divider(),
        _line(isDark, 'عمولة المالك', '${_egp(o['due'])} — اتحصل ${_egp(o['collected'])} · باقي ${_egp(o['receivable'])}'),
        _line(isDark, _resale ? 'عمولة المشتري' : 'عمولة المستأجر', '${_egp(c['due'])} — اتحصل ${_egp(c['collected'])} · باقي ${_egp(c['receivable'])}'),
        _line(isDark, 'الإجمالي', '${_egp(cm['total'])} — باقي ${_egp(cm['receivable'])}'),
        if (shares.isNotEmpty) ...[
          const Divider(),
          for (final s in shares) ...[
            _line(isDark, roleAr[s['role']] ?? '${s['role']}',
                '${_map(s['employee'])['name'] ?? s['beneficiary']} — ${_egp(s['amount'])}${s['mode'] == 'pct' ? ' (${s['value']}٪)' : ''}'
                '${s['settlement'] != null ? ' · اتصرف (إيصال ${_map(s['settlement'])['refNo']})' : ''}'),
            // an approved beneficiary outside the staff: paid once from the office cashbox, after the commission is all in
            if (s['canSettle'] == true)
              OutlinedButton.icon(
                onPressed: () async {
                  final r = await _send('/brokerage/deals/${d['id']}/shares/${s['id']}/settle', {'clientRef': _uuidFrom('')}, ok: 'اتصرف ✅');
                  if (!ctx.mounted) return;
                  JphUi.toast(ctx, r);
                  if (r['success'] == true) Navigator.pop(ctx);
                },
                icon: const Icon(Icons.outbound_rounded),
                label: Text('صرف نصيب ${s['beneficiary']} من الخزنة')),
          ],
        ],
        if (d['canApprove'] == true) ...[
          const Divider(),
          OutlinedButton.icon(onPressed: () => _approve(isDark, ctx, d), icon: const Icon(Icons.verified_rounded), label: const Text('اعتماد وتوزيع العمولة')),
          OutlinedButton.icon(
              onPressed: () async {
                final r = await _send('/brokerage/deals/${d['id']}/decision', {'decision': 'reject'}, ok: 'اترفضت');
                if (!ctx.mounted) return;
                JphUi.toast(ctx, r);
                if (r['success'] == true) Navigator.pop(ctx);
              },
              icon: const Icon(Icons.close_rounded), label: const Text('رفض')),
        ],
        if (d['canCollect'] == true) ...[
          const Divider(),
          if (_n(o['receivable']) > 0) OutlinedButton.icon(onPressed: () => _collect(isDark, ctx, d, 'owner', o['receivable']), icon: const Icon(Icons.payments_rounded), label: const Text('تحصيل من المالك')),
          if (_n(c['receivable']) > 0) OutlinedButton.icon(onPressed: () => _collect(isDark, ctx, d, 'client', c['receivable']), icon: const Icon(Icons.payments_rounded), label: Text(_resale ? 'تحصيل من المشتري' : 'تحصيل من المستأجر')),
        ],
      ], 'إغلاق', () async => Navigator.pop(ctx)),
    );
    _load();
  }

  Widget _line(bool isDark, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 120, child: Text(k, style: TextStyle(color: Glass.muted(isDark), fontSize: 12.5))),
          Expanded(child: Text(v, style: TextStyle(color: Glass.ink(isDark), fontSize: 13.5))),
        ]),
      );

  Future<void> _approve(bool isDark, BuildContext parent, Map<String, dynamic> d) async {
    final total = _n(_map(d['commission'])['total']);
    final rows = <(String, String, String?, TextEditingController, String)>[
      ('contributor', 'جايب العقار — ${_map(d['contributor'])['name']}', _map(d['contributor'])['id'] as String?, TextEditingController(), 'pct'),
      if (_map(d['closer'])['id'] != _map(d['contributor'])['id'])
        ('closer', 'اللي قفل — ${_map(d['closer'])['name']}', _map(d['closer'])['id'] as String?, TextEditingController(), 'pct'),
      if (d['salesManager'] != null)
        ('sales_manager', 'مدير المبيعات — ${_map(d['salesManager'])['name']}', _map(d['salesManager'])['id'] as String?, TextEditingController(), 'pct'),
    ];
    final modes = {for (final r in rows) r.$1: 'pct'};
    final otherName = TextEditingController(), otherAmount = TextEditingController();
    await showModalBottomSheet(
      context: parent, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        num sum() {
          var s = 0.0;
          for (final r in rows) {
            final v = num.tryParse(r.$4.text.trim()) ?? 0;
            s += modes[r.$1] == 'pct' ? total * v / 100 : v;
          }
          return s + (num.tryParse(otherAmount.text.trim()) ?? 0);
        }

        return _sheet(isDark, ctx, 'توزيع عمولة ${_egp(total)}', [
          for (final r in rows) ...[
            Text(r.$2, style: TextStyle(color: Glass.ink(isDark), fontSize: 13.5)),
            Row(children: [
              Expanded(child: JphUi.input(isDark: isDark, label: modes[r.$1] == 'pct' ? 'النسبة ٪' : 'المبلغ', controller: r.$4, number: true, big: false, onChanged: (_) => set(() {}))),
              const SizedBox(width: 8),
              SegmentedButton<String>(
                segments: const [ButtonSegment(value: 'pct', label: Text('٪')), ButtonSegment(value: 'fixed', label: Text('ج'))],
                selected: {modes[r.$1]!},
                onSelectionChanged: (v) => set(() => modes[r.$1] = v.first),
              ),
            ]),
          ],
          JphUi.input(isDark: isDark, label: 'مستفيد آخر (اختياري)', controller: otherName, icon: Icons.person_add_alt_rounded, big: false),
          JphUi.input(isDark: isDark, label: 'مبلغه', controller: otherAmount, number: true, big: false, onChanged: (_) => set(() {})),
          Text('الموزع ${_egp(sum())} · للمكتب ${_egp(math.max(0, total - sum()))}',
              style: TextStyle(color: sum() > total + 0.005 ? Colors.red : Glass.muted(isDark), fontSize: 13)),
        ], 'اعتماد', () async {
          final shares = [
            for (final r in rows)
              if ((num.tryParse(r.$4.text.trim()) ?? 0) > 0) {'role': r.$1, 'employeeId': r.$3, 'mode': modes[r.$1], 'value': num.tryParse(r.$4.text.trim())},
            if (otherName.text.trim().length >= 2 && (num.tryParse(otherAmount.text.trim()) ?? 0) > 0)
              {'role': 'other', 'beneficiary': otherName.text.trim(), 'mode': 'fixed', 'value': num.tryParse(otherAmount.text.trim())},
          ];
          final r = await _send('/brokerage/deals/${d['id']}/decision', {'decision': 'approve', 'shares': shares}, ok: 'اتعتمدت ✅');
          if (!ctx.mounted) return;
          JphUi.toast(ctx, r);
          if (r['success'] == true) {
            Navigator.pop(ctx);
            if (parent.mounted) Navigator.pop(parent);
          }
        });
      }),
    );
  }

  Future<void> _collect(bool isDark, BuildContext parent, Map<String, dynamic> d, String side, dynamic left) async {
    final amount = TextEditingController(text: '${_n(left)}');
    final ref = '${DateTime.now().microsecondsSinceEpoch}';
    final clientRef = _uuidFrom(ref);
    final recipient = ApiService.can('cash.office') ? 'manager' : 'hr';
    await showModalBottomSheet(
      context: parent, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (ctx) => _sheet(isDark, ctx, 'تحصيل عمولة — باقي ${_egp(left)}', [
        JphUi.input(isDark: isDark, label: 'المبلغ', controller: amount, number: true, icon: Icons.payments_rounded, big: false),
      ], 'تحصيل', () async {
        final r = await _send('/brokerage/deals/${d['id']}/collect',
            {'side': side, 'amount': num.tryParse(amount.text.trim()), 'recipient': recipient, 'clientRef': clientRef}, ok: 'اتحصلت ✅');
        if (!ctx.mounted) return;
        JphUi.toast(ctx, r);
        if (r['success'] == true) {
          Navigator.pop(ctx);
          if (parent.mounted) Navigator.pop(parent);
        }
      }),
    );
  }

  /// a v4-shaped UUID for the form's retry key (the same form sent twice → one receipt)
  static String _uuidFrom(String seed) {
    final r = math.Random.secure();
    String h(int n) => List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
    return '${h(8)}-${h(4)}-4${h(3)}-${['8', '9', 'a', 'b'][r.nextInt(4)]}${h(3)}-${h(12)}';
  }
}
