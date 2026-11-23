import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart' hide Text;
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';

import '../../services/api_service.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/side_sheet.dart';

/// مجموعات وتصنيفات المصروفات — classification only (server: /cash/expense-classes, proposed migration 086).
/// A group (تشغيل المكتب، تسويق…) offers categories (قهوة، كهربا، صيانة…); one category can sit in many groups.
/// Choosing / changing them never changes an expense's amount, approval, payment or the cashbox — the server keeps that.

Future<Map<String, dynamic>> _get(String path, [Map<String, dynamic> query = const {}]) =>
    ApiService.post({'action': 'cash_get', 'path': path, 'query': query});
Future<Map<String, dynamic>> _send(String path, Map<String, dynamic> body, {String? ok, bool patch = false}) =>
    ApiService.post({'action': 'cash_post', 'path': path, 'body': body, 'ok': ok, if (patch) 'method': 'patch'});
List<Map<String, dynamic>> _rows(Map<String, dynamic> r, String k) =>
    ((r[k] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();

/// The groups / categories as the server has them now (empty and not installed until 086 runs).
class ExpenseClasses {
  final bool installed;
  final bool canManage;
  final List<Map<String, dynamic>> groups;
  final List<Map<String, dynamic>> categories;
  const ExpenseClasses({this.installed = false, this.canManage = false, this.groups = const [], this.categories = const []});

  static Future<ExpenseClasses> load({String active = 'active'}) async {
    final r = await _get('/cash/expense-classes', {'active': active});
    if (r['success'] != true || r['installed'] != true) return const ExpenseClasses();
    return ExpenseClasses(installed: true, canManage: (r['can'] as Map?)?['manage'] == true,
        groups: _rows(r, 'groups'), categories: _rows(r, 'categories'));
  }

  String? groupName(Object? id) => id == null ? null : groups.where((g) => g['id'] == id).map((g) => '${g['name']}').firstOrNull;
  String? categoryName(Object? id) => id == null ? null : categories.where((c) => c['id'] == id).map((c) => '${c['name']}').firstOrNull;

  /// the categories a group offers (all of them when no group is chosen)
  List<Map<String, dynamic>> categoriesOf(String? groupId) {
    if (groupId == null) return categories;
    final g = groups.where((x) => x['id'] == groupId).firstOrNull;
    final ids = ((g?['categoryIds'] as List?) ?? const []).map((e) => '$e').toSet();
    return categories.where((c) => ids.contains('${c['id']}')).toList();
  }
}

/// A searchable list in the app's sheet; returns the chosen id, '' for «بدون», null when closed.
Future<String?> pickFromList(BuildContext context, bool isDark, String title, List<Map<String, dynamic>> items,
    {String? selected, String none = 'بدون'}) {
  final q = TextEditingController();
  return showAppSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final t = q.text.trim().toLowerCase();
      final shown = items.where((x) => t.isEmpty || '${x['name']}'.toLowerCase().contains(t)).toList();
      return Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          decoration: BoxDecoration(color: isDark ? const Color(0xFF262624) : Colors.white,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(26))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
            const SizedBox(height: 12),
            JphUi.input(isDark: isDark, label: 'بحث', controller: q, icon: Icons.search_rounded, big: false, onChanged: (_) => setS(() {})),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                ListTile(
                  leading: Icon(Icons.block_rounded, color: JphUi.sub(isDark)),
                  title: Text(none, style: TextStyle(color: JphUi.sub(isDark), fontWeight: FontWeight.w700)),
                  selected: selected == null,
                  onTap: () => Navigator.pop(ctx, ''),
                ),
                for (final x in shown)
                  ListTile(
                    leading: Icon(Icons.label_rounded, color: Ar.accent),
                    title: Text('${x['name']}', style: TextStyle(color: JphUi.text(isDark), fontWeight: FontWeight.w800)),
                    subtitle: '${x['description'] ?? ''}'.isEmpty ? null : Text('${x['description']}', style: TextStyle(color: JphUi.sub(isDark))),
                    trailing: selected == x['id'] ? const Icon(Icons.check_rounded, color: Ar.green) : null,
                    onTap: () => Navigator.pop(ctx, '${x['id']}'),
                  ),
                if (shown.isEmpty)
                  Padding(padding: const EdgeInsets.all(20), child: Text('مفيش نتايج', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
              ]),
            ),
          ]),
        ),
      );
    }),
  );
}

