import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';

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
                value: (monthData["workDays"] ?? "--").toString(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildStatMiniCard(
                context: context,
                title: AppLocalizations.of(context, 'leave_days'),
                value: (monthData["leaveDays"] ?? "0").toString(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildStatMiniCard(
                context: context,
                title: AppLocalizations.of(context, 'absent_days'),
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
                value: (monthData["sickLeave"] ?? "0").toString(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildStatMiniCard(
                context: context,
                title: AppLocalizations.of(context, 'overtime_hours'),
                value: (monthData["overtimeHours"] ?? "--").toString(),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatMiniCard({
    required BuildContext context,
    required String title,
    required String value,
  }) {
    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;

    return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.3),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white70 : Colors.grey.shade700,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        )

    );
  }
}