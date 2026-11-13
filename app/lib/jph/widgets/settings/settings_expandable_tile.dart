import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../glass_ui.dart';
import 'settings_tile.dart';

/// A settings group in the dashboard's card (the «Ardena» glass square) that opens in place.
class SettingsExpandableTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  const SettingsExpandableTile({
    super.key,
    required this.icon,
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final d = Provider.of<AppController>(context).isDark;
    return Container(
      decoration: Glass.panel(d, r: 18),
      child: Material(
        type: MaterialType.transparency,
        child: Column(children: [
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                settingsIcon(d, icon),
                const SizedBox(width: 12),
                Expanded(child: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Glass.ink(d)))),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 350),
                  curve: Glass.ease,
                  child: Icon(Icons.expand_more_rounded, color: Glass.muted(d)),
                ),
              ]),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 350),
            curve: Glass.ease,
            child: expanded ? Padding(padding: const EdgeInsets.fromLTRB(8, 0, 8, 12), child: child) : const SizedBox(width: double.infinity),
          ),
        ]),
      ),
    );
  }
}
