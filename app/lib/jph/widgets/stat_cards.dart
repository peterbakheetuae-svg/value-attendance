import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_controller.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_colors.dart';
import 'glass_ui.dart';

/* ================= MODEL ================= */

class StatRightCardModel {
  final String line1Title;
  final String line1Value;
  final IconData line1Icon;

  final String line2Title;
  final String line2Value;
  final IconData line2Icon;

  final String line3Title;
  final String? line3Value;
  final Widget? line3Widget;
  final IconData line3Icon;

  const StatRightCardModel({
    required this.line1Title,
    required this.line1Value,
    required this.line1Icon,
    required this.line2Title,
    required this.line2Value,
    required this.line2Icon,
    required this.line3Title,
    this.line3Value,
    this.line3Widget,
    required this.line3Icon,
  });

  factory StatRightCardModel.check({
    required String checkTime,
    required String checkOutTime,
    String? workTime,
    Widget? workTimeWidget,
  }) {
    return StatRightCardModel(
      line1Title: "check_in_time",
      line1Value: checkTime,
      line1Icon: Icons.login_rounded,
      line2Title: "check_out_time",
      line2Value: checkOutTime == "--:--" ? "--:--" : checkOutTime,
      line2Icon: Icons.logout_rounded,
      line3Title: "working_time",
      line3Value: workTime,
      line3Widget: workTimeWidget,
      line3Icon: Icons.timelapse_rounded,
    );
  }

  factory StatRightCardModel.breakTime({
    required String start,
    required String end,
    required String total,
  }) {
    return StatRightCardModel(
      line1Title: "start_time",
      line1Value: start,
      line1Icon: Icons.play_circle_outline_rounded,
      line2Title: "end_time",
      line2Value: end == "--:--" ? "--:--" : end,
      line2Icon: Icons.stop_circle_outlined,
      line3Title: "break_time",
      line3Value: total,
      line3Icon: Icons.timer_rounded,
    );
  }

  /// Hourly permission / external visit (replaces the break card).
  /// 1) time out  2) time back  3) live countdown to the return time.
  factory StatRightCardModel.outing({
    required String kind,
    required String start,
    required String expectedReturn,
    DateTime? returnAt,
  }) {
    return StatRightCardModel(
      line1Title: "outing_left_at",
      line1Value: start,
      line1Icon: Icons.logout_rounded,
      line2Title: "outing_return_at",
      line2Value: expectedReturn,
      line2Icon: Icons.login_rounded,
      line3Title: "outing_remaining",
      line3Value: returnAt == null ? '--:--' : null,
      line3Widget: returnAt == null ? null : OutingCountdown(until: returnAt),
      line3Icon: Icons.hourglass_bottom_rounded,
    );
  }

  factory StatRightCardModel.leave({
    required String leaveDays,
    required String leaveAttendance,
    required String sickLeave,
  }) {
    return StatRightCardModel(
      line1Title: "leave_days",
      line1Value: leaveDays,
      line1Icon: Icons.event_available_rounded,
      line2Title: "without_pay",
      line2Value: leaveAttendance,
      line2Icon: Icons.money_off_rounded,
      line3Title: "sick_leave",
      line3Value: sickLeave,
      line3Icon: Icons.medical_services_rounded,
    );
  }
}

/* ================= RIGHT GLASS CARD ================= */

class StatRightCard extends StatelessWidget {
  final StatRightCardModel model;
  /// greyed out — e.g. the employee's file says he has no check-in / check-out
  final bool disabled;

  const StatRightCard({super.key, required this.model, this.disabled = false});

  @override
  Widget build(BuildContext context) {
    return Selector<AppController, bool>(
      selector: (_, controller) => controller.isDark,
      builder: (context, isDark, _) {
        final card = _StatRightCardContent(
          model: model,
          isDark: isDark,
        );
        if (!disabled) return card;
        return Opacity(
          opacity: 0.45,
          child: ColorFiltered(
            colorFilter: const ColorFilter.matrix(<double>[
              0.2126, 0.7152, 0.0722, 0, 0,
              0.2126, 0.7152, 0.0722, 0, 0,
              0.2126, 0.7152, 0.0722, 0, 0,
              0, 0, 0, 1, 0,
            ]),
            child: card,
          ),
        );
      },
    );
  }
}

class _StatRightCardContent extends StatelessWidget {
  final StatRightCardModel model;
  final bool isDark;

