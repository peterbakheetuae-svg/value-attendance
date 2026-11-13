import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The «Ardena» glass look (the reference the owner picked): warm smoked-glass squares, soft inner tiles,
/// pill segments and meters — in the site's own colours, its orange included.
class Glass {
  Glass._();

  // the site's orange: fills (#d4401a) and the bright accent (#ff6a3d)
  static const Color blue = Color(0xFFD4401A);
  static const Color blueHi = Color(0xFFFF6A3D);
  static const Color accentText = Color(0xFFFF8A63);
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

  /// a form / sheet over a page: frosted almost solid (the page under it must not show through)
  static BoxDecoration sheet(bool d, {double r = 24}) => BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: d ? const [Color(0xF72D2C29), Color(0xFA232220)] : const [Color(0xFAFFFFFF), Color(0xF7F4F2EE)],
        ),
        borderRadius: BorderRadius.circular(r),
        border: Border.all(color: d ? Colors.white.withOpacity(0.10) : Colors.white),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(d ? 0.5 : 0.18), blurRadius: 40, offset: const Offset(0, -6))],
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
          // the photo exactly as supplied (no veil in it), a touch larger like the site (scale 1.08)
          Transform.scale(
            scale: 1.08,
            child: Image.asset('assets/bg/site_backdrop.jpeg', fit: BoxFit.cover, filterQuality: FilterQuality.medium, gaplessPlayback: true,
                errorBuilder: (_, __, ___) => const SizedBox.shrink()),
          ),
          // the site's own veil on top of it: dark (#0c0c0b 80% → #080807 90%) or light (#f6f3ee 50% → #ece8e2 62%)
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

/// Pill segments (Holdings / Rent roll / Loans — Value / Yield / Growth): the chosen one filled with the orange.
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
            padding: EdgeInsets.symmetric(horizontal: big ? 14 : 13, vertical: big ? 8.5 : 11), // the site: 36px tabs, 40px segments
            decoration: BoxDecoration(
              color: on ? (big ? Glass.blue : (isDark ? Colors.white.withOpacity(0.12) : Colors.white)) : Colors.transparent,
              borderRadius: BorderRadius.circular(99),
              boxShadow: on && big ? [BoxShadow(color: Glass.blue.withOpacity(0.35), blurRadius: 14, offset: const Offset(0, 5))] : null,
            ),
            child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(label,
                  style: TextStyle(
                      fontSize: big ? 13.5 : 12.5,
                      fontWeight: FontWeight.w600,
                      color: on ? (big ? Colors.white : Glass.ink(isDark)) : Glass.ink(isDark).withOpacity(0.85))),
              if (count != null && count > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: (on ? Colors.white : Glass.ink(isDark)).withOpacity(0.18), borderRadius: BorderRadius.circular(99)),
                  child: Text('$count', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: on ? Colors.white : Glass.ink(isDark))),
                ),
              ],
            ]),
          ),
        ),
      );
    }

    return Container(
      padding: EdgeInsets.all(big ? 4 : 3),
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11), // 40px
            decoration: BoxDecoration(
              color: on ? Glass.blue : (isDark ? Colors.white.withOpacity(0.06) : Colors.white.withOpacity(0.55)),
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: on ? Colors.transparent : Glass.rim(isDark)),
            ),
            child: Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: on ? Colors.white : Glass.ink(isDark))),
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: Glass.tile(isDark, r: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Glass.muted(isDark))),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: CountUpText(value, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: color ?? Glass.ink(isDark))),
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
  /// the site's orange accent (#ff6a3d; fills #d4401a)
  static const MaterialColor accent = MaterialColor(0xFFFF6A3D, <int, Color>{50: Color(0xFFFFF0EB), 100: Color(0xFFFFE3D8), 200: Color(0xFFFFC8B5), 300: Color(0xFFFFA98D), 400: Color(0xFFFF8A63), 500: Color(0xFFFF6A3D), 600: Color(0xFFE04B22), 700: Color(0xFFD4401A), 800: Color(0xFFA93214), 900: Color(0xFF7A240E)});
  /// info / neutral data (their #7fb4e8)
  static const MaterialColor info = MaterialColor(0xFF7FB4E8, <int, Color>{50: Color(0xFFF0F6FC), 100: Color(0xFFE0EDF9), 200: Color(0xFFC9E0F5), 300: Color(0xFFB0D0F1), 400: Color(0xFF96C2EC), 500: Color(0xFF7FB4E8), 600: Color(0xFF709ECC), 700: Color(0xFF6189B0), 800: Color(0xFF517394), 900: Color(0xFF425E79)});
  /// the sixth data colour (their #c99a76)
  static const MaterialColor tan = MaterialColor(0xFFC99A76, <int, Color>{50: Color(0xFFF9F3EF), 100: Color(0xFFF2E7DE), 200: Color(0xFFE8D5C5), 300: Color(0xFFDEC0AA), 400: Color(0xFFD3AC8F), 500: Color(0xFFC99A76), 600: Color(0xFFB18868), 700: Color(0xFF99755A), 800: Color(0xFF81634C), 900: Color(0xFF69503D)});
  /// warm stone greys instead of the cool Material greys
  static const MaterialColor grey = MaterialColor(0xFF8F8B84, <int, Color>{50: Color(0xFFFAF9F7), 100: Color(0xFFF2F0EC), 200: Color(0xFFE6E3DE), 300: Color(0xFFD6D2CB), 400: Color(0xFFB3AEA6), 500: Color(0xFF8F8B84), 600: Color(0xFF6F6B65), 700: Color(0xFF57534E), 800: Color(0xFF3A3835), 900: Color(0xFF22211F)});
}

