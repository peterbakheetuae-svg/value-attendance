import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/jph_form_ui.dart';

class MonthStats extends StatelessWidget {
  final Map<String, dynamic> monthData;

  const MonthStats({required this.monthData});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildStatMiniCard(
                context: context,
                title: AppLocalizations.of(context, 'work_days'),
                icon: Icons.event_available_rounded,
                color: Colors.green,
                value: (monthData["workDays"] ?? "--").toString(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildStatMiniCard(
                context: context,
                title: AppLocalizations.of(context, 'leave_days'),
                icon: Icons.beach_access_rounded,
                color: Colors.purple,
                value: (monthData["leaveDays"] ?? "0").toString(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildStatMiniCard(
                context: context,
                title: AppLocalizations.of(context, 'absent_days'),
                icon: Icons.event_busy_rounded,
                color: Colors.red,
                value: (monthData["absentDays"] ?? "--").toString(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _buildStatMiniCard(
                context: context,
                title: AppLocalizations.of(context, 'sick_leave'),
                icon: Icons.healing_rounded,
                color: Colors.pink,
                value: (monthData["sickLeave"] ?? "0").toString(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildStatMiniCard(
                context: context,
                title: AppLocalizations.of(context, 'late_month'),
                icon: Icons.schedule_rounded,
                color: Colors.orange,
                value: (monthData["lateTime"] ?? "--").toString(),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Same box as ملخص المالية (JphUi.stat).
  Widget _buildStatMiniCard({
    required BuildContext context,
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    final isDark = Provider.of<AppController>(context).isDark;
    return JphUi.stat(isDark, title, value, icon, color);
  }
}