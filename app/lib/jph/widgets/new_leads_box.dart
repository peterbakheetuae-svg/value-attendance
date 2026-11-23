import 'package:flutter/material.dart' hide Text;
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';

import '../pages/leads/lead_page.dart' show openLead;
import '../pages/leads/leads_api.dart' show lget, lm, ll, openLeadsPage;
import '../pages/leads/leads_list_page.dart';
import '../services/api_service.dart';
import 'glass_ui.dart';
import 'jph_form_ui.dart';

/// «ليد جديد»: on the salesperson's home screen — his newest lead that is still «جديد» (assigned to him, not worked yet);
/// with more than one, «عرض المزيد» opens all his new leads. Nothing when he has none (or does not work leads).
class NewLeadsBox extends StatefulWidget {
  final bool isDark;
  const NewLeadsBox({super.key, required this.isDark});

  @override
  State<NewLeadsBox> createState() => _NewLeadsBoxState();
}

class _NewLeadsBoxState extends State<NewLeadsBox> {
  Map<String, dynamic>? _first;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!ApiService.can('leads.own')) return;
    Map<String, dynamic> r;
    try {
      r = await lget('/leads', {'tab': 'mine', 'stage': 'new', 'sort': 'created', 'size': '5'});
    } catch (_) {
      return;
    }
    if (!mounted || r['success'] == false) return;
    final rows = ll(r['leads']);
    setState(() {
      _first = rows.isEmpty ? null : rows.first;
      _total = (r['total'] as num?)?.toInt() ?? rows.length;
    });
  }

  String _ago(Object? iso) {
    final t = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    if (t == null) return '';
    final m = DateTime.now().difference(t).inMinutes;
    if (m < 1) return 'دلوقتي';
    if (m < 60) return 'من $m دقيقة';
    if (m < 60 * 24) return 'من ${m ~/ 60} ساعة';
    return 'من ${m ~/ (60 * 24)} يوم';
  }

  @override
  Widget build(BuildContext context) {
    final l = _first;
    if (l == null) return const SizedBox.shrink();
    final d = widget.isDark;
    final project = '${lm(l['project'])['name'] ?? ''}';
    final more = _total - 1;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: Glass.panel(d, r: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Ar.green.withOpacity(0.15), borderRadius: BorderRadius.circular(12)),
            child: Icon(Icons.person_add_alt_1_rounded, color: Ar.green, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(_total > 1 ? 'عندك $_total ليد جديد' : 'عندك ليد جديد',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Glass.ink(d))),
          ),
          IconButton(onPressed: _load, icon: Icon(Icons.refresh_rounded, color: Glass.muted(d), size: 20)),
        ]),
        const SizedBox(height: 10),
        InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () async {
            await openLead(context, '${l['id']}');
            _load();
          },
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: JphUi.box(d),
            child: Row(children: [
              JphUi.personAvatar('${l['fullName'] ?? ''}', null, size: 42),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${l['fullName'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: Glass.ink(d))),
                  const SizedBox(height: 3),
                  Text([if (project.isNotEmpty) project, _ago(l['assignedAt'] ?? l['createdAt'])].join(' · '),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: Glass.muted(d))),
                ]),
              ),
              Icon(Icons.chevron_left_rounded, color: Glass.muted(d)),
            ]),
          ),
        ),
        if (more > 0) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 44,
            child: OutlinedButton.icon(
              onPressed: () async {
                await openLeadsPage(context, const LeadsListPage(tab: 'mine', stage: 'new'));
                _load();
              },
              icon: const Icon(Icons.list_alt_rounded),
              label: Text('عرض المزيد ($more)', style: const TextStyle(fontWeight: FontWeight.w700)),
              style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            ),
          ),
        ],
      ]),
    );
  }
}