/// The two pickers of the expense form (group, then one of its categories). Optional: both may stay empty.
class ExpenseClassFields extends StatelessWidget {
  final bool isDark;
  final ExpenseClasses classes;
  final String? groupId, categoryId;
  final void Function(String? groupId, String? categoryId) onChanged;
  const ExpenseClassFields({super.key, required this.isDark, required this.classes, required this.groupId, required this.categoryId,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    if (!classes.installed) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      JphUi.picker(isDark: isDark, icon: Icons.folder_rounded, iconColor: Ar.accent, label: 'المجموعة (اختياري)',
          value: classes.groupName(groupId) ?? 'بدون مجموعة', onTap: () async {
        final v = await pickFromList(context, isDark, 'المجموعة', classes.groups, selected: groupId, none: 'بدون مجموعة');
        if (v == null) return;
        final g = v.isEmpty ? null : v;
        // a category that is not in the new group is cleared
        final keep = categoryId != null && classes.categoriesOf(g).any((c) => c['id'] == categoryId);
        onChanged(g, keep ? categoryId : null);
      }),
      const SizedBox(height: 10),
      JphUi.picker(isDark: isDark, icon: Icons.sell_rounded, iconColor: Ar.info, label: 'التصنيف (اختياري)',
          value: classes.categoryName(categoryId) ?? 'بدون تصنيف', onTap: () async {
        final v = await pickFromList(context, isDark, 'التصنيف', classes.categoriesOf(groupId), selected: categoryId, none: 'بدون تصنيف');
        if (v == null) return;
        onChanged(groupId, v.isEmpty ? null : v);
      }),
    ]);
  }
}

/// «غير مصنف» or «المجموعة • التصنيف» on an expense card
Widget expenseClassChip(Map<String, dynamic> x) {
  final g = x['expenseGroupName'], c = x['expenseCategoryName'];
  if (g == null && c == null) return JphUi.chip('غير مصنف', Ar.grey);
  return JphUi.chip([if (g != null) '$g', if (c != null) '$c'].join(' • '), Ar.info);
}

/// Re-classify one recorded expense (metadata only — the server refuses anything else).
Future<bool> reclassifyExpense(BuildContext context, bool isDark, ExpenseClasses classes, Map<String, dynamic> x) async {
  String? g = x['expenseGroupId'] as String?, c = x['expenseCategoryId'] as String?;
  var done = false;
  await showAppSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => Directionality(
          textDirection: ui.TextDirection.rtl,
          child: Container(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
            decoration: BoxDecoration(color: isDark ? const Color(0xFF262624) : Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(26))),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('تصنيف المصروف #${x['refNo']}', textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
              const SizedBox(height: 6),
              Text('التصنيف للتقارير بس — المبلغ والخزنة والموافقة مش بيتغيروا', textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
              const SizedBox(height: 14),
              ExpenseClassFields(isDark: isDark, classes: classes, groupId: g, categoryId: c,
                  onChanged: (ng, nc) => setS(() { g = ng; c = nc; })),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  final r = await _send('/cash/expenses/${x['id']}/classification', {'groupId': g, 'categoryId': c}, ok: 'اتحفظ التصنيف ✅', patch: true);
                  if (!ctx.mounted) return;
                  JphUi.toast(ctx, r);
                  if (r['success'] == true) { done = true; Navigator.pop(ctx); }
                },
                style: ElevatedButton.styleFrom(backgroundColor: JphUi.primary(isDark), foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 54), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
                child: const Text('حفظ', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
              ),
            ]),
          ),
        )),
  );
  return done;
}

// ============================================================ the management screen: groups · categories · report

/// a date range: preset or custom (Cairo days, as the server counts them)
class _Range {
  final String label;
  final String? from, to;
  const _Range(this.label, this.from, this.to);
}

