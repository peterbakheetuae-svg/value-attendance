import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../core/api.dart';
import '../core/async_view.dart';
import '../core/format.dart';
import '../core/i18n.dart';
import '../core/session.dart';
import '../core/shift_tracker.dart';
import '../design/app_colors.dart';
import '../design/glass.dart';
import '../design/glass_page.dart';
import 'common.dart';
import 'notifications_page.dart';
import 'employees_page.dart';
import 'requests_page.dart';

/// The original JPH employee home, rebuilt 1:1 on the new API:
/// header (bell · date/name · avatar) → three top tabs (attendance / break / leave)
/// → long-press animated fingerprint + glass right card → today's time log → this month.
enum DashMode { check, breakTime, leave }

class FingerprintHome extends StatefulWidget {
  final int unreadNotifications;
  final VoidCallback? onChanged;
  const FingerprintHome({super.key, this.unreadNotifications = 0, this.onChanged});
  @override
  State<FingerprintHome> createState() => _FingerprintHomeState();
}

class _FingerprintHomeState extends State<FingerprintHome> {
  DashMode mode = DashMode.check;
  Map<String, dynamic>? _today;
  Map<String, dynamic>? _month;
  Object? _error;
  Timer? _ticker;
  final ValueNotifier<int> _tick = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    _load();
    // live work / break counters, like the original
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) => _tick.value++);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _tick.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = context.read<Session>();
    try {
      final now = DateTime.now();
      final r = await Future.wait([
        s.api.get('/attendance/today'),
        s.api.get('/attendance', {'month': Fmt.month(DateTime(now.year, now.month)), 'employeeId': s.id}),
      ]);
      if (mounted) setState(() { _today = r[0]; _month = r[1]; _error = null; });
      _syncTracker();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// In-shift follow-up runs exactly between check-in and check-out.
  void _syncTracker() {
    final s = context.read<Session>();
    if (checkedIn && !dayFinished) {
      ShiftTracker.instance.start(s.api, notifTitle: t('tracking_notif_title'), notifText: t('tracking_notif_text'));
    } else {
      ShiftTracker.instance.stop();
    }
  }

  // ------------------------------------------------------------------ state helpers
  Map<String, dynamic>? get _att => _today?.obj('attendance');
  Map<String, dynamic>? get _break => _today?.obj('break');
  bool get checkedIn => _att != null;
  bool get dayFinished => _att?['checkOut'] != null;
  bool get onBreak => _break?['onBreak'] == true;
  bool get breakFinished => _break != null && _break!['onBreak'] != true;
  int get _allowedBreak => (_break?['allowedMinutes'] ?? _today?['breakAllowedMinutes'] ?? 60) as int;

  int get _breakMinutesLive {
    final b = _break;
    if (b == null) return 0;
    final start = Fmt.parse(b['start']);
    final end = Fmt.parse(b['end']) ?? DateTime.now();
    return start == null ? 0 : max(0, end.difference(start).inMinutes);
  }

  bool get breakExceeded => onBreak && _breakMinutesLive > _allowedBreak;

  int get _workMinutesLive {
    final a = _att;
    if (a == null) return 0;
    if (a['checkOut'] != null) return (a['workedMinutes'] ?? 0) as int;
    final start = Fmt.parse(a['checkIn']);
    return start == null ? 0 : max(0, DateTime.now().difference(start).inMinutes);
  }

  String _hm(int minutes) => '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

  // ------------------------------------------------------------------ actions
  Future<Map<String, dynamic>> _location() async {
    if (!await Geolocator.isLocationServiceEnabled()) throw ApiException(0, 'gps', t('gps_off'));
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied || p == LocationPermission.deniedForever) throw ApiException(0, 'gps', t('gps_permission_denied'));
    final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 25)));
    return {'lat': pos.latitude, 'lng': pos.longitude, 'accuracyM': pos.accuracy};
  }

  Future<void> _onFingerSuccess() async {
    final s = context.read<Session>();
    String path, okMsg;
    switch (mode) {
      case DashMode.check:
        if (dayFinished) return;
        if (onBreak) { showSnack(context, t('fp_end_break_first'), error: true); setState(() => mode = DashMode.breakTime); return; }
        path = checkedIn ? '/attendance/check-out' : '/attendance/check-in';
        okMsg = checkedIn ? t('checked_out_ok') : t('checked_in_ok');
      case DashMode.breakTime:
        if (!checkedIn || dayFinished || breakFinished) return;
        path = onBreak ? '/attendance/break-end' : '/attendance/break-start';
        okMsg = onBreak ? t('break_ended_ok') : t('break_started_ok');
      case DashMode.leave:
        final ok = await showNewRequestSheet(context);
        if (ok == true) { await _load(); widget.onChanged?.call(); }
        return;
    }
    try {
      final needsGps = _today?['gpsRequired'] == true && mode == DashMode.check;
      final body = needsGps ? await _location() : <String, dynamic>{};
      if (path == '/attendance/check-in' && _today?['selfieRequired'] == true) {
        final shot = await ImagePicker().pickImage(source: ImageSource.camera, preferredCameraDevice: CameraDevice.front,
            maxWidth: 480, maxHeight: 640, imageQuality: 60);
        if (shot == null) { if (mounted) showSnack(context, t('selfie_needed'), error: true); return; }
        body['selfie'] = base64Encode(await shot.readAsBytes());
        body['selfieMime'] = 'image/jpeg';
      }
      await s.api.post(path, body);
      if (!mounted) return;
      showSnack(context, okMsg);
      await _load();
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      var msg = e is ApiException && e.code == 'gps' ? e.message : errorText(e);
      if (e is ApiException && e.details?['distanceOutsideM'] != null) msg = t('outside_office_by', {'m': e.details!['distanceOutsideM']});
      showSnack(context, msg, error: true);
    }
  }

  FingerUiConfig _fingerConfig(BuildContext context) {
    final isDark = isDarkOf(context);
    final primary = isDark ? AppColors.primaryLight : AppColors.primary;
    final secondary = isDark ? AppColors.secondaryLight : AppColors.secondary;
    final accent = isDark ? AppColors.accentLight : AppColors.accent;
    switch (mode) {
      case DashMode.check:
        if (dayFinished) return FingerUiConfig(title: t('fp_work_day_ended'), subtitle: t('fp_sub_day_ended'), disabled: true, color: primary);
        if (checkedIn && onBreak) {
          if (breakExceeded) return FingerUiConfig(title: t('fp_break_exceeded'), subtitle: t('fp_sub_end_break_first'), color: Colors.orange);
          return FingerUiConfig(title: t('fp_end_break_first'), subtitle: t('fp_sub_end_break_first'), color: secondary);
        }
        if (checkedIn) return FingerUiConfig(title: t('fp_check_out'), subtitle: t('fp_sub_check_out'), color: AppColors.error);
        return FingerUiConfig(title: t('fp_check_in'), subtitle: t('fp_sub_check_in'), color: primary);
      case DashMode.breakTime:
        if (dayFinished) return FingerUiConfig(title: t('fp_work_day_ended'), subtitle: t('fp_sub_day_ended'), disabled: true, color: primary);
        if (!checkedIn) return FingerUiConfig(title: t('fp_check_in_first'), subtitle: t('fp_sub_check_in_first'), disabled: true, color: Colors.grey);
        if (breakFinished) return FingerUiConfig(title: t('fp_break_ended'), subtitle: t('fp_sub_break_ended'), disabled: true, color: secondary);
        if (onBreak) return FingerUiConfig(title: t('fp_end_break'), subtitle: t('fp_sub_end_break'), color: breakExceeded ? Colors.orange : secondary);
        return FingerUiConfig(title: t('fp_start_break'), subtitle: t('fp_sub_start_break'), color: accent);
      case DashMode.leave:
        return FingerUiConfig(title: t('fp_request_leave'), subtitle: t('fp_sub_leave'), color: primary);
    }
  }

  StatRightCardModel _rightCard() {
    final sm = _month?.obj('summary') ?? const {};
    switch (mode) {
      case DashMode.breakTime:
        return StatRightCardModel(
          line1Title: t('start_time'), line1Value: Fmt.parse(_break?['start']) == null ? '--:--' : Fmt.time(_break!['start']), line1Icon: Icons.play_circle_outline_rounded,
          line2Title: t('end_time'), line2Value: Fmt.parse(_break?['end']) == null ? '--:--' : Fmt.time(_break!['end']), line2Icon: Icons.stop_circle_outlined,
          line3Title: t('break_label'), line3Value: _break == null ? '--:--' : _hm(_breakMinutesLive), line3Icon: Icons.timer_rounded,
          line3Color: breakExceeded ? Colors.orange : null,
        );
      case DashMode.leave:
        return StatRightCardModel(
          line1Title: t('leave_days_label'), line1Value: '${sm['approvedAbsenceDays'] ?? 0}', line1Icon: Icons.event_available_rounded,
          line2Title: t('without_pay'), line2Value: '${sm['unpaidAbsenceDays'] ?? 0}', line2Icon: Icons.money_off_rounded,
          line3Title: t('sick_leave_label'), line3Value: '${_sickDays()}', line3Icon: Icons.medical_services_rounded,
        );
      case DashMode.check:
        return StatRightCardModel(
          line1Title: t('check_in_time'), line1Value: checkedIn ? Fmt.time(_att!['checkIn']) : '--:--', line1Icon: Icons.login_rounded,
          line2Title: t('check_out_time'), line2Value: dayFinished ? Fmt.time(_att!['checkOut']) : '--:--', line2Icon: Icons.logout_rounded,
          line3Title: t('working_time'), line3Value: checkedIn ? _hm(_workMinutesLive) : '--:--', line3Icon: Icons.timelapse_rounded,
        );
    }
  }

  int _sickDays() => (_month?.list('days') ?? const []).where((d) => d['absenceType'] == 'sick').length;

  // ------------------------------------------------------------------ UI
  String _todayLabel() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t('today')} ${t('day_${now.weekday}')} ${two(now.day)} / ${two(now.month)} / ${now.year}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = isDarkOf(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (breakExceeded)
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            const Icon(Icons.notifications_active, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(child: Text(t('break_exceeded_banner'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500))),
          ]),
        ),
      _header(context, isDark),
      const SizedBox(height: 18),
      TopTabs(mode: mode, onTap: (m) => setState(() => mode = m)),
      const SizedBox(height: 18),
      if (_error != null)
        ErrorState(errorText(_error!), onRetry: _load, retryLabel: t('retry'))
      else if (_today == null)
        const SizedBox(height: 210, child: Center(child: CircularProgressIndicator()))
      else ...[
        ValueListenableBuilder<int>(
          valueListenable: _tick,
          builder: (_, __, ___) => Row(children: [
            Expanded(
              child: AnimatedFingerprintAction(
                key: ValueKey('${_att?['checkIn']}-${_att?['checkOut']}-${_break?['start']}-${_break?['end']}-$mode'),
                config: _fingerConfig(context),
                onSuccess: _onFingerSuccess,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: StatRightCard(model: _rightCard())),
          ]),
        ),
        if (_today?['holiday'] != null || _today?['isWeekend'] == true) Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Center(child: StatusChip(_today?['holiday'] != null ? '${t('status_holiday')}: ${_today!['holiday']}' : t('fp_not_working_day'),
              color: AppColors.primaryLight)),
        ),
        const SizedBox(height: 18),
        Text(t('today_time_log'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        ValueListenableBuilder<int>(
          valueListenable: _tick,
          builder: (_, __, ___) => _statRow(context, [
            (t('work_time'), checkedIn ? _hm(_workMinutesLive) : '--:--'),
            (t('break_label'), _break == null ? '--:--' : _hm(_breakMinutesLive)),
            (t('overtime_label'), Fmt.minutes(_att?['overtimeMinutes'] ?? 0)),
          ]),
        ),
        const SizedBox(height: 16),
        Text(t('this_month'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        _monthStats(context),
      ],
    ]);
  }

  Widget _monthStats(BuildContext context) {
    final sm = _month?.obj('summary') ?? const {};
    return Column(children: [
      _statRow(context, [
        (t('work_days_label'), '${sm['attendedDays'] ?? '--'} / ${sm['workingDays'] ?? '--'}'),
        (t('leave_days_label'), '${sm['approvedAbsenceDays'] ?? 0}'),
        (t('absent_days_label'), '${sm['unapprovedAbsenceDays'] ?? '--'}'),
      ]),
      const SizedBox(height: 10),
      _statRow(context, [
        (t('sick_leave_label'), '${_sickDays()}'),
        (t('overtime_hours_label'), Fmt.minutes(sm['overtimeMinutes'] ?? 0)),
      ]),
    ]);
  }

  /// Original `_buildStatMiniCard`: plain translucent tile, value on top, title under it.
  Widget _statRow(BuildContext context, List<(String, String)> items) {
    final isDark = isDarkOf(context);
    final cells = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) cells.add(const SizedBox(width: 10));
      cells.add(Expanded(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(children: [
            Text(items[i].$2, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
            const SizedBox(height: 4),
            Text(items[i].$1, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.grey.shade700)),
          ]),
        ),
      ));
    }
    return Row(children: cells);
  }

  Widget _header(BuildContext context, bool isDark) {
    final s = context.watch<Session>();
    final unread = widget.unreadNotifications;
    final bellColor = unread > 0 ? Colors.red : (isDark ? Colors.white.withValues(alpha: 0.8) : AppColors.primary.withValues(alpha: 0.8));
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      GestureDetector(
        onTap: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationsPage()));
          widget.onChanged?.call();
        },
        child: Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isDark ? Colors.white.withValues(alpha: 0.15) : AppColors.primary.withValues(alpha: 0.1),
            border: Border.all(color: isDark ? Colors.white.withValues(alpha: 0.2) : AppColors.primary.withValues(alpha: 0.2)),
          ),
          child: Stack(alignment: Alignment.center, children: [
            Icon(Icons.notifications, size: 30, color: bellColor),
            if (unread > 0) Positioned(right: 8, top: 8, child: Container(width: 10, height: 10,
                decoration: BoxDecoration(color: Colors.red, shape: BoxShape.circle, border: Border.all(color: isDark ? Colors.black26 : Colors.white, width: 1.5)))),
          ]),
        ),
      ),
      Expanded(
        child: Column(children: [
          Text(_todayLabel(), textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.grey.shade700)),
          Text(s.name, textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
          Text(I18n.lang == 'ar' ? (s.me?['role_name_ar'] ?? '') : (s.me?['role_name_en'] ?? ''),
              style: TextStyle(fontSize: 10, color: isDark ? Colors.white60 : Colors.grey.shade600)),
        ]),
      ),
      GestureDetector(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => EmployeeProfilePage(id: s.id))),
        child: Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: isDark ? Colors.white.withValues(alpha: 0.2) : AppColors.primary.withValues(alpha: 0.2), width: 1.5),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 6, spreadRadius: 1, offset: const Offset(0, 2))],
          ),
          child: s.me?['has_photo'] == true
              ? EmployeeAvatar(employeeId: s.id, hasPhoto: true, size: 44)
              : Container(
                  decoration: BoxDecoration(shape: BoxShape.circle, color: isDark ? Colors.white.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.25)),
                  child: Icon(Icons.person, size: 24, color: isDark ? Colors.white70 : Colors.grey.shade700),
                ),
        ),
      ),
    ]);
  }
}

