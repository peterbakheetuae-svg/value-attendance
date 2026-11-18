import 'package:jph_real_estate_hr/design/glass_perf.dart';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text;
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';

import 'glass_ui.dart';

/// A notification while the app is open: a glass card that slides down at the top of the screen (the app's own look,
/// not the system's), goes away by itself after a few seconds or with a swipe to the right / left, and a tap opens
/// what it is about (the leave request, the lead on the sales board, the task …).
class TopBanner {
  TopBanner._();

  static OverlayEntry? _entry;
  static Timer? _timer;

  /// [icon] / [color]: by the notification's kind; [onTap]: open what it is about.
  static void show(
    OverlayState overlay, {
    required String title,
    String body = '',
    IconData icon = Icons.notifications_active_rounded,
    Color color = Glass.blue,
    VoidCallback? onTap,
    Duration duration = const Duration(seconds: 6),
  }) {
    hide();
    final key = GlobalKey<_BannerState>();
    _entry = OverlayEntry(
      builder: (_) => _Banner(
        key: key,
        title: title,
        body: body,
        icon: icon,
        color: color,
        onTap: onTap == null
            ? null
            : () {
                hide();
                onTap();
              },
        onGone: hide,
      ),
    );
    overlay.insert(_entry!);
    _timer = Timer(duration, () => key.currentState?.slideAway() ?? hide());
  }

  static void hide() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }
}

class _Banner extends StatefulWidget {
  final String title, body;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  final VoidCallback onGone;
  const _Banner({super.key, required this.title, required this.body, required this.icon, required this.color,
      required this.onTap, required this.onGone});

  @override
  State<_Banner> createState() => _BannerState();
}

class _BannerState extends State<_Banner> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 320))..forward();
  late final Animation<Offset> _slide =
      Tween(begin: const Offset(0, -1.3), end: Offset.zero).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));

  Future<void> slideAway() async {
    if (!mounted) return;
    await _c.reverse();
    widget.onGone();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = Theme.of(context).brightness == Brightness.dark;
    final top = MediaQuery.of(context).padding.top;
    final wide = MediaQuery.of(context).size.width > 700;
    return Positioned(
      top: top + 10,
      left: 12,
      right: 12,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: wide ? 460 : double.infinity),
          child: SlideTransition(
            position: _slide,
            child: Dismissible(
              key: const ValueKey('top-banner'),
              direction: DismissDirection.horizontal,
              onDismissed: (_) => widget.onGone(),
              child: Material(
                type: MaterialType.transparency,
                child: GestureDetector(
                  onTap: widget.onTap,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: GlassBlur(
                      filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: Container(
                        decoration: Glass.panel(d, r: 20).copyWith(
                          color: Glass.card(d).withOpacity(d ? 0.86 : 0.9),
                        ),
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(colors: [widget.color.withOpacity(0.85), widget.color]),
                            ),
                            child: Icon(widget.icon, color: Colors.white, size: 22),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(widget.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: Glass.ink(d))),
                              if (widget.body.isNotEmpty) ...[
                                const SizedBox(height: 3),
                                Text(widget.body,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 13, color: Glass.muted(d))),
                              ],
                            ]),
                          ),
                          if (widget.onTap != null) ...[
                            const SizedBox(width: 6),
                            Icon(Icons.arrow_forward_ios_rounded, size: 16, color: Glass.muted(d)),
                          ],
                        ]),
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