String _d(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

List<_Range> _presets() {
  final n = DateTime.now();
  final m0 = DateTime(n.year, n.month, 1), pm0 = DateTime(n.year, n.month - 1, 1), pm1 = DateTime(n.year, n.month, 0);
  return [
    _Range('الشهر ده', _d(m0), _d(n)),
    _Range('الشهر اللي فات', _d(pm0), _d(pm1)),
    _Range('السنة دي', _d(DateTime(n.year, 1, 1)), _d(n)),
    const _Range('من الأول', null, null),
  ];
}

class ExpenseClassesView extends StatefulWidget {
  final bool isDark;
  /// the cashbox page's own filter on top (a month, or «كل الشهور»): when given, this view follows it and shows no
  /// period filter of its own
  final ValueListenable<DateTime>? month;
  final ValueListenable<bool>? allMonths;
  const ExpenseClassesView({super.key, required this.isDark, this.month, this.allMonths});
  @override
  State<ExpenseClassesView> createState() => _ExpenseClassesViewState();
}

class _ExpenseClassesViewState extends State<ExpenseClassesView> {
  int _tab = 0; // 0 المجموعات • 1 التصنيفات • 2 التقرير
  String _active = 'active';
  final _q = TextEditingController();
  _Range _range = _presets().first;
  bool _loading = true;
  Map<String, dynamic> _data = const {};

  @override
  void initState() {
    super.initState();
    _followTop();
    widget.month?.addListener(_onTop);
    widget.allMonths?.addListener(_onTop);
    _load();
  }

  @override
  void dispose() {
    widget.month?.removeListener(_onTop);
    widget.allMonths?.removeListener(_onTop);
    super.dispose();
  }

  bool get _followsTop => widget.month != null;

  /// the period = the cashbox page's filter: one month (its first day → its last), or every month
  void _followTop() {
    if (!_followsTop) return;
    if (widget.allMonths?.value == true) {
      _range = const _Range('كل الشهور', null, null);
      return;
    }
    final m = widget.month!.value;
    _range = _Range('${JphUi.monthsAr[m.month - 1]} ${m.year}', _d(DateTime(m.year, m.month, 1)), _d(DateTime(m.year, m.month + 1, 0)));
  }

  void _onTop() {
    if (!mounted) return;
    setState(_followTop);
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await _get('/cash/expense-classes', {'active': _active, 'q': _q.text.trim(), 'from': _range.from, 'to': _range.to});
    if (!mounted) return;
    setState(() { _data = r; _loading = false; });
  }

  bool get _installed => _data['installed'] == true;
  bool get _manage => (_data['can'] as Map?)?['manage'] == true;

  Future<void> _pickRange() async {
    final v = await JphUi.sheet<int>(context, widget.isDark, 'الفترة', [
      for (var i = 0; i < _presets().length; i++) (i, _presets()[i].label, Icons.date_range_rounded),
      (-1, 'فترة تختارها…', Icons.edit_calendar_rounded),
    ]);
    if (v == null) return;
    if (v >= 0) {
      setState(() => _range = _presets()[v]);
    } else {
      if (!mounted) return;
      final r = await showDateRangePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime.now());
      if (r == null) return;
      setState(() => _range = _Range('${_d(r.start)} ← ${_d(r.end)}', _d(r.start), _d(r.end)));
    }
    await _load();
  }

  /// create / edit one group or category (name, description, its links)
  Future<void> _edit(String kind, [Map<String, dynamic>? x]) async {
    final isDark = widget.isDark;
    final name = TextEditingController(text: x?['name'] ?? ''), desc = TextEditingController(text: x?['description'] ?? '');
    final others = _rows(_data, kind == 'group' ? 'categories' : 'groups').where((o) => o['isActive'] == true).toList();
    final linkKey = kind == 'group' ? 'categoryIds' : 'groupIds';
    final links = {...((x?[linkKey] as List?) ?? const []).map((e) => '$e')};
    var saving = false;
    await showAppSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => Directionality(
            textDirection: ui.TextDirection.rtl,
            child: Container(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.92),
              padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
              decoration: BoxDecoration(color: isDark ? const Color(0xFF262624) : Colors.white,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(26))),
              child: SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                  Text(x == null ? (kind == 'group' ? 'مجموعة جديدة' : 'تصنيف جديد') : 'تعديل ${x['name']}', textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                  const SizedBox(height: 14),
                  JphUi.input(isDark: isDark, label: 'الاسم *', controller: name, icon: Icons.label_rounded, big: false),
                  const SizedBox(height: 12),
                  JphUi.input(isDark: isDark, label: 'وصف (اختياري)', controller: desc, icon: Icons.notes_rounded, big: false),
                  const SizedBox(height: 14),
                  Text(kind == 'group' ? 'التصنيفات اللي في المجموعة' : 'المجموعات اللي فيها التصنيف',
                      style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final o in others)
                      FilterChip(label: Text('${o['name']}'), selected: links.contains('${o['id']}'),
                          onSelected: (v) => setS(() => v ? links.add('${o['id']}') : links.remove('${o['id']}'))),
                    if (others.isEmpty) Text('لسه مفيش', style: TextStyle(color: JphUi.sub(isDark))),
                  ]),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: saving
                        ? null
                        : () async {
                            setS(() => saving = true);
                            final path = '/cash/expense-classes/${kind == 'group' ? 'groups' : 'categories'}';
                            final body = {'name': name.text.trim(), 'description': desc.text.trim(), linkKey: links.toList()};
                            final r = x == null ? await _send(path, body, ok: 'اتضاف ✅') : await _send('$path/${x['id']}', body, ok: 'اتعدل ✅', patch: true);
                            setS(() => saving = false);
                            if (!ctx.mounted) return;
                            JphUi.toast(ctx, r);
                            if (r['success'] == true) Navigator.pop(ctx);
                          },
                    style: ElevatedButton.styleFrom(backgroundColor: JphUi.primary(isDark), foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 54), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
                    child: const Text('حفظ', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                  ),
                ]),
              ),
            ),
          )),
    );
    await _load();
  }

  Future<void> _archive(String kind, Map<String, dynamic> x, bool active) async {
    final r = await _send('/cash/expense-classes/${kind == 'group' ? 'groups' : 'categories'}/${x['id']}', {'isActive': active},
        ok: active ? 'اترجع نشط ✅' : 'اتأرشف ✅', patch: true);
    if (!mounted) return;
    JphUi.toast(context, r);
    await _load();
  }

  Future<void> _details(String kind, Map<String, dynamic> x) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _ClassDetailPage(isDark: widget.isDark, kind: kind, item: x, range: _range)));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    if (!_loading && !_installed) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text('تصنيف المصروفات لسه مش متفعّل — محتاج تحديث قاعدة البيانات بموافقة المالك.', textAlign: TextAlign.center,
            style: TextStyle(color: JphUi.sub(isDark))),
      );
    }
    final kind = _tab == 0 ? 'group' : 'category';
    final items = _rows(_data, _tab == 0 ? 'groups' : 'categories');
    final names = {for (final g in _rows(_data, 'groups')) '${g['id']}': '${g['name']}', for (final c in _rows(_data, 'categories')) '${c['id']}': '${c['name']}'};
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      JphUi.tabs(isDark, const [('المجموعات', Icons.folder_rounded), ('التصنيفات', Icons.sell_rounded), ('التقرير', Icons.bar_chart_rounded)], _tab,
          (i) => setState(() => _tab = i)),
      const SizedBox(height: 12),
      // the period: the cashbox page's filter on top when there is one (no second filter here)
      if (!_followsTop) ...[
        JphUi.picker(isDark: isDark, icon: Icons.date_range_rounded, iconColor: Ar.info, label: 'الفترة', value: _range.label, onTap: _pickRange),
        const SizedBox(height: 12),
      ],
      if (_tab == 2)
        _ReportView(isDark: isDark, range: _range)
      else ...[
        JphUi.input(isDark: isDark, label: 'بحث', controller: _q, icon: Icons.search_rounded, big: false, onSubmitted: (_) => _load()),
        const SizedBox(height: 10),
        Wrap(spacing: 6, children: [
          for (final (k, l) in const [('active', 'نشط'), ('archived', 'مؤرشف'), ('all', 'الكل')])
            ChoiceChip(label: Text(l), selected: _active == k, onSelected: (_) { setState(() => _active = k); _load(); }),
        ]),
        const SizedBox(height: 10),
        if (_manage)
          OutlinedButton.icon(
            onPressed: () => _edit(kind),
            icon: const Icon(Icons.add_rounded),
            label: Text(_tab == 0 ? 'مجموعة جديدة' : 'تصنيف جديد'),
          ),
        const SizedBox(height: 10),
        if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        if (!_loading && items.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text('مفيش', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        if (!_loading)
          for (final x in items)
            GestureDetector(
              onTap: () => _details(kind, x),
              child: Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(14),
                decoration: JphUi.box(isDark),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    JphUi.iconTile(isDark, _tab == 0 ? Icons.folder_rounded : Icons.sell_rounded, x['isActive'] == true ? Ar.accent : Ar.grey),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${x['name']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                        if ('${x['description'] ?? ''}'.isNotEmpty)
                          Text('${x['description']}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                        Text('${x['count']} مصروف', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                      ]),
                    ),
                    Text(JphUi.money(x['total']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                  ]),
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    if (x['isActive'] != true) JphUi.chip('مؤرشف', Ar.grey),
                    for (final id in ((x[_tab == 0 ? 'categoryIds' : 'groupIds'] as List?) ?? const []))
                      if (names['$id'] != null) JphUi.chip(names['$id']!, Ar.info),
                  ]),
                  if (_manage)
                    Wrap(alignment: WrapAlignment.end, spacing: 8, children: [
                      TextButton(onPressed: () => _edit(kind, x), child: const Text('تعديل')),
                      if (x['isActive'] == true)
                        TextButton(onPressed: () => _archive(kind, x, false), child: const Text('أرشفة', style: TextStyle(color: Ar.red)))
                      else
                        TextButton(onPressed: () => _archive(kind, x, true), child: const Text('إرجاع نشط', style: TextStyle(color: Ar.green))),
                    ]),
                ]),
              ),
            ),
      ],
    ]);
  }
}