// ==================================================================== TopTabs (original top_tabs_team.dart)
class TopTabs extends StatelessWidget {
  final DashMode mode;
  final void Function(DashMode) onTap;
  const TopTabs({super.key, required this.mode, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = isDarkOf(context);
    final primary = isDark ? AppColors.primaryLight : AppColors.primary;
    final textColor = isDark ? Colors.white : Colors.black;
    Widget tab(String key, IconData icon, DashMode m) {
      final selected = mode == m;
      return Expanded(
        child: GestureDetector(
          onTap: () => onTap(m),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(color: selected ? primary : Colors.transparent, borderRadius: BorderRadius.circular(24)),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 20, color: selected ? Colors.white : textColor),
              const SizedBox(width: 6),
              Flexible(child: Text(t(key), overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: selected ? Colors.white : textColor, fontWeight: FontWeight.w600))),
            ]),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(children: [
        tab('tab_check', Icons.checklist, DashMode.check),
        tab('tab_break', Icons.access_time, DashMode.breakTime),
        tab('tab_leave', Icons.logout, DashMode.leave),
      ]),
    );
  }
}

// ==================================================================== Fingerprint (original fingerprint_config_team.dart)
class FingerUiConfig {
  final String title;
  final String subtitle;
  final Color color;
  final bool disabled;
  const FingerUiConfig({required this.title, required this.color, required this.subtitle, this.disabled = false});

