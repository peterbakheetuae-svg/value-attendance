import 'package:flutter/material.dart';

import 'glass_ui.dart';

/// The Windows app (VALUNIVO.exe) only: check-in / check-out are done from the phone, never from the computer.
/// In place of the fingerprint button + tabs, the employee sees his day as cards in the owner dashboard's style:
/// a highlighted card «سجلت حضور ولا لأ» with the check-in / check-out times and the live work time, then today's and the
/// month's numbers. Nothing here punches.
class WindowsAttendanceOverview extends StatelessWidget {
  final bool isDark;
  final String checkIn, checkOut;
  /// the live work time (the dashboard's ticker), "--:--" when nothing yet
  final ValueListenable<String>? liveWork;
  final Map sheetData, monthData;
  final bool exempt;
  /// false where the page shows the month in its own boxes (the admins' dashboard)
  final bool showMonth;
  const WindowsAttendanceOverview({
    super.key,
    required this.isDark,
    required this.checkIn,
    required this.checkOut,
    required this.sheetData,
    required this.monthData,
    this.liveWork,
    this.exempt = false,
    this.showMonth = true,
  });

  bool get _in => checkIn != '--:--' && checkIn.isNotEmpty;
  bool get _out => checkOut != '--:--' && checkOut.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final ink = Glass.ink(isDark), muted = Glass.muted(isDark);
    final (title, sub, icon) = exempt
        ? ('مش محتاج تسجيل حضور', 'حسابك معفي من الحضور والانصراف', Icons.verified_user_outlined)
        : _out
            ? ('انصرفت النهارده', 'حضور $checkIn · انصراف $checkOut', Icons.logout_rounded)
            : _in
                ? ('سجلت حضور ✓', 'من الساعة $checkIn', Icons.how_to_reg_rounded)
                : ('لسه مسجلتش حضور', 'سجّل من الموبايل', Icons.schedule_rounded);

    Widget status = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            begin: Alignment(-0.8, -1), end: Alignment(0.9, 1), colors: [Glass.blueHi, Glass.blue]),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Glass.blue.withOpacity(0.35), blurRadius: 30, offset: const Offset(0, 14), spreadRadius: -18)],
      ),
      child: Row(children: [
        Container(
          width: 52, height: 52,
          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withOpacity(0.18)),
          child: Icon(icon, color: Colors.white, size: 26),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: Colors.white)),
            const SizedBox(height: 4),
            Text(sub, style: TextStyle(fontSize: 14, color: Colors.white.withOpacity(0.85))),
          ]),
        ),
        if (_in && !_out && liveWork != null)
          ValueListenableBuilder<String>(
            valueListenable: liveWork!,
            builder: (_, v, __) => Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(v, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white)),
              Text('وقت الشغل', style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.8))),
            ]),
          ),
      ]),
    );

    Widget tile(String label, String value, IconData ic) => Container(
          padding: const EdgeInsets.all(14),
          decoration: Glass.panel(isDark, r: 18),
          child: Row(children: [
            Icon(ic, size: 20, color: isDark ? Glass.blueHi : Glass.blue),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: muted)),
                const SizedBox(height: 3),
                Text(value, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: ink)),
              ]),
            ),
          ]),
        );

    String v(Map m, String k, String d) => '${m[k] ?? d}';
    final tiles = [
      tile('الحضور', _in ? checkIn : '--:--', Icons.login_rounded),
      tile('الانصراف', _out ? checkOut : '--:--', Icons.logout_rounded),
      tile('وقت الشغل النهارده', v(sheetData, 'workTime', '--:--'), Icons.timer_outlined),
      tile('تأخير النهارده', v(sheetData, 'lateTime', '00:00'), Icons.schedule_rounded),
      if (showMonth) ...[
      tile('أيام الحضور الشهر ده', v(monthData, 'workDays', '--'), Icons.event_available_outlined),
      tile('أيام الغياب', v(monthData, 'absentDays', '--'), Icons.event_busy_outlined),
      tile('أيام الإجازات', v(monthData, 'leaveDays', '0'), Icons.beach_access_outlined),
      tile('تأخير الشهر', v(monthData, 'lateTime', '--'), Icons.hourglass_bottom_rounded),
      ],
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      status,
      const SizedBox(height: 10),
      Row(children: [
        Icon(Icons.phone_android_rounded, size: 16, color: muted),
        const SizedBox(width: 6),
        Expanded(
          child: Text('تسجيل الحضور والانصراف من تطبيق الموبايل بس — البرنامج بيعرض حالتك',
              style: TextStyle(fontSize: 12.5, color: muted)),
        ),
      ]),
      const SizedBox(height: 16),
      LayoutBuilder(builder: (context, c) {
        final cols = c.maxWidth >= 900 ? 4 : 2;
        final w = (c.maxWidth - (cols - 1) * 12) / cols;
        return Wrap(spacing: 12, runSpacing: 12, children: [for (final t in tiles) SizedBox(width: w, child: t)]);
      }),
    ]);
  }
}