/// one group / category: total, count, the split the other way, its expenses — with date and status filters
class _ClassDetailPage extends StatefulWidget {
  final bool isDark;
  final String kind;
  final Map<String, dynamic> item;
  final _Range range;
  const _ClassDetailPage({required this.isDark, required this.kind, required this.item, required this.range});
  @override
  State<_ClassDetailPage> createState() => _ClassDetailPageState();
}

const _statusAr = {'posted': 'اتصرف', 'pending_approval': 'مستني موافقة', 'awaiting_otp': 'مستني الكود', 'rejected': 'مرفوض', 'reversed': 'معكوس', 'all': 'الكل'};

class _ClassDetailPageState extends State<_ClassDetailPage> {
  late _Range _range = widget.range;
  String _status = 'posted';
  Map<String, dynamic> _d = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await _get('/cash/expense-classes/${widget.kind == 'group' ? 'groups' : 'categories'}/${widget.item['id']}',
        {'from': _range.from, 'to': _range.to, 'status': _status});
    if (!mounted) return;
    setState(() { _d = r; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        backgroundColor: isDark ? const Color(0xFF1F1F1E) : const Color(0xFFF6F5F2),
        appBar: AppBar(title: Text('${widget.item['name']}'), backgroundColor: Colors.transparent, elevation: 0,
            foregroundColor: JphUi.text(isDark)),
        body: RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 60), children: [
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final p in _presets())
                ChoiceChip(label: Text(p.label), selected: _range.label == p.label, onSelected: (_) { setState(() => _range = p); _load(); }),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final s in _statusAr.entries)
                ChoiceChip(label: Text(s.value), selected: _status == s.key, onSelected: (_) { setState(() => _status = s.key); _load(); }),
            ]),
            const SizedBox(height: 12),
            if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
            if (!_loading) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: JphUi.box(isDark),
                child: Column(children: [
                  Text(JphUi.money(_d['total']), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                  Text('${_d['count'] ?? 0} مصروف', style: TextStyle(color: JphUi.sub(isDark))),
                  if (widget.item['isActive'] != true) Padding(padding: const EdgeInsets.only(top: 6), child: JphUi.chip('مؤرشف', Ar.grey)),
                ]),
              ),
              const SizedBox(height: 12),
              Text(widget.kind == 'group' ? 'حسب التصنيف' : 'حسب المجموعة', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
              for (final b in _rows(_d, 'breakdown'))
                ListTile(dense: true, title: Text('${b['name']}', style: TextStyle(color: JphUi.text(isDark))),
                    trailing: Text('${JphUi.money(b['total'])} • ${b['count']}', style: TextStyle(color: JphUi.sub(isDark)))),
              const SizedBox(height: 8),
              Text(widget.kind == 'group' ? 'التصنيفات المرتبطة' : 'المجموعات المرتبطة', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [for (final l in _rows(_d, 'linked')) JphUi.chip('${l['name']}', l['isActive'] == true ? Ar.info : Ar.grey)]),
              const SizedBox(height: 12),
              Text('المصروفات', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
              for (final e in _rows(_d, 'expenses'))
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: JphUi.box(isDark),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${e['category']} • #${e['refNo']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                        Text('${e['reason']} • ${e['beneficiary']} • ${JphUi.date(e['at'])}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                      ]),
                    ),
                    Text(JphUi.money(e['amount']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                  ]),
                ),
              if (_d['more'] == true)
                Padding(padding: const EdgeInsets.all(10), child: Text('ظاهر أحدث 200 — ضيّق الفترة للباقي', textAlign: TextAlign.center,
                    style: TextStyle(color: JphUi.sub(isDark)))),
            ],
          ]),
        ),
      ),
    );
  }
}

