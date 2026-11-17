import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../widgets/glass_ui.dart';
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';
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
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
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

    // swipe the bar right / left to move between the tabs: the selection goes the way the finger goes
    void swipe(DragEndDetails d) {
      final v = d.primaryVelocity ?? 0;
      if (v.abs() < 150) return;
      final rtl = Directionality.of(context) == TextDirection.rtl;
      final forward = rtl ? v < 0 : v > 0;   // the selection moves the way the finger moves
      const order = DashMode.values;
      final i = order.indexOf(mode) + (forward ? 1 : -1);
      if (i < 0 || i >= order.length) return;
      onTap(order[i]);
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: swipe,
      child: Container(
      padding: const EdgeInsets.all(6),
      decoration: Glass.tile(isDark, r: 30),
      child: Row(
        children: [
          tab('check', Icons.checklist, DashMode.check),
          tab('break_time', Icons.directions_walk_rounded, DashMode.breakTime),
          tab('leave', Icons.logout, DashMode.leave),
        ],
      ),
      ),
    );
  }
}