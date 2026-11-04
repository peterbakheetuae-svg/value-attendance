import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import 'dash_mode_team.dart'; // ✅ التصحيح: استيراد النسخة الصحيحة

class TopTabs extends StatelessWidget {
  final DashMode mode;
  final void Function(DashMode) onTap;

  const TopTabs({required this.mode, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;
    final primaryColor = isDark ? AppColors.primaryLight : AppColors.primary;
    final textColor = isDark ? Colors.white : Colors.black;

    Widget tab(String key, IconData icon, DashMode m) {
      final selected = mode == m;
      return Expanded(
        child: GestureDetector(
          onTap: () => onTap(m),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: selected ? primaryColor : Colors.transparent,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: selected ? Colors.white : textColor),
                const SizedBox(width: 6),
                Text(
                  AppLocalizations.of(context, key),
                  style: TextStyle(
                    color: selected ? Colors.white : textColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.35),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        children: [
          tab('check', Icons.checklist, DashMode.check),
          tab('break_time', Icons.access_time, DashMode.breakTime),
          tab('leave', Icons.logout, DashMode.leave),
        ],
      ),
    );
  }
}