import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import '../core/api.dart';
import '../core/async_view.dart';
import '../core/format.dart';
import '../core/i18n.dart';
import '../core/session.dart';
import '../design/app_colors.dart';
import '../design/glass.dart';
import '../design/glass_page.dart';
import '../design/primary_button.dart';
import 'common.dart';

class AttendancePage extends StatelessWidget {
  const AttendancePage({super.key});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(title: t('attendance')),
        AttendanceMonthView(employeeId: s.id),
        const SizedBox(height: 100),
      ]),
    );
  }
}

/// Check-in / check-out card. GPS is requested only when the company requires it.
class TodayAttendanceCard extends StatefulWidget {
  final bool compact;
  final VoidCallback? onChanged;
  const TodayAttendanceCard({super.key, this.compact = false, this.onChanged});
  @override
  State<TodayAttendanceCard> createState() => _TodayAttendanceCardState();
}

class _TodayAttendanceCardState extends State<TodayAttendanceCard> {
  Map<String, dynamic>? _today;
  Object? _error;
  bool _busy = false;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final r = await context.read<Session>().api.get('/attendance/today');
      if (mounted) setState(() { _today = r; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<Map<String, dynamic>> _location() async {
    if (!await Geolocator.isLocationServiceEnabled()) throw ApiException(0, 'gps', t('gps_off'));
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied || p == LocationPermission.deniedForever) throw ApiException(0, 'gps', t('gps_permission_denied'));
    final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 25)));
    return {'lat': pos.latitude, 'lng': pos.longitude, 'accuracyM': pos.accuracy};
  }

  Future<void> _act(bool checkIn) async {
    final s = context.read<Session>();
    setState(() => _busy = true);
    try {
      final body = (_today?['gpsRequired'] == true) ? await _location() : <String, dynamic>{};
      await s.api.post(checkIn ? '/attendance/check-in' : '/attendance/check-out', body);
      if (!mounted) return;
      showSnack(context, checkIn ? t('checked_in_ok') : t('checked_out_ok'));
      await _load();
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      var msg = e is ApiException && e.code == 'gps' ? e.message : errorText(e);
      if (e is ApiException && e.details?['distanceOutsideM'] != null) msg = t('outside_office_by', {'m': e.details!['distanceOutsideM']});
      showSnack(context, msg, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return ErrorState(errorText(_error!), onRetry: _load, retryLabel: t('retry'));
    final d = _today;
    if (d == null) return const GlassCard(child: SizedBox(height: 120, child: Center(child: CircularProgressIndicator())));
    final a = d.obj('attendance');
    final sch = d.obj('schedule')!;
    final checkedIn = a != null, checkedOut = a?['checkOut'] != null;
    final isDark = isDarkOf(context);
    return GlassCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.fingerprint_rounded, size: 34, color: isDark ? AppColors.primaryLight : AppColors.primary),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('today'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Text(t('schedule_from_to', {'from': '${sch['start']}'.substring(0, 5), 'to': '${sch['end']}'.substring(0, 5)}),
                style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.grey.shade700)),
          ])),
          if (d['holiday'] != null) StatusChip('${t('status_holiday')}: ${d['holiday']}', color: AppColors.primaryLight)
          else if (d['isWeekend'] == true) StatusChip(t('status_weekend'), color: AppColors.primaryLight),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: GlassMiniCard(title: t('check_in'), value: checkedIn ? Fmt.time(a['checkIn']) : '—', icon: Icons.login_rounded, iconColor: AppColors.success, height: 80)),
          const SizedBox(width: 12),
          Expanded(child: GlassMiniCard(title: t('check_out'), value: checkedOut ? Fmt.time(a?['checkOut']) : '—', icon: Icons.logout_rounded, iconColor: AppColors.error, height: 80)),
          if (!widget.compact) ...[
            const SizedBox(width: 12),
            Expanded(child: GlassMiniCard(title: t('late_minutes'), value: checkedIn ? '${a['lateMinutes']}' : '—', icon: Icons.schedule_rounded, iconColor: AppColors.warning, height: 80)),
          ],
        ]),
        const SizedBox(height: 14),
        if (!checkedIn)
          PrimaryButton(label: t('check_in'), icon: Icons.login_rounded, loading: _busy, onTap: () => _act(true))
        else if (!checkedOut)
          PrimaryButton(label: t('check_out'), icon: Icons.logout_rounded, color: AppColors.secondaryDark, loading: _busy, onTap: () => _act(false))
        else
          Center(child: Text(t('day_done'), style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.success))),
        if (d['gpsRequired'] == true) Padding(padding: const EdgeInsets.only(top: 8),
            child: Text(t('gps_required_note'), textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: isDark ? Colors.white60 : Colors.grey.shade600))),
      ]),
    );
  }
}

