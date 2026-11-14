import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import 'lead_page.dart' show openLead;
import 'leads_api.dart';

/// الصفقات (like Elite): a board of three columns — مفتوحة / ناجحة / خاسرة. Drag a card to another column
/// (or between two cards) to move it; on the phone a long press drags too, or the card's menu moves it.
class DealsPage extends StatefulWidget {
  const DealsPage({super.key});

  @override
  State<DealsPage> createState() => _DealsPageState();
}

const _cols = [('open', 'مفتوحة', Icons.timelapse_rounded), ('won', 'ناجحة', Icons.emoji_events_rounded), ('lost', 'خاسرة', Icons.cancel_rounded)];
Color _colColor(String s) => switch (s) { 'won' => Ar.green, 'lost' => Ar.red, _ => Ar.info };

class _DealsPageState extends State<DealsPage> {
  Map<String, dynamic> _d = {}, _meta = {};
  bool _loading = true;
  final _q = TextEditingController();
  String? _hoverCol;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Future.wait([lget('/deals', {'q': _q.text.trim()}), LeadsMeta.load()]);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _d = r[0];
      _meta = r[1];
    });
  }

  List<Map<String, dynamic>> _of(String stage) => ll(_d['deals']).where((x) => x['stage'] == stage).toList()
    ..sort((a, b) => ((a['sort'] as num?) ?? 0).compareTo((b['sort'] as num?) ?? 0));

  Future<void> _move(Map<String, dynamic> deal, String stage, {String? beforeId}) async {
    if (deal['stage'] == stage && beforeId == null) return;
    String? reason;
    if (stage == 'lost' && deal['stage'] != 'lost') {
      final c = TextEditingController();
      final isDark = context.read<AppController>().isDark;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('سبب الخسارة')),
          content: JphUi.input(isDark: isDark, label: tr('ليه الصفقة اتخسرت؟ (اختياري)'), controller: c, icon: Icons.notes_rounded, big: false),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('رجوع'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('خاسرة'))),
          ],
        ),
      );
      if (ok != true) return;
      reason = c.text.trim();
    }
    // move it on the screen at once, then save
    setState(() => deal['stage'] = stage);
    final r = await lpost('/deals/${deal['id']}', {'stage': stage, if (beforeId != null) 'beforeId': beforeId, if (reason != null) 'lostReason': reason},
        method: 'patch');
    if (!mounted) return;
    if (r['success'] != true) JphUi.toast(context, r);
    _load();
  }

  Future<void> _delete(Map<String, dynamic> x) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('حذف الصفقة؟')),
        content: Text(tr('الصفقة هتتحذف نهائي ومش هترجع.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('رجوع'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('احذف'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final r = await lpost('/deals/${x['id']}/delete', {}, ok: tr('اتحذفت'));
    if (!mounted) return;
    JphUi.toast(context, r);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final can = lm(_d['can']);
    final totals = lm(_d['totals']);
    return LeadsShell(
      isDark: isDark,
      title: tr('الصفقات'),
      fab: can['create'] == true
          ? FloatingActionButton.extended(
              onPressed: () async {
                if (await editDeal(context, isDark, _meta)) _load();
              },
              backgroundColor: JphUi.primary(isDark),
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add_rounded),
              label: Text(tr('صفقة جديدة'), style: const TextStyle(fontWeight: FontWeight.w800)),
            )
          : null,
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _d['success'] == false
              ? Center(child: Text('${_d['message']}', style: TextStyle(color: JphUi.sub(isDark))))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 110), children: [
                    Text(tr('مراحل الصفقات'), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    Text(tr('اسحب الصفقة لعمود تاني عشان تنقلها.'), style: TextStyle(color: JphUi.sub(isDark))),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _q,
                      onSubmitted: (_) => _load(),
                      decoration: InputDecoration(
                        hintText: tr('دوّر باسم الصفقة أو العميل أو الرقم'),
                        prefixIcon: const Icon(Icons.search_rounded),
                        isDense: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(builder: (context, box) {
                      final wide = box.maxWidth >= 860;
                      final colW = wide ? (box.maxWidth - 24) / 3 : box.maxWidth * 0.82;
                      final cols = [for (final c in _cols) SizedBox(width: colW, child: _column(isDark, c, lm(totals[c.$1]), can))];
                      return wide
                          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              for (var i = 0; i < cols.length; i++) ...[if (i > 0) const SizedBox(width: 12), cols[i]],
                            ])
                          : SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                for (var i = 0; i < cols.length; i++) ...[if (i > 0) const SizedBox(width: 10), cols[i]],
                              ]),
                            );
                    }),
                  ]),
                ),
    );
  }

  Widget _column(bool isDark, (String, String, IconData) c, Map<String, dynamic> total, Map<String, dynamic> can) {
    final items = _of(c.$1);
    final color = _colColor(c.$1);
    return DragTarget<Map<String, dynamic>>(
      onWillAcceptWithDetails: (d) {
        setState(() => _hoverCol = c.$1);
        return can['edit'] == true;
      },
      onLeave: (_) => setState(() => _hoverCol = null),
      onAcceptWithDetails: (d) {
        setState(() => _hoverCol = null);
        _move(d.data, c.$1);
      },
      builder: (context, cand, rej) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(10),
        constraints: const BoxConstraints(minHeight: 260),
        decoration: BoxDecoration(
          color: (_hoverCol == c.$1 ? color.withOpacity(0.16) : (isDark ? Colors.white.withOpacity(0.04) : const Color(0xFFF6F5F3))),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _hoverCol == c.$1 ? color : (isDark ? Colors.white12 : const Color(0xFFE6E3DE)), width: _hoverCol == c.$1 ? 2 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(c.$3, color: color, size: 20),
            const SizedBox(width: 8),
            Text(tr(c.$2), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
            const SizedBox(width: 8),
            pill('${total['count'] ?? items.length}', color, dot: false),
            const Spacer(),
            Text(JphUi.money(total['value'] ?? 0), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: JphUi.sub(isDark))),
          ]),
          const SizedBox(height: 10),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Text(tr('افلت الصفقات هنا'), textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark))),
            ),
          for (final x in items) _card(isDark, x, can),
        ]),
      ),
    );
  }

  Widget _card(bool isDark, Map<String, dynamic> x, Map<String, dynamic> can) {
    final card = _cardBody(isDark, x, can);
    if (can['edit'] != true) return card;
    // drop on a card = put the dragged one above it
    final target = DragTarget<Map<String, dynamic>>(
      onWillAcceptWithDetails: (d) => d.data['id'] != x['id'],
      onAcceptWithDetails: (d) => _move(d.data, '${x['stage']}', beforeId: '${x['id']}'),
      builder: (context, cand, rej) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (cand.isNotEmpty) Container(height: 4, margin: const EdgeInsets.only(bottom: 6), decoration: BoxDecoration(color: Ar.accent, borderRadius: BorderRadius.circular(2))),
        card,
      ]),
    );
    final feedback = Material(color: Colors.transparent, child: SizedBox(width: 260, child: Opacity(opacity: 0.9, child: _cardBody(isDark, x, can))));
    final ghost = Opacity(opacity: 0.35, child: card);
    // the computer: drag with the mouse at once; the phone: a long press starts the drag (the list still scrolls)
    return MediaQuery.of(context).size.width >= 860
        ? Draggable<Map<String, dynamic>>(data: x, feedback: feedback, childWhenDragging: ghost, child: target)
        : LongPressDraggable<Map<String, dynamic>>(data: x, feedback: feedback, childWhenDragging: ghost, child: target);
  }

  Widget _cardBody(bool isDark, Map<String, dynamic> x, Map<String, dynamic> can) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2A2927) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(isDark ? 0.3 : 0.06), blurRadius: 10, offset: const Offset(0, 3))],
        ),
        child: InkWell(
          onTap: () async {
            if (await editDeal(context, isDark, _meta, deal: x, can: can)) _load();
          },
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text('${x['title']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
              ),
              Text('#${x['refNo']}', style: TextStyle(fontSize: 11, color: JphUi.sub(isDark))),
              if (can['edit'] == true)
                PopupMenuButton<String>(
                  tooltip: tr('نقل'),
                  icon: const Icon(Icons.more_vert_rounded, size: 18),
                  onSelected: (s) => s == 'delete' ? _delete(x) : _move(x, s),
                  itemBuilder: (_) => [
                    for (final c in _cols) if (c.$1 != x['stage']) PopupMenuItem(value: c.$1, child: Text('${tr('انقل لـ')} ${tr(c.$2)}')),
                    if (can['delete'] == true) PopupMenuItem(value: 'delete', child: Text(tr('حذف الصفقة'), style: const TextStyle(color: Ar.red))),
                  ],
                ),
            ]),
            if (x['value'] != null) Text(JphUi.money(x['value']), style: TextStyle(fontWeight: FontWeight.w800, color: Ar.accent.shade700)),
            const SizedBox(height: 4),
            Text([
              if (lm(x['project'])['name'] != null) '${lm(x['project'])['name']}',
              if ('${x['unit'] ?? ''}'.isNotEmpty) '${x['unit']}',
              if (lm(x['owner'])['name'] != null) '${lm(x['owner'])['name']}',
            ].join(' · '), maxLines: 2, style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
            if (x['lead'] != null)
              TextButton.icon(
                style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                onPressed: () => openLead(context, '${lm(x['lead'])['id']}'),
                icon: const Icon(Icons.person_rounded, size: 16),
                label: Text('${lm(x['lead'])['name']}'),
              ),
            if (x['stage'] == 'lost' && '${x['lostReason'] ?? ''}'.isNotEmpty)
              Text('${tr('السبب')}: ${x['lostReason']}', style: const TextStyle(fontSize: 12, color: Ar.red)),
          ]),
        ),
      );
}

