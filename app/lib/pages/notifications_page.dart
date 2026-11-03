import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/async_view.dart';
import '../core/format.dart';
import '../core/i18n.dart';
import '../core/session.dart';
import '../design/app_colors.dart';
import '../design/glass.dart';
import '../design/glass_page.dart';
import 'requests_page.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});
  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  Key _k = UniqueKey();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return GlassPage(
      title: t('notifications'),
      actions: [TextButton(onPressed: () async {
        try { await s.api.post('/notifications/read-all'); setState(() => _k = UniqueKey()); } catch (e) { if (context.mounted) showSnack(context, errorText(e), error: true); }
      }, child: Text(t('mark_all_read')))],
      body: AsyncView<Map<String, dynamic>>(
        key: _k,
        load: () => s.api.get('/notifications'),
        builder: (ctx, d, reload) {
          final list = d.list('notifications');
          if (list.isEmpty) return EmptyState(t('no_notifications'), icon: Icons.notifications_none_rounded);
          return Column(children: [
            for (final n in list) Padding(padding: const EdgeInsets.only(bottom: 8), child: GlassCard(
              radius: 18,
              backgroundColor: n['read_at'] == null ? AppColors.primary.withValues(alpha: 0.08) : null,
              onTap: () async {
                if (n['read_at'] == null) { try { await s.api.post('/notifications/${n['id']}/read'); } catch (_) {} }
                if (!context.mounted) return;
                if (n['entity'] == 'request' && n['entity_id'] != null) {
                  await Navigator.push(context, MaterialPageRoute(builder: (_) => RequestDetailPage(id: n.s('entity_id'))));
                }
                await reload();
              },
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(_icon(n.s('type')), color: n['read_at'] == null ? AppColors.primary : Colors.grey),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(n.s('title'), style: TextStyle(fontWeight: n['read_at'] == null ? FontWeight.w800 : FontWeight.w600)),
                  if (n.s('body').isNotEmpty) Text(n.s('body'), style: const TextStyle(fontSize: 13)),
                  Text(Fmt.dateTime(n['created_at']), style: const TextStyle(fontSize: 11)),
                ])),
              ]),
            )),
          ]);
        },
      ),
    );
  }

  IconData _icon(String type) => switch (type) {
        'request_approved' => Icons.check_circle_rounded,
        'request_rejected' => Icons.cancel_rounded,
        'request_awaiting' => Icons.how_to_reg_rounded,
        'attendance_corrected' => Icons.edit_calendar_rounded,
        'evaluation_published' => Icons.star_rounded,
        'finance_awaiting' => Icons.account_balance_wallet_rounded,
        _ => Icons.notifications_rounded,
      };
}
