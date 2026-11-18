import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../widgets/glass_ui.dart';
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';
import 'dash_mode.dart'; // تم الاستيراد من ملف منفصل

class TopTabs extends StatefulWidget {
  final DashMode mode;
  final void Function(DashMode) onTap;

  const TopTabs({super.key, required this.mode, required this.onTap});

  @override
  State<TopTabs> createState() => _TopTabsState();
}

/// حضور / إذن / إجازة — tap a tab, or drag the selection along the bar with the finger (it follows the finger and
/// stops on the tab under it), or flick it right / left. For everyone who has the attendance page.
class _TopTabsState extends State<TopTabs> {
  static const _order = [DashMode.check, DashMode.breakTime, DashMode.leave];
  bool _dragged = false;

  /// the tab under the finger at [dx] (the bar's width [w]); in Arabic the first tab is on the right
  DashMode _at(double dx, double w, bool rtl) {
    var i = (dx / (w / _order.length)).floor().clamp(0, _order.length - 1);
    if (rtl) i = _order.length - 1 - i;
    return _order[i];
  }

  void _go(DashMode m) {
    if (m != widget.mode) widget.onTap(m);
  }

  @override
  Widget build(BuildContext context) {
    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;
    final primaryColor = isDark ? AppColors.primaryLight : AppColors.primary;
    final textColor = isDark ? Colors.white : Colors.black;
    final rtl = Directionality.of(context) == TextDirection.rtl;

    Widget tab(String key, IconData icon, DashMode m) {
      final selected = widget.mode == m;
      return Expanded(
        child: GestureDetector(
          onTap: () => _go(m),
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
                Flexible(
                  child: Text(
                    AppLocalizations.of(context, key),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? Colors.white : textColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth - 12;   // the padding
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => _dragged = false,
        // the selection follows the finger
        onHorizontalDragUpdate: (d) {
          if (d.localPosition.dx < 6 || d.localPosition.dx > w + 6) return;
          _dragged = true;
          _go(_at(d.localPosition.dx - 6, w, rtl));
        },
        // a quick flick (no tab passed under the finger): one tab the way it went
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v.abs() < 250) return;
          final forward = rtl ? v < 0 : v > 0;
          final i = _order.indexOf(widget.mode) + (forward ? 1 : -1);
          if (!_dragged && i >= 0 && i < _order.length) _go(_order[i]);
        },
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: Glass.tile(isDark, r: 30),
          child: Row(
            children: [
              tab('check', Icons.checklist, DashMode.check),
              tab('break_time', Icons.access_time, DashMode.breakTime),
              tab('leave', Icons.logout, DashMode.leave),
            ],
          ),
        ),
      );
    });
  }
}