/// add a deal (from a lead = «تحويل لصفقة») or edit one
Future<bool> editDeal(BuildContext context, bool isDark, Map<String, dynamic> meta,
    {Map<String, dynamic>? lead, Map<String, dynamic>? deal, Map<String, dynamic>? can}) async {
  final title = TextEditingController(text: '${deal?['title'] ?? lead?['fullName'] ?? ''}');
  final value = TextEditingController(text: deal?['value'] == null ? '' : '${deal!['value']}');
  final unit = TextEditingController(text: '${deal?['unit'] ?? ''}');
  final notes = TextEditingController(text: '${deal?['notes'] ?? ''}');
  String? project = '${lm(deal?['project'])['id'] ?? lm(lead?['project'])['id'] ?? ''}';
  if (project.isEmpty) project = null;
  final projects = ll(meta['projects']);
  final editing = deal != null;
  return leadForm(context, isDark, editing ? '${tr('صفقة')} #${deal['refNo']}' : (lead != null ? '${tr('تحويل العميل')} — ${lead['fullName']}' : tr('صفقة جديدة')), (set) => [
        JphUi.input(isDark: isDark, label: tr('اسم الصفقة'), controller: title, icon: Icons.handshake_rounded, big: false),
        JphUi.input(isDark: isDark, label: tr('القيمة'), controller: value, number: true, icon: Icons.payments_rounded, big: false),
        refPicker(context, isDark, tr('المشروع'), Icons.apartment_rounded, projects, project, (v) => set(() => project = v)),
        JphUi.input(isDark: isDark, label: tr('الوحدة (اختياري)'), controller: unit, icon: Icons.home_work_rounded, big: false),
        JphUi.input(isDark: isDark, label: tr('ملاحظات'), controller: notes, icon: Icons.notes_rounded, big: false),
      ], () async {
    final v = num.tryParse(value.text.replaceAll(',', '').trim());
    final body = {
      'title': title.text.trim(), 'value': v, 'unit': unit.text.trim(), 'notes': notes.text.trim(),
      if (project != null) 'projectId': project,
      if (!editing && lead != null) 'leadId': lead['id'],
    };
    final r = editing
        ? await lpost('/deals/${deal['id']}', body, method: 'patch', ok: tr('اتحفظ ✅'))
        : await lpost('/deals', body, ok: tr('اتعملت الصفقة ✅'));
    if (context.mounted) JphUi.toast(context, r);
    return r['success'] == true;
  }, saveLabel: editing ? tr('حفظ') : tr('اعمل الصفقة'));
}