  const _StatRightCardContent({
    required this.model,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = isDark
        ? AppColors.outlineDark.withOpacity(0.3)
        : Colors.white.withOpacity(0.30);

    final shadowColor = isDark
        ? Colors.black.withOpacity(0.25)
        : Colors.black.withOpacity(0.08);

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: isDark ? 12 : 10,
            sigmaY: isDark ? 12 : 10,
          ),
          child: DecoratedBox(
            decoration: Glass.panel(isDark, r: 26), // the dashboard's card
            child: SizedBox(
              height: 210,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _Row(
                      title: AppLocalizations.of(context, model.line1Title),
                      value: model.line1Value,
                      icon: model.line1Icon,
                      isDark: isDark,
                    ),
                    const _Divider(isDark: null), // سيتم تحديثه في build
                    _Row(
                      title: AppLocalizations.of(context, model.line2Title),
                      value: model.line2Value,
                      icon: model.line2Icon,
                      isDark: isDark,
                    ),
                    const _Divider(isDark: null), // سيتم تحديثه في build
                    _RowWidget(
                      title: AppLocalizations.of(context, model.line3Title),
                      value: model.line3Widget ??
                          Text(
                            model.line3Value ?? "--:--",
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: isDark
                                  ? AppColors.onSurfaceDark
                                  : Colors.black,
                            ),
                          ),
                      icon: model.line3Icon,
                      isDark: isDark,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final bool isDark;

  const _Row({
    required this.title,
    required this.value,
    required this.icon,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final titleColor = isDark
        ? AppColors.onSurfaceVariantDark
        : Colors.black54;

    final valueColor = isDark
        ? AppColors.onSurfaceDark
        : Colors.black;

    return Row(
      children: [
        _Icon(icon: icon, isDark: isDark),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 0), // Placeholder
              Text(
                title,
                style: TextStyle(fontSize: 12, color: titleColor),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: valueColor,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RowWidget extends StatelessWidget {
  final String title;
  final Widget value;
  final IconData icon;
  final bool isDark;

  const _RowWidget({
    required this.title,
    required this.value,
    required this.icon,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final titleColor = isDark
        ? AppColors.onSurfaceVariantDark
        : Colors.black54;

    return Row(
      children: [
        _Icon(icon: icon, isDark: isDark),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(fontSize: 12, color: titleColor),
              ),
              const SizedBox(height: 4),
              value,
            ],
          ),
        ),
      ],
    );
  }
}

class _Icon extends StatelessWidget {
  final IconData icon;
  final bool isDark;

  const _Icon({
    required this.icon,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = isDark
        ? AppColors.primaryLight
        : AppColors.primary;

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: iconColor.withOpacity(0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 18, color: iconColor),
    );
  }
}

class _Divider extends StatelessWidget {
  final bool? isDark;

  const _Divider({this.isDark});

  @override
  Widget build(BuildContext context) {
    // إذا كان isDark == null، نحصل عليه من Provider
    final darkMode = isDark ??
        Provider.of<AppController>(context, listen: false).isDark;

    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: darkMode
          ? AppColors.outlineDark.withOpacity(0.3)
          : Colors.white.withOpacity(0.25),
    );
  }
}

/* ================= MINI STAT CARD ================= */

class StatMiniCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData? icon;

  const StatMiniCard({
    super.key,
    required this.title,
    required this.value,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Selector<AppController, bool>(
      selector: (_, controller) => controller.isDark,
      builder: (context, isDark, _) {
        return _StatMiniCardContent(
          title: title,
          value: value,
          icon: icon,
          isDark: isDark,
        );
      },
    );
  }
}

class _StatMiniCardContent extends StatelessWidget {
  final String title;
  final String value;
  final IconData? icon;
  final bool isDark;

  const _StatMiniCardContent({
    required this.title,
    required this.value,
    required this.icon,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = isDark
        ? AppColors.outlineDark.withOpacity(0.3)
        : Colors.white.withOpacity(0.30);

    final shadowColor = isDark
        ? Colors.black.withOpacity(0.20)
        : Colors.black.withOpacity(0.06);

    final valueColor = isDark
        ? AppColors.onSurfaceDark
        : Colors.black;

    final titleColor = isDark
        ? AppColors.onSurfaceVariantDark
        : Colors.black54;

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: isDark ? 10 : 8,
            sigmaY: isDark ? 10 : 8,
          ),
          child: DecoratedBox(
            decoration: Glass.panel(isDark, r: 22), // the dashboard's card
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Container(
                      width: 32,
                      height: 32,
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: (isDark
                            ? AppColors.primaryLight
                            : AppColors.primary).withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        icon,
                        size: 16,
                        color: isDark
                            ? AppColors.primaryLight
                            : AppColors.primary,
                      ),
                    ),
                  ],

                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: valueColor,
                    ),
                  ),

                  const SizedBox(height: 6),

                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: titleColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Live countdown to the return time; turns red and counts up once it has passed.
class OutingCountdown extends StatefulWidget {
  final DateTime until;
  const OutingCountdown({super.key, required this.until});

  @override
  State<OutingCountdown> createState() => _OutingCountdownState();
}

class _OutingCountdownState extends State<OutingCountdown> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.until.difference(DateTime.now());
    final late = d.isNegative;
    final a = d.abs();
    String two(int v) => v.toString().padLeft(2, '0');
    final txt = '${late ? '+' : ''}${two(a.inHours)}:${two(a.inMinutes % 60)}:${two(a.inSeconds % 60)}';
    return Text(txt, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: late ? Ar.red : null));
  }
}
