import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../l10n/app_localizations.dart'; // 🔥 استيراد الترجمة


class DailySection extends StatelessWidget {
  final List<Map<String, dynamic>> daily;
  final bool isDark;

  const DailySection({
    super.key,
    required this.daily,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final d in daily) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              (d["date"] ?? "").toString(),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: isDark ? Colors.white : Colors.black,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 18),
            decoration: BoxDecoration(
              color: isDark ? Colors.white.withOpacity(0.15) : Colors.white,
              borderRadius: BorderRadius.circular(26),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 10,
                ),
              ],
            ),
            child: DailyCardContent(dayData: d, isDark: isDark),
          ),
          const SizedBox(height: 18),
        ],
      ],
    );
  }
}

class DailyCardContent extends StatelessWidget {
  final Map<String, dynamic> dayData;
  final bool isDark;

  const DailyCardContent({
    super.key,
    required this.dayData,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    // 🔥 ترجمة النصوص
    final attendanceText = AppLocalizations.of(context, 'attendance_1');
    final startTimeText = AppLocalizations.of(context, 'start_time');
    final endTimeText = AppLocalizations.of(context, 'end_time');
    final workHoursText = AppLocalizations.of(context, 'work_hours');
    final lateText = AppLocalizations.of(context, 'late_time');
    final holidayText = AppLocalizations.of(context, 'holiday');
    final absentText = AppLocalizations.of(context, 'absent');
    final leaveText = AppLocalizations.of(context, 'leave');
    final dateText = AppLocalizations.of(context, 'date');

    final status = (dayData["status"] ?? "").toString().trim();

    if (status == "منصرف") {
      return Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: isDark ? Colors.green.shade900.withOpacity(0.3) : Colors.green.shade100,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.check_circle,
                  color: isDark ? Colors.green.shade300 : Colors.green.shade700,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  attendanceText, // 🔥 استخدام الترجمة
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.green.shade300 : Colors.green.shade700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          DailyInfoRow(
            label: startTimeText, // 🔥 استخدام الترجمة
            value: (dayData["start"] ?? "--").toString(),
            icon: Icons.login_rounded,
            iconColor: isDark ? const Color(0xFF4CAF50) : const Color(0xFF20A45A),
            bgColor: isDark ? const Color(0xFF1A3D2C) : const Color(0xFFDFF3E6),
            isDark: isDark,
          ),
          const SizedBox(height: 12),
          DailyInfoRow(
            label: endTimeText, // 🔥 استخدام الترجمة
            value: (dayData["end"] ?? "--").toString(),
            icon: Icons.logout_rounded,
            iconColor: isDark ? const Color(0xFFEF5350) : const Color(0xFFD04545),
            bgColor: isDark ? const Color(0xFF3A2424) : const Color(0xFFFFE0E0),
            isDark: isDark,
          ),
          const SizedBox(height: 12),
          DailyInfoRow(
            label: workHoursText, // 🔥 استخدام الترجمة
            value: (dayData["work"] ?? "--").toString(),
            icon: Icons.access_time_rounded,
            iconColor: isDark ? AppColors.primaryLight : AppColors.primary,
            bgColor: isDark ? AppColors.primaryLight.withOpacity(0.2) : const Color(0xFFE8E6FF),
            isDark: isDark,
          ),
          const SizedBox(height: 12),
          DailyInfoRow(
            label: lateText,
            value: (dayData["late"] ?? "--").toString(),
            icon: Icons.timer_rounded,
            iconColor: isDark ? const Color(0xFFFF9800) : const Color(0xFFFF5722),
            bgColor: isDark ? const Color(0xFF332211) : const Color(0xFFFFF3E0),
            isDark: isDark,
          ),
        ],
      );
    } else {
      Color statusColor;
      IconData statusIcon;
      String displayStatus = status;

      if (status.contains("اجازه") || status.contains("عطلة")) {
        statusColor = isDark ? const Color(0xFFFFB74D) : const Color(0xFFFF9800);
        statusIcon = Icons.emoji_events_rounded;
        displayStatus = holidayText; // 🔥 استخدام الترجمة
      } else if (status.contains("غياب") || status.isEmpty) {
        statusColor = isDark ? const Color(0xFFEF5350) : const Color(0xFFD04545);
        statusIcon = Icons.cancel_rounded;
        displayStatus = absentText; // 🔥 استخدام الترجمة
      } else if (status.contains("إجازة")) {
        statusColor = isDark ? const Color(0xFFFFB74D) : const Color(0xFFFF9800);
        statusIcon = Icons.emoji_events_rounded;
        displayStatus = leaveText; // 🔥 استخدام الترجمة
      } else {
        statusColor = isDark ? Colors.grey.shade400 : Colors.grey.shade600;
        statusIcon = Icons.info_rounded;
      }

      return Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
            decoration: BoxDecoration(
              color: isDark ? statusColor.withOpacity(0.2) : statusColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: statusColor.withOpacity(0.3),
                width: 2,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  statusIcon,
                  color: statusColor,
                  size: 32,
                ),
                const SizedBox(width: 16),
                Text(
                  displayStatus,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: statusColor,
                  ),
                ),
              ],
            ),
          ),
          if (dayData["date"] != null) ...[
            const SizedBox(height: 12),
            Text(
              "$dateText ${dayData["date"]}", // 🔥 استخدام الترجمة
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
              ),
            ),
          ],
        ],
      );
    }
  }
}

class DailyInfoRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color iconColor;
  final Color bgColor;
  final bool isDark;

  const DailyInfoRow({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.iconColor,
    required this.bgColor,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: bgColor,
        border: Border.all(
          color: iconColor.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: isDark ? Colors.black.withOpacity(0.3) : Colors.white.withOpacity(0.8),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}