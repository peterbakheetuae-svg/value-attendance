import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The «Ardena» glass look (the reference the owner picked): warm smoked-glass squares, soft inner tiles,
/// pill segments and meters — with our blue in place of their orange.
class Glass {
  Glass._();

  static const Color blue = AppColors.primary; // our blue (their orange)
  static const Color blueHi = AppColors.primaryLight;
  static const Color good = Color(0xFF63D985);
  static const Color amber = Color(0xFFF7A928);
  static const Color bad = Color(0xFFFF7D6E);

  static Color ink(bool d) => d ? const Color(0xFFF6F5F2) : const Color(0xFF1C1B19);
  static Color muted(bool d) => d ? const Color(0xFFC9C6BF) : const Color(0xFF5F5C57);
  static Color card(bool d) => d ? const Color(0x66605F5B) : Colors.white.withOpacity(0.62);
  static Color rim(bool d) => d ? Colors.white.withOpacity(0.10) : Colors.black.withOpacity(0.07);
  static Color line(bool d) => d ? Colors.white.withOpacity(0.09) : Colors.black.withOpacity(0.07);
  static Color track(bool d) => d ? Colors.white.withOpacity(0.10) : Colors.black.withOpacity(0.08);

  /// the soft tile inside a card (Value / Rent / Yield)
  static BoxDecoration tile(bool d, {double r = 14}) => BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: d
              ? [Colors.white.withOpacity(0.075), Colors.white.withOpacity(0.03)]
              : [Colors.black.withOpacity(0.035), Colors.black.withOpacity(0.015)],
        ),
        borderRadius: BorderRadius.circular(r),
        border: Border.all(color: rim(d)),
      );

  /// the glass square itself (cards, the side bar, the «المزيد» sheet)
  static BoxDecoration panel(bool d, {double r = 20}) => BoxDecoration(
        // the card colour with the glass shine laid over it (top-left)
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: const [0, 0.32, 0.58],
          colors: d
              ? [for (final o in const [0.13, 0.035, 0.0]) Color.alphaBlend(Colors.white.withOpacity(o), card(d))]
              : [Colors.white.withOpacity(0.85), Colors.white.withOpacity(0.62), Colors.white.withOpacity(0.55)],
        ),
        borderRadius: BorderRadius.circular(r),
        border: Border.all(color: d ? Colors.white.withOpacity(0.11) : Colors.white.withOpacity(0.7)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(d ? 0.35 : 0.08), blurRadius: 40, offset: const Offset(0, 18), spreadRadius: -22)],
      );
}

/// A blurred glass square.
class GlassBox extends StatelessWidget {
  final Widget child;
  final bool isDark;
  final double radius;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  const GlassBox({super.key, required this.child, required this.isDark, this.radius = 20, this.padding = EdgeInsets.zero, this.onTap});

  @override
  Widget build(BuildContext context) {
    final box = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: Glass.panel(isDark, r: radius),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
    if (onTap == null) return box;
    return MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: box));
  }
}

/// Pill segments (Holdings / Rent roll / Loans — Value / Yield / Growth): the chosen one filled with our blue.
class GlassSegments extends StatelessWidget {
  final bool isDark;
  final List<(String, int?)> items; // label, optional count badge
  final int selected;
  final ValueChanged<int> onTap;
  final bool big;
  final bool expand;
  const GlassSegments({super.key, required this.isDark, required this.items, required this.selected, required this.onTap, this.big = true, this.expand = false});

  @override
  Widget build(BuildContext context) {
    Widget seg(int i) {
      final on = i == selected;
      final (label, count) = items[i];
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => onTap(i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.symmetric(horizontal: big ? 20 : 16, vertical: big ? 12 : 8),
            decoration: BoxDecoration(
              color: on ? (big ? Glass.blue : (isDark ? Colors.white.withOpacity(0.12) : Colors.white)) : Colors.transparent,
              borderRadius: BorderRadius.circular(99),
              boxShadow: on && big ? [BoxShadow(color: Glass.blue.withOpacity(0.35), blurRadius: 14, offset: const Offset(0, 5))] : null,
            ),
            child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(label,
                  style: TextStyle(
                      fontSize: big ? 15 : 13.5,
                      fontWeight: FontWeight.w700,
                      color: on ? (big ? Colors.white : Glass.ink(isDark)) : Glass.ink(isDark).withOpacity(0.85))),
              if (count != null && count > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(color: (on ? Colors.white : Glass.ink(isDark)).withOpacity(0.18), borderRadius: BorderRadius.circular(99)),
                  child: Text('$count', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: on ? Colors.white : Glass.ink(isDark))),
                ),
              ],
            ]),
          ),
        ),
      );
    }

    return Container(
      padding: EdgeInsets.all(big ? 5 : 3),
      decoration: BoxDecoration(
        gradient: LinearGradient(
            colors: isDark ? [Colors.white.withOpacity(0.075), Colors.white.withOpacity(0.03)] : [Colors.white.withOpacity(0.7), Colors.white.withOpacity(0.45)]),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: Glass.rim(isDark)),
      ),
      child: expand
          ? Row(children: [for (var i = 0; i < items.length; i++) Expanded(child: seg(i))])
          : Row(mainAxisSize: MainAxisSize.min, children: [for (var i = 0; i < items.length; i++) seg(i)]),
    );
  }
}

/// A round filter chip (All / Lisbon / Porto…).
class GlassChip extends StatelessWidget {
  final bool isDark;
  final String label;
  final bool on;
  final VoidCallback onTap;
  const GlassChip({super.key, required this.isDark, required this.label, required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            decoration: BoxDecoration(
              color: on ? Glass.blue : (isDark ? Colors.white.withOpacity(0.06) : Colors.white.withOpacity(0.55)),
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: on ? Colors.transparent : Glass.rim(isDark)),
            ),
            child: Text(label, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: on ? Colors.white : Glass.ink(isDark))),
          ),
        ),
      );
}

/// The thin progress line under a card (5/6 let).
class GlassMeter extends StatelessWidget {
  final bool isDark;
  final double value; // 0..1
  final Color color;
  const GlassMeter({super.key, required this.isDark, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: 8,
          child: Stack(children: [
            Positioned.fill(child: ColoredBox(color: Glass.track(isDark))),
            FractionallySizedBox(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: value.clamp(0, 1).toDouble(),
              child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8))),
            ),
          ]),
        ),
      );
}

/// A label / value tile inside a card.
class GlassStat extends StatelessWidget {
  final bool isDark;
  final String label;
  final String value;
  final Color? color;
  const GlassStat({super.key, required this.isDark, required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: Glass.tile(isDark),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: Glass.muted(isDark))),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: color ?? Glass.ink(isDark))),
          ),
        ]),
      );
}
