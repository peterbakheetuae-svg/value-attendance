import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/async_view.dart';
import '../core/format.dart';
import '../core/i18n.dart';
import '../core/session.dart';
import '../design/app_colors.dart';
import '../design/glass.dart';
import '../design/glass_page.dart';
import 'common.dart';

/// "متابعة الموظفين أثناء الشيفت" — who is in the office, who is out and for how long, whose tracking stopped.
class TrackingLivePage extends StatefulWidget {
  const TrackingLivePage({super.key});
  @override
  State<TrackingLivePage> createState() => _TrackingLivePageState();
}

class _TrackingLivePageState extends State<TrackingLivePage> {
  Key _k = UniqueKey();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return GlassPage(
      title: t('tracking_live'),
      onRefresh: () async => setState(() => _k = UniqueKey()),
      body: AsyncView<Map<String, dynamic>>(
        key: _k,
        load: () => s.api.get('/tracking/live'),
        builder: (ctx, d, reload) {
          final rows = d.list('live');
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (d['trackingEnabled'] != true)
              Padding(padding: const EdgeInsets.only(bottom: 10), child: StatusChip(t('tracking_off_hint'), color: AppColors.warning)),
            MiniCardGrid(children: [
              GlassMiniCard(title: t('in_office'), value: '${rows.where((x) => x['inside'] == true && x['checkOut'] == null).length}', icon: Icons.apartment_rounded, iconColor: AppColors.success),
              GlassMiniCard(title: t('out_of_office'), value: '${rows.where((x) => x['inside'] == false && x['checkOut'] == null).length}', icon: Icons.directions_walk_rounded, iconColor: AppColors.warning),
              GlassMiniCard(title: t('tracking_stopped'), value: '${rows.where((x) => x['stopped'] == true).length}', icon: Icons.location_disabled_rounded, iconColor: AppColors.error),
            ]),
            const SizedBox(height: 12),
            if (rows.isEmpty) EmptyState(t('nobody_checked_in')),
            for (final r in rows) Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GlassCard(radius: 20, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  EmployeeAvatar(employeeId: r.s('employeeId'), hasPhoto: r['hasPhoto'] == true, size: 40),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(r.s('fullName'), style: const TextStyle(fontWeight: FontWeight.w800)),
                    Text('${r.s('code')}${r['teamName'] != null ? ' · ${r['teamName']}' : ''}', style: const TextStyle(fontSize: 12)),
                  ])),
                  _status(r),
                ]),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  StatusChip('${t('check_in')} ${Fmt.time(r['checkIn'])}', color: AppColors.primary),
                  if (r['checkOut'] != null) StatusChip('${t('check_out')} ${Fmt.time(r['checkOut'])}', color: AppColors.secondary),
                  if (r['lastPingAt'] != null) StatusChip('${t('last_location')} ${Fmt.time(r['lastPingAt'])}', color: AppColors.primaryLight),
                  if ((r['awayMinutesToday'] ?? 0) > 0) StatusChip('${t('away_today')} ${Fmt.minutes(r['awayMinutesToday'])}', color: AppColors.warning),
                  if (r['inside'] == false && r['distanceM'] != null) StatusChip(t('meters_away', {'m': r['distanceM']}), color: AppColors.warning),
                ]),
                if (r['position'] != null) Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(
                    icon: const Icon(Icons.map_rounded),
                    label: Text(t('open_map')),
                    onPressed: () => launchUrl(Uri.parse('https://www.google.com/maps?q=${r.obj('position')!['lat']},${r.obj('position')!['lng']}'),
                        mode: LaunchMode.externalApplication),
                  ),
                ),
              ])),
            ),
          ]);
        },
      ),
    );
  }

  Widget _status(Map<String, dynamic> r) {
    if (r['checkOut'] != null) return StatusChip(t('left_for_day'), color: AppColors.secondary);
    if (r['stopped'] == true) return StatusChip(t('tracking_stopped'), color: AppColors.error);
    if (r['inside'] == true) return StatusChip(t('in_office'), color: AppColors.success);
    if (r['inside'] == false) return StatusChip(t('out_of_office'), color: AppColors.warning);
    return StatusChip(t('location_unknown'), color: Colors.grey);
  }
}
