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
  static Color goodOn(bool d) => d ? good : const Color(0xFF19733A);
  static Color amberOn(bool d) => d ? amber : const Color(0xFFEF9D14);

  /// the site's ease (cubic-bezier(.22, 1, .36, 1))
  static const Curve ease = Cubic(0.22, 1, 0.36, 1);

  static Color bg(bool d) => d ? const Color(0xFF1B1B1A) : const Color(0xFFE9E6E1);
  static Color ink(bool d) => d ? const Color(0xFFF6F5F2) : const Color(0xFF1C1B19);
  static Color muted(bool d) => d ? const Color(0xFFC9C6BF) : const Color(0xFF59554E);
  static Color card(bool d) => d ? const Color(0x66605F5B) : const Color(0x66FFFFFF);
  static Color rim(bool d) => d ? Colors.white.withOpacity(0.10) : Colors.white.withOpacity(0.80);
  static Color line(bool d) => d ? const Color(0x17FFFFFF) : const Color(0x171E1A14);
  static Color track(bool d) => d ? Colors.white.withOpacity(0.10) : const Color(0x1F1E1A14);

  /// the soft tile inside a card (Value / Rent / Yield)
  static BoxDecoration tile(bool d, {double r = 14}) => BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: d
              ? [Colors.white.withOpacity(0.075), Colors.white.withOpacity(0.03)]
              : [const Color(0xB8FFFFFF), const Color(0x6BFFFFFF)],
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
              : [const Color(0xC4FFFFFF), const Color(0x80FFFFFF), const Color(0x66FFFFFF)],
        ),
        borderRadius: BorderRadius.circular(r),
        border: Border.all(color: d ? Colors.white.withOpacity(0.11) : const Color(0xB3FFFFFF)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(d ? 0.35 : 0.08), blurRadius: 40, offset: const Offset(0, 18), spreadRadius: -22)],
      );
}

/// A blurred glass square. On a computer it lifts a little and its edge brightens under the mouse (like the site).
class GlassBox extends StatefulWidget {
  final Widget child;
  final bool isDark;
  final double radius;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  const GlassBox({super.key, required this.child, required this.isDark, this.radius = 20, this.padding = EdgeInsets.zero, this.onTap});

  @override
  State<GlassBox> createState() => _GlassBoxState();
}

class _GlassBoxState extends State<GlassBox> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.isDark;
    final box = AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      curve: Glass.ease,
      transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 350),
            curve: Glass.ease,
            decoration: Glass.panel(d, r: widget.radius).copyWith(
              border: Border.all(
                  color: _hover
                      ? (d ? Colors.white.withOpacity(0.24) : Colors.white)
                      : (d ? Colors.white.withOpacity(0.11) : const Color(0xB3FFFFFF))),
            ),
            child: Padding(padding: widget.padding, child: widget.child),
          ),
        ),
      ),
    );
    if (widget.onTap == null) return box;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(onTap: widget.onTap, behavior: HitTestBehavior.opaque, child: box),
    );
  }
}

/// The page backdrop: a soft, out-of-focus room behind a dark (or light) veil — the same for every page.
class AppBackdrop extends StatelessWidget {
  final bool isDark;
  const AppBackdrop({super.key, required this.isDark});

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Stack(fit: StackFit.expand, children: [
          ColoredBox(color: isDark ? const Color(0xFF2A2723) : const Color(0xFFE9E6E1)),
          Image.asset('assets/bg/backdrop.webp', fit: BoxFit.cover, filterQuality: FilterQuality.low, gaplessPlayback: true,
              errorBuilder: (_, __, ___) => const SizedBox.shrink()),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isDark ? const [Color(0xCC0C0C0B), Color(0xE6080807)] : const [Color(0x80F6F3EE), Color(0x9EECE8E2)],
              ),
            ),
          ),
        ]),
      );
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
            // grows in from the start, like the site's meters
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: value.clamp(0, 1).toDouble()),
              duration: const Duration(milliseconds: 900),
              curve: Glass.ease,
              builder: (_, v, __) => FractionallySizedBox(
                alignment: AlignmentDirectional.centerStart,
                widthFactor: v,
                child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8))),
              ),
            ),
          ]),
        ),
      );
}

/// Fades a block in and lifts it a little when it first shows (the cards of a list, one after the other).
class GlassEntrance extends StatelessWidget {
  final Widget child;
  final int index;
  const GlassEntrance({super.key, required this.child, this.index = 0});

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: 520 + (index.clamp(0, 8)) * 60),
        curve: Glass.ease,
        builder: (_, t, c) => Opacity(opacity: t, child: Transform.translate(offset: Offset(0, (1 - t) * 14), child: c)),
        child: child,
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