/// A number that counts up to its value (1.2 s, the site's ease) and tweens again when it changes — like the
/// dashboard's figures. Works on any text with a number in it ("12,500 ج", "3.5٪", "8 / 10"): the first number moves,
/// the rest of the text stays.
class CountUpText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;
  final TextDirection? textDirection;
  const CountUpText(this.text, {super.key, this.style, this.textAlign, this.maxLines, this.overflow, this.softWrap, this.textDirection});

  @override
  State<CountUpText> createState() => _CountUpTextState();
}

class _CountUpTextState extends State<CountUpText> {
  static final _num = RegExp(r'-?\d[\d,]*(?:\.\d+)?');
  double _from = 0;

  double? _value(String t) {
    final m = _num.firstMatch(t);
    return m == null ? null : double.tryParse(m.group(0)!.replaceAll(',', ''));
  }

  @override
  void didUpdateWidget(covariant CountUpText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _from = _value(old.text) ?? 0;
  }

  Text _text(String t) => Text(t,
      style: widget.style,
      textAlign: widget.textAlign,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      softWrap: widget.softWrap,
      textDirection: widget.textDirection);

  @override
  Widget build(BuildContext context) {
    final m = _num.firstMatch(widget.text);
    final end = m == null ? null : double.tryParse(m.group(0)!.replaceAll(',', ''));
    if (m == null || end == null || end == _from) return _text(widget.text);
    final raw = m.group(0)!;
    // times, dates, phones and codes stay as they are (09:30, 13/11/2026, 0100…)
    if (RegExp(r'[:/]').hasMatch(widget.text) || (raw.length > 1 && raw.startsWith('0') && !raw.startsWith('0.'))) {
      return _text(widget.text);
    }
    final decimals = raw.contains('.') ? raw.split('.').last.length : 0;
    final grouped = raw.contains(',');
    String fmt(double v) {
      var s = v.abs().toStringAsFixed(decimals);
      if (grouped) {
        final parts = s.split('.');
        final i = parts.first;
        final b = StringBuffer();
        for (var k = 0; k < i.length; k++) {
          if (k > 0 && (i.length - k) % 3 == 0) b.write(',');
          b.write(i[k]);
        }
        s = parts.length > 1 ? '$b.${parts[1]}' : '$b';
      }
      return '${v < 0 ? '-' : ''}$s';
    }

    return TweenAnimationBuilder<double>(
      key: ValueKey(widget.text),
      tween: Tween(begin: _from, end: end),
      duration: const Duration(milliseconds: 1200),
      curve: Glass.ease,
      builder: (_, v, __) => _text(widget.text.replaceRange(m.start, m.end, fmt(v))),
    );
  }
}

/// Any bar / ring value that fills from the start like the dashboard's bars (1 s, the site's ease).
class GrowTo extends StatelessWidget {
  final double value;
  final Widget Function(double v) builder;
  const GrowTo({super.key, required this.value, required this.builder});

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: value.isNaN ? 0 : value),
        duration: const Duration(milliseconds: 1000),
        curve: Glass.ease,
        builder: (_, v, __) => builder(v),
      );
}

/// Squares that keep their size on a wide screen: as many per row as fit (between [minCols] and [maxCols]),
/// one under the other on a phone. Rows keep each square's own height.
class ResponsiveGrid extends StatelessWidget {
  final List<Widget> children;
  final double minTileWidth;
  final int minCols, maxCols;
  final double spacing;
  const ResponsiveGrid({super.key, required this.children, this.minTileWidth = 220, this.minCols = 1, this.maxCols = 5, this.spacing = 12});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final cols = ((c.maxWidth + spacing) / (minTileWidth + spacing)).floor().clamp(minCols, maxCols);
        final w = (c.maxWidth - spacing * (cols - 1)) / cols;
        return Wrap(spacing: spacing, runSpacing: spacing, children: [for (final x in children) SizedBox(width: w, child: x)]);
      });
}
