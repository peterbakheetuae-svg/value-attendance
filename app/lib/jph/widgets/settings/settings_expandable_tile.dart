import 'package:flutter/material.dart';

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
    return Column(
      children: [
        ListTile(
          leading: Icon(icon),
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          trailing: AnimatedRotation(
            turns: expanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 250),
            child: const Icon(Icons.expand_more),
          ),
          onTap: onToggle,
        ),

        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          child: expanded
              ? Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: child,
          )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}