  @override
  bool operator ==(Object other) =>
      other is FingerUiConfig && other.title == title && other.color == color && other.disabled == disabled && other.subtitle == subtitle;
  @override
  int get hashCode => Object.hash(title, color, disabled, subtitle);
}

/// Press and hold: a ring fills around the fingerprint in 0.5 s, then the action fires.
class AnimatedFingerprintAction extends StatefulWidget {
  final FingerUiConfig config;
  final Future<void> Function() onSuccess;
  const AnimatedFingerprintAction({super.key, required this.config, required this.onSuccess});
  @override
  State<AnimatedFingerprintAction> createState() => _AnimatedFingerprintActionState();
}

class _AnimatedFingerprintActionState extends State<AnimatedFingerprintAction> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _isPressed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: const Duration(milliseconds: 500), vsync: this);
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) _complete();
    });
  }

  @override
  void didUpdateWidget(covariant AnimatedFingerprintAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config != widget.config) _reset();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _reset() {
    _controller.reset();
    if (mounted) setState(() => _isPressed = false);
  }

  Future<void> _complete() async {
    if (!mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.onSuccess();
    } finally {
      if (mounted) { setState(() => _busy = false); _reset(); }
    }
  }

  void _down(TapDownDetails _) {
    if (widget.config.disabled || _isPressed || _busy) return;
    setState(() => _isPressed = true);
    _controller.forward();
  }

  void _up(TapUpDetails _) {
    if (_controller.status != AnimationStatus.completed) _reset();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.config;
    final disabled = c.disabled;
    final isDark = isDarkOf(context);
    final color = disabled ? Colors.grey : c.color;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      GestureDetector(
        onTapDown: _down,
        onTapUp: _up,
        onTapCancel: _reset,
        child: Stack(alignment: Alignment.center, children: [
          Container(width: 140, height: 140, decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.2))),
          AnimatedBuilder(
            animation: _controller,
            builder: (_, __) => CustomPaint(
              size: const Size(140, 140),
              painter: _FingerprintCirclePainter(progress: _controller.value, color: color, isPressed: _isPressed && !disabled),
            ),
          ),
          Container(
            width: 100, height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDark ? Colors.black.withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.7),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, spreadRadius: 2)],
            ),
            child: _busy
                ? Padding(padding: const EdgeInsets.all(30), child: CircularProgressIndicator(strokeWidth: 3, color: color))
                : Icon(Icons.fingerprint, size: 60, color: color),
          ),
          if (_isPressed && !disabled && !_busy)
            AnimatedBuilder(
              animation: _controller,
              builder: (_, __) => IgnorePointer(
                child: Container(
                  width: 80, height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(
                      colors: [color.withValues(alpha: 0.1), color.withValues(alpha: 0.3), color.withValues(alpha: 0.6), color.withValues(alpha: 0.1)],
                      stops: const [0.0, 0.25, 0.5, 0.75],
                      transform: GradientRotation(2 * pi * _controller.value),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 16),
      Text(c.title, textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: disabled ? (isDark ? Colors.white38 : Colors.black38) : c.color)),
      const SizedBox(height: 4),
      Text(disabled ? t('fp_unavailable') : (_isPressed ? c.subtitle : t('fp_hold')), textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: disabled ? (isDark ? Colors.white38 : Colors.black38) : Colors.grey.shade600)),
    ]);
  }
}