/// Monthly summary + day list for one employee. HR sees a correction action per day.
class AttendanceMonthView extends StatefulWidget {
  final String employeeId;
  const AttendanceMonthView({super.key, required this.employeeId});
  @override
  State<AttendanceMonthView> createState() => _AttendanceMonthViewState();
}

class _AttendanceMonthViewState extends State<AttendanceMonthView> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  Key _k = UniqueKey();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    final canCorrect = s.has('attendance.correct') && widget.employeeId != s.id;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle(t('monthly_attendance'), trailing: MonthPicker(month: _month, onChanged: (m) => setState(() { _month = m; _k = UniqueKey(); }))),
      AsyncView<Map<String, dynamic>>(
        key: _k,
        load: () => s.api.get('/attendance', {'month': Fmt.month(_month), 'employeeId': widget.employeeId}),
        builder: (ctx, d, reload) {
          final sm = d.obj('summary')!;
          final days = d.list('days').where((x) => x['status'] != 'future').toList().reversed.toList();
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (sm['complete'] == false) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(t('period_incomplete'), style: TextStyle(fontSize: 12, color: Colors.orange[700]))),
            MiniCardGrid(children: [
              GlassMiniCard(title: t('working_days'), value: '${sm['workingDays']}', icon: Icons.calendar_month_rounded),
              GlassMiniCard(title: t('days_attended'), value: '${sm['attendedDays']}', icon: Icons.event_available_rounded, iconColor: AppColors.success),
              GlassMiniCard(title: t('absence_days'), value: '${sm['absenceDays']} (${t('unapproved')}: ${sm['unapprovedAbsenceDays']})', icon: Icons.event_busy_rounded, iconColor: AppColors.error),
              GlassMiniCard(title: t('late_arrivals'), value: '${sm['lateArrivals']}', icon: Icons.schedule_rounded, iconColor: AppColors.warning),
              GlassMiniCard(title: t('early_departures'), value: '${sm['earlyDepartures']}', icon: Icons.directions_walk_rounded, iconColor: AppColors.warning),
              GlassMiniCard(title: t('working_hours'), value: Fmt.minutes(sm['workedMinutes']), icon: Icons.timer_rounded),
              GlassMiniCard(title: t('overtime_hours'), value: Fmt.minutes(sm['overtimeMinutes']), icon: Icons.more_time_rounded, iconColor: AppColors.secondary),
              GlassMiniCard(title: t('missing_checkouts'), value: '${sm['missingCheckouts']}', icon: Icons.report_problem_rounded, iconColor: AppColors.error),
              GlassMiniCard(title: t('attendance_percent'), value: Fmt.percent(sm['attendancePercent']), icon: Icons.percent_rounded),
            ]),
            const SizedBox(height: 12),
            GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: days.isEmpty
                  ? EmptyState(t('no_days_yet'))
                  : Column(children: [
                      for (var i = 0; i < days.length; i++) ...[
                        if (i > 0) const GlassDivider(),
                        _DayRow(day: days[i], canCorrect: canCorrect, onCorrect: () async {
                          final ok = await _correct(context, days[i]);
                          if (ok == true) await reload();
                        }),
                      ],
                    ]),
            ),
          ]);
        },
      ),
    ]);
  }

  Future<bool?> _correct(BuildContext context, Map<String, dynamic> day) {
    final a = day.obj('attendance');
    TimeOfDay? inT = a == null ? null : TimeOfDay.fromDateTime(Fmt.parse(a['checkIn'])!);
    TimeOfDay? outT = a?['checkOut'] == null ? null : TimeOfDay.fromDateTime(Fmt.parse(a!['checkOut'])!);
    final reason = TextEditingController();
    return showGlassSheet<bool>(context, title: '${t('correct_attendance')} — ${Fmt.date(day['date'])}', child: StatefulBuilder(
      builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t('correction_keeps_original'), style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.login), label: Text(inT == null ? t('check_in') : hhmm(inT!)),
              onPressed: () async { final v = await pickTime(ctx, initial: inT); if (v != null) set(() => inT = v); })),
          const SizedBox(width: 10),
          Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.logout), label: Text(outT == null ? t('check_out') : hhmm(outT!)),
              onPressed: () async { final v = await pickTime(ctx, initial: outT ?? const TimeOfDay(hour: 18, minute: 0)); if (v != null) set(() => outT = v); })),
        ]),
        const SizedBox(height: 12),
        TextField(controller: reason, maxLines: 2, decoration: glassInput(ctx, t('reason_required'))),
        const SizedBox(height: 16),
        PrimaryButton(label: t('save'), onTap: () async {
          if (inT == null || reason.text.trim().length < 3) { showSnack(ctx, t('fill_required'), error: true); return; }
          try {
            await context.read<Session>().api.post('/attendance/corrections', {
              'employeeId': widget.employeeId, 'workDate': day['date'], 'checkIn': hhmm(inT!),
              if (outT != null) 'checkOut': hhmm(outT!), 'reason': reason.text.trim(),
            });
            if (ctx.mounted) Navigator.pop(ctx, true);
          } catch (e) {
            if (ctx.mounted) showSnack(ctx, errorText(e), error: true);
          }
        }),
      ]),
    ));
  }
}

