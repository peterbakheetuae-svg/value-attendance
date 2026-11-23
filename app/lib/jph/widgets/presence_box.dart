import 'package:flutter/material.dart' hide Text;
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';

import '../services/api_service.dart';
import '../pages/leads/leads_api.dart' show lget, lm, ll;
import 'glass_ui.dart';
import 'jph_form_ui.dart';

/// «الموظفين دلوقتي» at the end of the attendance page — for HR and the admin officer only (the server says who): every
/// employee with his photo, a green / red dot (online in the last 10 minutes) and where he is now. Shows nothing for
/// anyone else.
class PresenceBox extends StatefulWidget {
  final bool isDark;
  /// shows only for the administrative officer (his main dashboard), not for HR
  final bool adminOfficerOnly;
  const PresenceBox({super.key, required this.isDark, this.adminOfficerOnly = false});

  @override
  State<PresenceBox> createState() => _PresenceBoxState();
}

class _PresenceBoxState extends State<PresenceBox> {
  Map<String, dynamic>? _p;
  Map<String, String> _photos = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    Map<String, dynamic> r;
    try {
      r = await lget('/dashboard/presence');
    } catch (_) {
      return;
    }
    if (!mounted || r['success'] == false || r['hr'] != true) return;
    if (widget.adminOfficerOnly && r['adminOfficer'] != true) return;
    final p = lm(r['presence']);
    setState(() => _p = p);
    final ids = ll(p['rows']).map((x) => '${x['id']}').where((x) => x.isNotEmpty).toList();
    if (ids.isNotEmpty) {
      final ph = await JphRouter.photosOf(ids);
      if (mounted) setState(() => _photos = ph);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    if (p == null) return const SizedBox.shrink();
    final d = widget.isDark;
    final rows = ll(p['rows']);
    Color toneOf(String t) => switch (t) {
          'good' => d ? const Color(0xFF63D985) : const Color(0xFF19733A),
          'warn' => d ? const Color(0xFFF7B445) : const Color(0xFFEF9D14),
          'bad' => const Color(0xFFFF7D6E),
          'info' => d ? const Color(0xFF93C1FF) : const Color(0xFF3B78C4),
          _ => Glass.muted(d),
        };
    Widget person(Map<String, dynamic> x, double w) {
      final online = x['online'] == true;
      return Container(
        width: w,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: d ? Colors.white.withOpacity(0.06) : const Color(0x8CFFFFFF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Glass.line(d)),
        ),
        child: Row(children: [
          Stack(clipBehavior: Clip.none, children: [
            JphUi.personAvatar('${x['name']}', _photos['${x['id']}'], size: 40),
            PositionedDirectional(
              bottom: -1,
              end: -1,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: online ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
                  border: Border.all(color: d ? const Color(0xFF1B2230) : Colors.white, width: 2),
                ),
              ),
            ),
          ]),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('${x['name']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: Glass.ink(d))),
              const SizedBox(height: 3),
              Text('${x['status']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: toneOf('${x['tone']}'))),
            ]),
          ),
        ]),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: Glass.panel(d, r: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('${p['title'] ?? 'الموظفين دلوقتي'}',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Glass.ink(d))),
          ),
          Text('${p['sub'] ?? ''}', style: TextStyle(fontSize: 13, color: Glass.muted(d))),
          IconButton(onPressed: _load, icon: Icon(Icons.refresh_rounded, color: Glass.muted(d), size: 20)),
        ]),
        const SizedBox(height: 8),
        if (rows.isEmpty) Text('${p['empty'] ?? ''}', style: TextStyle(color: Glass.muted(d))),
        // two employees in a row
        LayoutBuilder(builder: (context, box) {
          final w = (box.maxWidth - 10) / 2;
          return Wrap(spacing: 10, runSpacing: 10, children: [for (final x in rows) person(x, w)]);
        }),
      ]),
    );
  }
}
