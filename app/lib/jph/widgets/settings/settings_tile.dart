import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../glass_ui.dart';

/// A settings row in the dashboard's card (the «Ardena» glass square): an icon tile, the title and a chevron.
class SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final d = Provider.of<AppController>(context).isDark;
    return Container(
      decoration: Glass.panel(d, r: 18),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              settingsIcon(d, icon),
              const SizedBox(width: 12),
              Expanded(child: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Glass.ink(d)))),
              Icon(Directionality.of(context) == TextDirection.rtl ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
                  color: Glass.muted(d)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// the 32px icon tile the settings rows and the «المزيد» sheet share
Widget settingsIcon(bool d, IconData icon) => Container(
      width: 32,
      height: 32,
      decoration: Glass.tile(d, r: 10),
      child: Icon(icon, size: 17, color: d ? Glass.blueHi : Glass.blue),
    );