class _FingerprintCirclePainter extends CustomPainter {
  final double progress;
  final Color color;
  final bool isPressed;
  _FingerprintCirclePainter({required this.progress, required this.color, required this.isPressed});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    canvas.drawCircle(center, radius - 1.5, Paint()
      ..color = color.withValues(alpha: 0.1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3);
    if (isPressed && progress > 0) {
      final sweep = 2 * pi * progress;
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius - 2), -pi / 2, sweep, false, Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round);
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius - 3), -pi / 2, sweep + 0.1, false, Paint()
        ..color = color.withValues(alpha: 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    }
    if (!isPressed) {
      final dot = Paint()..color = color.withValues(alpha: 0.5);
      final inner = radius * 0.7;
      for (var i = 0; i < 12; i++) {
        final a = 2 * pi * i / 12;
        canvas.drawCircle(Offset(center.dx + inner * cos(a), center.dy + inner * sin(a)), 2, dot);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FingerprintCirclePainter old) =>
      progress != old.progress || isPressed != old.isPressed || color != old.color;
}

// ==================================================================== Right glass card (original stat_cards.dart)
class StatRightCardModel {
  final String line1Title, line1Value, line2Title, line2Value, line3Title, line3Value;
  final IconData line1Icon, line2Icon, line3Icon;
  final Color? line3Color;
  const StatRightCardModel({
    required this.line1Title, required this.line1Value, required this.line1Icon,
    required this.line2Title, required this.line2Value, required this.line2Icon,
    required this.line3Title, required this.line3Value, required this.line3Icon, this.line3Color,
  });
}