class _DayRow extends StatelessWidget {
  final Map<String, dynamic> day;
  final bool canCorrect;
  final VoidCallback onCorrect;
  const _DayRow({required this.day, required this.canCorrect, required this.onCorrect});

  @override
  Widget build(BuildContext context) {
    final a = day.obj('attendance');
    final status = day.s('status');
    final flags = <Widget>[
      if (a?['isLate'] == true) StatusChip('${t('late')} ${a!['lateMinutes']}${t('min_short')}', color: AppColors.warning),
      if (a?['isEarly'] == true) StatusChip('${t('early')} ${a!['earlyMinutes']}${t('min_short')}', color: AppColors.warning),
      if (a?['missingCheckout'] == true) StatusChip(t('missing_checkout'), color: AppColors.error),
      if (a?['corrected'] == true) StatusChip(t('corrected'), color: AppColors.primaryLight),
      if ((day['hourlyPermissionMinutes'] ?? 0) > 0) StatusChip('${t('permission')} ${Fmt.minutes(day['hourlyPermissionMinutes'])}', color: AppColors.secondary),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 92, child: Text(Fmt.date(day['date']), style: const TextStyle(fontWeight: FontWeight.w700))),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 6, runSpacing: 6, children: [
              StatusPill(status),
              if (day['holidayName'] != null) Text('${day['holidayName']}', style: const TextStyle(fontSize: 12)),
              ...flags,
            ]),
            if (a != null) Padding(padding: const EdgeInsets.only(top: 6),
                child: Text('${Fmt.time(a['checkIn'])} → ${Fmt.time(a['checkOut'])}   ·   ${Fmt.minutes(a['workedMinutes'])}', style: const TextStyle(fontSize: 13))),
          ]),
        ),
        if (canCorrect && status != 'before_joining')
          IconButton(tooltip: t('correct_attendance'), icon: const Icon(Icons.edit_calendar_rounded), onPressed: onCorrect),
      ]),
    );
  }
}