/// spending by group / category / both / unclassified — daily, monthly, yearly or one total, for the chosen range
class _ReportView extends StatefulWidget {
  final bool isDark;
  final _Range range;
  const _ReportView({required this.isDark, required this.range});
  @override
  State<_ReportView> createState() => _ReportViewState();
}

class _ReportViewState extends State<_ReportView> {
  String _by = 'group', _every = 'none';
  Map<String, dynamic> _r = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _ReportView old) {
    super.didUpdateWidget(old);
    if (old.range.label != widget.range.label) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await _get('/cash/expense-classes/report', {'by': _by, 'every': _every, 'from': widget.range.from, 'to': widget.range.to});
    if (!mounted) return;
    setState(() { _r = r; _loading = false; });
  }

  String _label(Map<String, dynamic> x) => switch (_by) {
        'group' => '${x['groupName']}',
        'category' => '${x['categoryName']}',
        'group_category' => '${x['groupName']} • ${x['categoryName']}',
        _ => '${x['item']}',
      };

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final lines = _rows(_r, 'lines');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final (k, l) in const [('group', 'حسب المجموعة'), ('category', 'حسب التصنيف'), ('group_category', 'المجموعة والتصنيف'), ('unclassified', 'غير المصنف')])
          ChoiceChip(label: Text(l), selected: _by == k, onSelected: (_) { setState(() => _by = k); _load(); }),
      ]),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final (k, l) in const [('none', 'إجمالي'), ('day', 'يومي'), ('month', 'شهري'), ('year', 'سنوي')])
          ChoiceChip(label: Text(l), selected: _every == k, onSelected: (_) { setState(() => _every = k); _load(); }),
      ]),
      const SizedBox(height: 12),
      if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
      if (!_loading) ...[
        Container(
          padding: const EdgeInsets.all(16),
          decoration: JphUi.box(isDark),
          child: Column(children: [
            Text(JphUi.money(_r['total']), style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
            Text('${_r['count'] ?? 0} مصروف • غير مصنف: ${JphUi.money((_r['unclassified'] as Map?)?['total'])}',
                style: TextStyle(color: JphUi.sub(isDark))),
          ]),
        ),
        const SizedBox(height: 8),
        for (final x in lines)
          ListTile(
            dense: true,
            title: Text(_label(x), style: TextStyle(color: JphUi.text(isDark), fontWeight: FontWeight.w700)),
            subtitle: x['period'] == null ? null : Text('${x['period']}'.substring(0, _every == 'year' ? 4 : _every == 'month' ? 7 : 10),
                style: TextStyle(color: JphUi.sub(isDark))),
            trailing: Text('${JphUi.money(x['total'])} • ${x['count']}', style: TextStyle(color: JphUi.text(isDark))),
          ),
        if (lines.isEmpty) Padding(padding: const EdgeInsets.all(20), child: Text('مفيش مصروفات في الفترة دي', textAlign: TextAlign.center,
            style: TextStyle(color: JphUi.sub(isDark)))),
      ],
    ]);
  }
}