class StatRightCard extends StatelessWidget {
  final StatRightCardModel model;
  const StatRightCard({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    final isDark = isDarkOf(context);
    final border = isDark ? AppColors.outlineDark.withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.30);
    final shadow = isDark ? Colors.black.withValues(alpha: 0.25) : Colors.black.withValues(alpha: 0.08);
    Widget divider() => Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 6),
        color: isDark ? AppColors.outlineDark.withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.25));
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: isDark ? 12 : 10, sigmaY: isDark ? 12 : 10),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: border),
              boxShadow: [BoxShadow(blurRadius: 20, offset: const Offset(0, 10), color: shadow)],
            ),
            child: SizedBox(
              height: 210,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  _RightRow(title: model.line1Title, value: model.line1Value, icon: model.line1Icon),
                  divider(),
                  _RightRow(title: model.line2Title, value: model.line2Value, icon: model.line2Icon),
                  divider(),
                  _RightRow(title: model.line3Title, value: model.line3Value, icon: model.line3Icon, valueColor: model.line3Color),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RightRow extends StatelessWidget {
  final String title, value;
  final IconData icon;
  final Color? valueColor;
  const _RightRow({required this.title, required this.value, required this.icon, this.valueColor});

  @override
  Widget build(BuildContext context) {
    final isDark = isDarkOf(context);
    final primary = isDark ? AppColors.primaryLight : AppColors.primary;
    return Row(children: [
      Container(
        width: 36, height: 36,
        decoration: BoxDecoration(color: primary.withValues(alpha: 0.12), shape: BoxShape.circle),
        child: Icon(icon, size: 18, color: primary),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: isDark ? AppColors.onSurfaceVariantDark : Colors.black54)),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
              color: valueColor ?? (isDark ? AppColors.onSurfaceDark : Colors.black))),
        ]),
      ),
    ]);
  }
}
