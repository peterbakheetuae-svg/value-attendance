import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/glass_ui.dart';

class TodayStats extends StatelessWidget {
  final Map<String, dynamic> sheetData;

  const TodayStats({required this.sheetData});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildStatMiniCard(
                context: context,
                title: 'وقت العمل',
                icon: Icons.timer_rounded,
                color: Ar.info,
                value: (sheetData["workTime"] ?? "--:--").toString(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildStatMiniCard(
                context: context,
                title: 'الاستراحة',
                icon: Icons.free_breakfast_rounded,
                color: Ar.green,
                value: (sheetData["breakTime"] ?? "--:--").toString(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildStatMiniCard(
                context: context,
                title: AppLocalizations.of(context, 'late_time'),
                icon: Icons.schedule_rounded,
                color: Ar.amber,
                value: (sheetData["lateTime"] ?? "00:00").toString(),
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