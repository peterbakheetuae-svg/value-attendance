import 'package:jph_real_estate_hr/design/glass_perf.dart';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';

import '../../core/ring_alert.dart';

/// «Valunivo Call» — an alert that looks like an incoming call, over the lock screen:
///  • 'checkin': the employee checked in on another phone of his account → «ابدأ عملك الآن» (opening the app here starts
///    this phone's follow-up during work);
///  • 'exit': he left the office with no approved permission → «خرجت بدون إذن».
/// Swiping ANY of the three buttons up answers it: the ringing stops and the app opens (nothing else happens).
class IncomingCall {
  IncomingCall._();
  static bool _open = false;

  /// a call ringing / that opened the app → its screen (safe to call often: on start, on resume)
  static Future<void> check(GlobalKey<NavigatorState> nav) async {
    final kind = await RingAlert.pendingCall();
    if (kind != null) await show(nav, kind);
  }

  static final Map<String, DateTime> _answered = {};

  static Future<void> show(GlobalKey<NavigatorState> nav, String kind) async {
    final state = nav.currentState;
    if (_open || state == null) return;
    // the same alarm told twice (the phone's own ring + the server's) is answered once
    final last = _answered[kind];
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 2)) {
      await RingAlert.endCalls();
      return;
    }
    _open = true;
    try {
      await state.push(PageRouteBuilder<void>(
        opaque: true,
        fullscreenDialog: true,
        transitionDuration: const Duration(milliseconds: 250),
        pageBuilder: (_, __, ___) => IncomingCallPage(kind: kind),
        transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
      ));
    } finally {
      _open = false;
      _answered[kind] = DateTime.now();
    }
  }
}

class IncomingCallPage extends StatefulWidget {
  final String kind;
  const IncomingCallPage({super.key, required this.kind});

  @override
  State<IncomingCallPage> createState() => _IncomingCallPageState();
}

class _IncomingCallPageState extends State<IncomingCallPage> with SingleTickerProviderStateMixin {
  final AudioPlayer _player = AudioPlayer();
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  Timer? _buzz;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    // the notification stops ringing; the screen rings instead until it is answered
    RingAlert.endCalls();
    _ring();
  }

  Future<void> _ring() async {
    try {
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(AssetSource('sounds/notification.mp3'));
    } catch (_) {}
    _buzz = Timer.periodic(const Duration(milliseconds: 1600), (_) => HapticFeedback.heavyImpact());
  }

  Future<void> _answer() async {
    if (_done) return;
    _done = true;
    _buzz?.cancel();
    try { await _player.stop(); } catch (_) {}
    await RingAlert.endCalls();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _buzz?.cancel();
    _pulse.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final exit = widget.kind == 'exit';
    return PopScope(
      canPop: false, // only answering closes it
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: const Color(0xFF0E1015),
          body: Stack(fit: StackFit.expand, children: [
            Image.asset('assets/bg/dark_bg.webp', fit: BoxFit.cover, color: Colors.black.withOpacity(0.45), colorBlendMode: BlendMode.darken),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors: [Color(0x330E1015), Color(0x000E1015), Color(0xCC0E1015)]),
              ),
            ),
            SafeArea(
              child: Column(children: [
                const SizedBox(height: 36),
                _logo(),
                const SizedBox(height: 22),
                _wordmark(),
                const SizedBox(height: 10),
                const Text('Valunivo Call', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w500)),
                const SizedBox(height: 10),
                Text(exit ? 'خرجت بدون إذن' : 'ابدأ عملك الآن',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: exit ? const Color(0xFFFF8A7A) : Colors.white, fontSize: 30, fontWeight: FontWeight.w600)),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 34),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    _SwipeButton(
                      size: 74,
                      color: Colors.white.withOpacity(0.16),
                      icon: Icons.chat_bubble_outline_rounded,
                      iconColor: Colors.white70,
                      label: 'الرسالة',
                      onAnswer: _answer,
                    ),
                    _SwipeButton(
                      size: 96,
                      color: const Color(0xFF3DB57A),
                      icon: Icons.call_rounded,
                      iconColor: Colors.white,
                      label: 'التمرير لأعلى للرد',
                      onAnswer: _answer,
                      pulse: _pulse,
                    ),
                    _SwipeButton(
                      size: 74,
                      color: const Color(0xFF6B1D24),
                      icon: Icons.call_end_rounded,
                      iconColor: const Color(0xFFFF5A5F),
                      label: 'رفض',
                      onAnswer: _answer,
                    ),
                  ]),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _logo() => ClipOval(
        child: GlassBlur(
          filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            width: 132,
            height: 132,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(0.14),
              border: Border.all(color: Colors.white.withOpacity(0.35), width: 1.5),
            ),
            child: Image.asset('assets/images/login_logo.png', fit: BoxFit.contain, filterQuality: FilterQuality.medium),
          ),
        ),
      );

  // the VALUNIVO wordmark: brushed silver
  Widget _wordmark() => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (r) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFFFFF), Color(0xFFD9DCE1), Color(0xFF9CA1AA), Color(0xFFE9EBEE)],
          stops: [0, 0.45, 0.55, 1],
        ).createShader(r),
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('VALUNIVO',
              style: TextStyle(fontSize: 46, fontWeight: FontWeight.w800, letterSpacing: 4, height: 1,
                  shadows: [Shadow(color: Color(0x99000000), blurRadius: 8, offset: Offset(0, 3))])),
        ),
      );
}

