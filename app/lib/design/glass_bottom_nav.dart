// Original JPH Attendance GlassBottomNav (radius 40, blur 12/14, 72px, pill for the active
// item with icon + label). Generalised to take its items so each role gets its own tabs.
import 'dart:ui';
import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'glass.dart';

class NavItem {
  final IconData icon;
  final String label;
  const NavItem(this.icon, this.label);
}

class GlassBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<NavItem> items;
  const GlassBottomNav({super.key, required this.currentIndex, required this.onTap, required this.items});

  @override
  Widget build(BuildContext context) {
    final isDark = isDarkOf(context);
    final activeColor = isDark ? AppColors.primaryLight : AppColors.primary;
    final inactiveColor = isDark ? Colors.white70 : Colors.black54;
    return SafeArea(
      top: false,
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 22),
            child: RepaintBoundary(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(40),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: isDark ? 14.0 : 12.0, sigmaY: isDark ? 14.0 : 12.0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(40),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.12), blurRadius: 22, offset: const Offset(0, 10))],
                    ),
                    child: SizedBox(
                      height: 72,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          for (var i = 0; i < items.length; i++)
                            _Item(item: items[i], active: i == currentIndex, onTap: () => onTap(i),
                                activeColor: activeColor, inactiveColor: inactiveColor),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Item extends StatelessWidget {
  final NavItem item;
  final bool active;
  final VoidCallback onTap;
  final Color activeColor;
  final Color inactiveColor;
  const _Item({required this.item, required this.active, required this.onTap, required this.activeColor, required this.inactiveColor});

  @override
  Widget build(BuildContext context) {
    final fg = active ? Colors.white : inactiveColor;
    return Semantics(
      button: true, selected: active, label: item.label,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: active ? activeColor.withValues(alpha: 0.95) : Colors.transparent, borderRadius: BorderRadius.circular(22)),
          child: Row(children: [
            Icon(item.icon, color: fg, size: 22),
            if (active) ...[
              const SizedBox(width: 8),
              Text(item.label, style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 12)),
            ],
          ]),
        ),
      ),
    );
  }
}