/// Moving between pages like the site: the new page fades in while rising a little (no sideways slide).
class GlassPageTransitions extends PageTransitionsBuilder {
  const GlassPageTransitions();

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    final a = CurvedAnimation(parent: animation, curve: Glass.ease, reverseCurve: Curves.easeInCubic);
    return FadeTransition(
      opacity: a,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.025), end: Offset.zero).animate(a),
        child: child,
      ),
    );
  }
}

/// The «Ardena» data colours as Material swatches, so every `Colors.green` / `.shade700` in the app now reads them.
class Ar {
  Ar._();
  /// good / money in (their #4fcf73)
  static const MaterialColor green = MaterialColor(0xFF4FCF73, <int, Color>{50: Color(0xFFEAF9EE), 100: Color(0xFFD5F3DD), 200: Color(0xFFB5EBC4), 300: Color(0xFF92E1A8), 400: Color(0xFF6FD88C), 500: Color(0xFF4FCF73), 600: Color(0xFF46B665), 700: Color(0xFF3C9D57), 800: Color(0xFF33844A), 900: Color(0xFF296C3C)});
  /// bad / late / refused (their #ff7d6e)
  static const MaterialColor red = MaterialColor(0xFFFF7D6E, <int, Color>{50: Color(0xFFFFEFEE), 100: Color(0xFFFFE0DC), 200: Color(0xFFFFC8C2), 300: Color(0xFFFFAEA5), 400: Color(0xFFFF9488), 500: Color(0xFFFF7D6E), 600: Color(0xFFE06E61), 700: Color(0xFFC25F54), 800: Color(0xFFA35046), 900: Color(0xFF854139)});
  /// warning / pending (their #f7a928)
  static const MaterialColor amber = MaterialColor(0xFFF7A928, <int, Color>{50: Color(0xFFFEF5E5), 100: Color(0xFFFDEACB), 200: Color(0xFFFCDBA5), 300: Color(0xFFFACA7A), 400: Color(0xFFF8B84F), 500: Color(0xFFF7A928), 600: Color(0xFFD99523), 700: Color(0xFFBC801E), 800: Color(0xFF9E6C1A), 900: Color(0xFF805815)});
  /// our blue (their orange accent)
  static const MaterialColor accent = MaterialColor(0xFF6A67F5, <int, Color>{50: Color(0xFFEDEDFE), 100: Color(0xFFDBDBFD), 200: Color(0xFFC0BFFB), 300: Color(0xFFA3A1F9), 400: Color(0xFF8582F7), 500: Color(0xFF6A67F5), 600: Color(0xFF5D5BD8), 700: Color(0xFF514EBA), 800: Color(0xFF44429D), 900: Color(0xFF37367F)});
  /// info / neutral data (their #7fb4e8)
  static const MaterialColor info = MaterialColor(0xFF7FB4E8, <int, Color>{50: Color(0xFFF0F6FC), 100: Color(0xFFE0EDF9), 200: Color(0xFFC9E0F5), 300: Color(0xFFB0D0F1), 400: Color(0xFF96C2EC), 500: Color(0xFF7FB4E8), 600: Color(0xFF709ECC), 700: Color(0xFF6189B0), 800: Color(0xFF517394), 900: Color(0xFF425E79)});
  /// the sixth data colour (their #c99a76)
  static const MaterialColor tan = MaterialColor(0xFFC99A76, <int, Color>{50: Color(0xFFF9F3EF), 100: Color(0xFFF2E7DE), 200: Color(0xFFE8D5C5), 300: Color(0xFFDEC0AA), 400: Color(0xFFD3AC8F), 500: Color(0xFFC99A76), 600: Color(0xFFB18868), 700: Color(0xFF99755A), 800: Color(0xFF81634C), 900: Color(0xFF69503D)});
  /// warm stone greys instead of the cool Material greys
  static const MaterialColor grey = MaterialColor(0xFF8F8B84, <int, Color>{50: Color(0xFFFAF9F7), 100: Color(0xFFF2F0EC), 200: Color(0xFFE6E3DE), 300: Color(0xFFD6D2CB), 400: Color(0xFFB3AEA6), 500: Color(0xFF8F8B84), 600: Color(0xFF6F6B65), 700: Color(0xFF57534E), 800: Color(0xFF3A3835), 900: Color(0xFF22211F)});
}
