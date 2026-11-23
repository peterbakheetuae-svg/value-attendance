import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';

import '../pages/leads/lead_page.dart';
import '../pages/leads/leads_api.dart' show lget, ll, lm;
import '../pages/leads/leads_list_page.dart';
import '../services/api_service.dart';
import 'glass_ui.dart';

/// «ليدز جديدة» on the attendance home of whoever works his own leads: the newest new lead assigned to him (stage «جديد»),
/// and «عرض المزيد» when there is more than one → the list of all his new leads. Nothing when he has none.
/// Refreshed every minute while the home is open.
class NewLeadsCard extends StatefulWidget {
  final bool isDark;
  const NewLeadsCard({super.key, required this.isDark});

  @override
  State<NewLeadsCard> createState() => _NewLeadsCardState();
}

class _NewLeadsCardState extends State<NewLeadsCard> {
  List<Map<String, dynamic>> _leads = [];
  int _total = 0;
  Timer? _tick;

  bool get _works => ApiService.can('leads.own');

  @override
  void initState() {
    super.initState();
    if (!_works) return;
    _load();
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => _load());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    Map<String, dynamic> r;
    try {
      r = await lget('/leads', {'tab': 'mine', 'stage': 'new', 'sort': 'created', 'size': '5'});
    } catch (_) {
      return;
    }
    if (!mounted || r['success'] == false) return;
    setState(() {
      _leads = ll(r['leads']);
      _total = int.tryParse('${r['total'] ?? ''}') ?? _leads.length;
    });
  }

  Future<void> _open(Widget page) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    _load();
  }

  String _ago(String? iso) {
    final t = DateTime.tryParse(iso ?? '')?.toLocal();
    if (t == null) return '';
    final m = DateTime.now().difference(t).inMinutes;
    if (m < 1) return 'دلوقتي';
    if (m < 60) return 'من $m دقيقة';
    if (m < 60 * 24) return 'من ${m ~/ 60} ساعة';
    return 'من ${m ~/ (60 * 24)} يوم';
  }

  @override
  Widget build(BuildContext context) {
    if (!_works || _leads.isEmpty) return const SizedBox.shrink();
    final d = widget.isDark;
    final l = _leads.first;
    final project = lm(l['project'])['name'];
    final pending = l['pending'] == true;
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: Glass.panel(d, r: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: Glass.blue.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.person_add_alt_1_rounded, color: Glass.blue, size: 20),
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
          borderRadius: BorderRadius.circular(14),
          onTap: () => _open(LeadPage(leadId: '${l['id']}')),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: d ? Colors.white.withOpacity(0.06) : const Color(0x8CFFFFFF),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: pending ? Colors.orange.withOpacity(0.6) : Glass.line(d)),
            ),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${l['fullName'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: Glass.ink(d))),
                  const SizedBox(height: 3),
                  Text([if (project != null) '$project', _ago(l['assignedAt'] as String? ?? l['createdAt'] as String?)].where((x) => x.isNotEmpty).join(' · '),
                      style: TextStyle(fontSize: 12.5, color: Glass.muted(d))),
                  if (pending) ...[
                    const SizedBox(height: 3),
                    const Text('مستني أول تواصل منك', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.orange)),
                  ],
                ]),
              ),
              Icon(Icons.chevron_left_rounded, color: Glass.muted(d)),
            ]),
          ),
        ),
        if (_total > 1) ...[
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              // a salesman's list is his own already («عملائي» is a managers' tab)
              onPressed: () => _open(LeadsListPage(
                  tab: ApiService.can('leads.team') || ApiService.can('leads.read_all') ? 'mine' : 'all', stage: 'new')),
              icon: const Icon(Icons.list_alt_rounded, size: 18),
              label: Text('عرض المزيد (${_total - 1})'),
            ),
          ),
        ],
      ]),
    );
  }
}