/// a call button that answers when dragged up (any of the three): the chevrons above it show the way
class _SwipeButton extends StatefulWidget {
  final double size;
  final Color color, iconColor;
  final IconData icon;
  final String label;
  final VoidCallback onAnswer;
  final AnimationController? pulse;
  const _SwipeButton({required this.size, required this.color, required this.icon, required this.iconColor,
      required this.label, required this.onAnswer, this.pulse});

  @override
  State<_SwipeButton> createState() => _SwipeButtonState();
}

class _SwipeButtonState extends State<_SwipeButton> {
  double _dy = 0; // how far it was dragged up (negative)
  static const _answerAt = 90.0;

  void _end() {
    if (-_dy >= _answerAt) {
      widget.onAnswer();
    } else {
      setState(() => _dy = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final lift = (-_dy).clamp(0.0, 160.0);
    Widget circle = Container(
      width: s,
      height: s,
      decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color,
          boxShadow: [BoxShadow(color: widget.color.withOpacity(0.45), blurRadius: 18)]),
      child: Icon(widget.icon, color: widget.iconColor, size: s * 0.4),
    );
    final p = widget.pulse;
    if (p != null) {
      circle = AnimatedBuilder(
        animation: p,
        builder: (_, child) => Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
          Container(
            width: s * (1 + 0.35 * p.value),
            height: s * (1 + 0.35 * p.value),
            decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color.withOpacity(0.35 * (1 - p.value))),
          ),
          child!,
        ]),
        child: circle,
      );
    }
    return SizedBox(
      width: s + 40,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Opacity(
          opacity: (1 - lift / _answerAt).clamp(0.0, 1.0),
          child: const Icon(Icons.keyboard_double_arrow_up_rounded, color: Colors.white38, size: 28),
        ),
        const SizedBox(height: 8),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: (d) => setState(() => _dy = (_dy + d.delta.dy).clamp(-160.0, 0.0)),
          onVerticalDragEnd: (_) => _end(),
          onVerticalDragCancel: () => setState(() => _dy = 0),
          child: Transform.translate(offset: Offset(0, -lift), child: circle),
        ),
        const SizedBox(height: 14),
        Text(widget.label, textAlign: TextAlign.center, maxLines: 2,
            style: const TextStyle(color: Colors.white70, fontSize: 14)),
      ]),
    );
  }
}
