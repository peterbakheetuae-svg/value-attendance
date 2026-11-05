import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui_widgets.dart';

/// OTP verification — the "Secure Vault Access" motion (digit pills → digits orbit and spin into the
/// center → loading ring with a 0–100 counter → success flash, bubbles, confetti, check drawn, badge pop;
/// shake + red pills on a wrong code, then it resets by itself), inside the app's glass card and background.
class OtpPage extends StatefulWidget {
  final String identifier;
  final String sentTo;
  const OtpPage({super.key, required this.identifier, this.sentTo = ''});

  @override
  State<OtpPage> createState() => _OtpPageState();
}

enum _Stage { input, orbit, loading, success, error }

class _OtpPageState extends State<OtpPage> with TickerProviderStateMixin {
  static const _len = 4;
  static const _green = Color(0xFF10B981);
  static const _red = Color(0xFFF43F5E);
  final _ctrls = List.generate(_len, (_) => TextEditingController());
  final _nodes = List.generate(_len, (_) => FocusNode());
  _Stage _stage = _Stage.input;
  String? _errorText;
  int _resendIn = 60;
  Timer? _timer;
  Timer? _resetTimer;
  List<String> _orbitDigits = const [];
  final _rnd = math.Random();
  List<_Confetti> _confetti = const [];

  late final AnimationController _enter = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..forward();
  late final AnimationController _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
  late final AnimationController _orbit = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();
  late final AnimationController _percent = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
  late final AnimationController _success = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));

  @override
  void initState() {
    super.initState();
    _startTimer();
    Future.delayed(const Duration(milliseconds: 300), () { if (mounted) _nodes.first.requestFocus(); });
  }

  void _startTimer() {
    _timer?.cancel();
    setState(() => _resendIn = 60);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _resendIn--);
      if (_resendIn <= 0) t.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _resetTimer?.cancel();
    for (final c in _ctrls) c.dispose();
    for (final n in _nodes) n.dispose();
    for (final c in [_enter, _shake, _orbit, _spin, _pulse, _percent, _success]) c.dispose();
    super.dispose();
  }

  String get _code => _ctrls.map((c) => c.text).join();
  bool get _busy => _stage == _Stage.orbit || _stage == _Stage.loading || _stage == _Stage.success;

  void _reset({bool focus = true}) {
    _resetTimer?.cancel();
    for (final c in _ctrls) c.clear();
    setState(() { _stage = _Stage.input; _errorText = null; });
    if (focus) _nodes.first.requestFocus();
  }

  void _onChanged(int i, String v) {
    if (_busy) return;
    if (_stage == _Stage.error) {
      _resetTimer?.cancel();
      setState(() { _stage = _Stage.input; _errorText = null; });
    }
    final digits = v.replaceAll(RegExp(r'\D'), '');
    if (digits.length > 1) {
      // pasted code: spread it across the pills
      for (var k = 0; k < _len; k++) {
        _ctrls[k].text = k < digits.length ? digits[k] : '';
      }
      _nodes[math.min(digits.length, _len) - 1].requestFocus();
    } else {
      _ctrls[i].text = digits;
      if (digits.isNotEmpty) {
        HapticFeedback.selectionClick();
        if (i < _len - 1) _nodes[i + 1].requestFocus();
      }
    }
    setState(() {});
    if (_code.length == _len) _verify();
  }

  Future<void> _verify() async {
    FocusScope.of(context).unfocus();
    _orbitDigits = _ctrls.map((c) => c.text).toList();
    setState(() => _stage = _Stage.orbit);
    final call = ApiService.post({'action': 'verify_otp', 'identifier': widget.identifier, 'code': _code});
    await _orbit.forward(from: 0);
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted) return;
    setState(() => _stage = _Stage.loading);
    final results = await Future.wait<Object?>([call, _percent.forward(from: 0)]);
    if (!mounted) return;
    final r = results.first as Map<String, dynamic>;
    if (r['success'] == true) {
      HapticFeedback.mediumImpact();
      _confetti = List.generate(24, (i) {
        final a = (i / 24) * math.pi * 2 + (_rnd.nextDouble() - 0.5) * 0.25;
        final d = 90 + _rnd.nextDouble() * 70;
        return _Confetti(Offset(math.cos(a) * d, math.sin(a) * d), _confettiColors[i % _confettiColors.length],
            6 + _rnd.nextDouble() * 10, i % 4, 0.07 + _rnd.nextDouble() * 0.1);
      });
      setState(() => _stage = _Stage.success);
      await _success.forward(from: 0);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      final done = await Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) => NewPasswordPage(resetToken: '${r['resetToken']}')));
      if (done == true && mounted) Navigator.of(context).pop(true);
    } else {
      HapticFeedback.heavyImpact();
      for (var k = 0; k < _len; k++) {
        _ctrls[k].text = k < _orbitDigits.length ? _orbitDigits[k] : '';
      }
      setState(() { _stage = _Stage.error; _errorText = '${r['message'] ?? 'الكود غلط، جرّب تاني'}'; });
      _shake.forward(from: 0);
      _resetTimer = Timer(const Duration(seconds: 2), () { if (mounted && _stage == _Stage.error) _reset(); });
    }
  }

  Future<void> _resend() async {
    final r = await ApiService.post({'action': 'forgot_password', 'identifier': widget.identifier});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${r['message'] ?? ''}'),
      backgroundColor: r['success'] == true ? Colors.green : Colors.red,
    ));
    if (r['success'] == true) { _startTimer(); _reset(); }
  }

  (String, String) get _texts => switch (_stage) {
        _Stage.loading || _Stage.orbit => ('جاري التحقق…', 'بنراجع الكود بأمان.'),
        _Stage.success => ('تم التحقق', 'تمام — هنكمّل لتغيير كلمة المرور…'),
        _Stage.error => ('التحقق فشل', 'الكود اللي كتبته مش صحيح.'),
        _Stage.input => ('اكتب كود التحقق', widget.sentTo.isNotEmpty
            ? 'اتبعتلك كود من 4 أرقام على ${widget.sentTo} — صالح 10 دقايق (بص في الـ Spam لو مش لاقيه).'
            : 'اتبعتلك كود من 4 أرقام على إيميلك المسجّل، صالح 10 دقايق.'),
      };

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<AppController>(context).isDark;
    final accent = isDark ? AppColors.primaryLight : AppColors.primary;
    final textMain = isDark ? Colors.white : const Color(0xFF1E1B4B);
    final muted = isDark ? Colors.white60 : const Color(0xFF64748B);
    final (title, subtitle) = _texts;

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: AnimatedBuilder(
              animation: Listenable.merge([_shake, _enter]),
              builder: (_, child) {
                // cardEnter + shake
                final t = _shake.value;
                final dx = t == 0 || t == 1 ? 0.0 : math.sin(t * math.pi * 8) * 6 * (1 - t);
                final e = Curves.easeOutCubic.transform(_enter.value);
                return Opacity(
                  opacity: e,
                  child: Transform.translate(offset: Offset(dx, 20 * (1 - e)), child: Transform.scale(scale: 0.98 + 0.02 * e, child: child)),
                );
              },
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(26),
                    boxShadow: [
                      if (_stage == _Stage.success) BoxShadow(color: _green.withOpacity(0.35), blurRadius: 40, spreadRadius: 2),
                      if (_stage == _Stage.error) BoxShadow(color: _red.withOpacity(0.25), blurRadius: 30),
                    ],
                  ),
                  child: GlassCard(
                    radius: 26,
                    padding: const EdgeInsets.fromLTRB(24, 36, 24, 24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: Text(title, key: ValueKey(title), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: textMain)),
                      ),
                      const SizedBox(height: 8),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: Text(subtitle, key: ValueKey(subtitle), textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 14, height: 1.5, color: muted)),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(height: 200, child: _stageView(accent, textMain, isDark)),
                      AnimatedOpacity(
                        duration: const Duration(milliseconds: 250),
                        opacity: _stage == _Stage.error ? 1 : 0,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(_errorText ?? ' ', textAlign: TextAlign.center,
                              style: const TextStyle(color: _red, fontWeight: FontWeight.w600)),
                        ),
                      ),
                      if (_stage != _Stage.success)
                        TextButton(
                          onPressed: _resendIn > 0 || _busy ? null : _resend,
                          child: Text.rich(TextSpan(children: [
                            TextSpan(text: 'ماوصلكش؟ ', style: TextStyle(color: muted)),
                            TextSpan(
                              text: _resendIn > 0 ? 'إعادة الإرسال بعد $_resendIn ث' : 'ابعت تاني',
                              style: TextStyle(color: _resendIn > 0 ? muted : accent, fontWeight: FontWeight.w700),
                            ),
                          ])),
                        ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _stageView(Color accent, Color textMain, bool isDark) {
    return Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
      // input pills (fade away when the orbit starts)
      IgnorePointer(
        ignoring: _busy,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 250),
          opacity: _stage == _Stage.input || _stage == _Stage.error ? 1 : 0,
          child: _pills(accent, textMain, isDark),
        ),
      ),
      if (_stage == _Stage.orbit) _orbitView(accent, textMain, isDark),
      if (_stage == _Stage.loading) _loadingView(accent, isDark),
      if (_stage == _Stage.success) _successView(),
    ]);
  }

  BoxDecoration _pillDeco({required Color border, required bool isDark, List<BoxShadow> shadow = const [], bool filled = false}) =>
      BoxDecoration(
        color: filled
            ? (isDark ? Colors.white.withOpacity(0.10) : Colors.white.withOpacity(0.55))
            : (isDark ? Colors.white.withOpacity(0.05) : Colors.white.withOpacity(0.30)),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border, width: 1.5),
        boxShadow: shadow,
      );

  Widget _pills(Color accent, Color textMain, bool isDark) {
    final err = _stage == _Stage.error;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < _len; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          SizedBox(
            width: 56,
            height: 64,
            child: AnimatedBuilder(
              animation: _nodes[i],
              builder: (_, __) {
                final focused = _nodes[i].hasFocus, filled = _ctrls[i].text.isNotEmpty;
                final border = err ? _red : (focused || filled) ? accent : (isDark ? Colors.white24 : Colors.black12);
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  curve: const Cubic(0.25, 0.1, 0.25, 1),
                  decoration: _pillDeco(border: border, isDark: isDark, filled: filled, shadow: [
                    if (focused && !err) BoxShadow(color: accent.withOpacity(0.25), spreadRadius: 3),
                    if (err) BoxShadow(color: _red.withOpacity(0.2), spreadRadius: 3),
                  ]),
                  alignment: Alignment.center,
                  child: TextField(
                    controller: _ctrls[i],
                    focusNode: _nodes[i],
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    cursorColor: accent,
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: textMain),
                    decoration: const InputDecoration(border: InputBorder.none, counterText: '', isCollapsed: true),
                    onChanged: (v) => _onChanged(i, v),
                    onTap: () {
                      if (_stage == _Stage.error) _reset(focus: false);
                      _ctrls[i].selection = TextSelection(baseOffset: 0, extentOffset: _ctrls[i].text.length);
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ]),
    );
  }

  /// The four digits fly out to a circle, the circle turns once, then they shrink into the center.
  Widget _orbitView(Color accent, Color textMain, bool isDark) {
    return AnimatedBuilder(
      animation: _orbit,
      builder: (_, __) {
        final t = _orbit.value;
        final turn = const Cubic(0.6, 0, 0.4, 1).transform(t);
        return Transform.rotate(
          angle: turn * 2 * math.pi,
          child: SizedBox(
            width: 200,
            height: 200,
            child: Stack(alignment: Alignment.center, children: [
              for (var i = 0; i < _len; i++)
                Builder(builder: (_) {
                  // per-node delay of 60 ms, keyframes 0 → 25% out → 75% out → 100% center
                  final local = ((t * 1600 - i * 60) / 1600).clamp(0.0, 1.0);
                  final a = (i / _len) * math.pi * 2 - math.pi / 2;
                  final target = Offset(math.cos(a) * 70, math.sin(a) * 70);
                  double k, scale, opacity = 1;
                  if (local < 0.25) {
                    k = const Cubic(0.34, 1.4, 0.64, 1).transform(local / 0.25);
                    scale = 1 + 0.05 * k;
                  } else if (local < 0.75) {
                    k = 1;
                    scale = 1.05 - 0.1 * ((local - 0.25) / 0.5);
                  } else {
                    final q = Curves.easeIn.transform((local - 0.75) / 0.25);
                    k = 1 - q;
                    scale = 0.95 - 0.65 * q;
                    opacity = 1 - q;
                  }
                  return Transform.translate(
                    offset: target * k,
                    child: Opacity(
                      opacity: opacity.clamp(0.0, 1.0),
                      child: Transform.scale(
                        scale: scale,
                        child: Container(
                          width: 56, height: 64,
                          alignment: Alignment.center,
                          decoration: _pillDeco(border: accent, isDark: isDark, filled: true,
                              shadow: [BoxShadow(color: accent.withOpacity(0.25), blurRadius: 12)]),
                          // keep digits upright while the ring turns
                          child: Transform.rotate(
                            angle: -turn * 2 * math.pi,
                            child: Text(i < _orbitDigits.length ? _orbitDigits[i] : '',
                                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: textMain)),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
            ]),
          ),
        );
      },
    );
  }

  /// Spinning conic ring + outward pulse + a 0 → 100 counter.
  Widget _loadingView(Color accent, bool isDark) {
    return AnimatedBuilder(
      animation: Listenable.merge([_spin, _pulse, _percent]),
      builder: (_, __) {
        final p = _percent.value;
        final shown = (1 - math.pow(1 - p, 2.2)) * 100;
        final morph = Curves.easeOutBack.transform((_percent.value * 6).clamp(0.0, 1.0));
        return Transform.scale(
          scale: 0.4 + 0.6 * morph,
          child: Transform.rotate(
            angle: (1 - morph) * -math.pi / 4,
            child: SizedBox(
              width: 120,
              height: 120,
              child: Stack(alignment: Alignment.center, children: [
                Opacity(
                  opacity: 0.55 * (1 - _pulse.value),
                  child: Transform.scale(
                    scale: 0.85 + 0.5 * _pulse.value,
                    child: Container(width: 100, height: 100,
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: accent))),
                  ),
                ),
                Transform.rotate(
                  angle: _spin.value * 2 * math.pi,
                  child: Container(
                    width: 72, height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: SweepGradient(colors: [Colors.transparent, accent, Colors.transparent], stops: const [0, 0.7, 1]),
                    ),
                  ),
                ),
                Container(
                  width: 58, height: 58,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: isDark ? const Color(0xFF18181B) : Colors.white),
                ),
                Container(
                  width: 44, height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isDark ? const Color(0xFF09090B) : const Color(0xFFFAFAFA),
                    border: Border.all(color: accent.withOpacity(0.25), width: 1.5),
                    boxShadow: [BoxShadow(color: accent.withOpacity(0.15), blurRadius: 12)],
                  ),
                  child: Text('${shown.round()}', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: accent)),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }

  double _seg(double t, double from, double len) => ((t - from) / len).clamp(0.0, 1.0);

  /// Flash, three bubbles, confetti splash, vault pops in, check is drawn, "Verified" badge pops.
  Widget _successView() {
    return AnimatedBuilder(
      animation: _success,
      builder: (_, __) {
        final ms = _success.value * 1500;
        final flash = _seg(ms, 0, 900);
        final pop = _seg(ms, 0, 700);
        final draw = const Cubic(0.65, 0, 0.35, 1).transform(_seg(ms, 300, 550));
        final badge = _seg(ms, 650, 550);
        return SizedBox(
          width: 260,
          height: 200,
          child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
            // flash
            Opacity(
              opacity: (flash < 0.4 ? flash / 0.4 : (1 - flash) / 0.6).clamp(0.0, 1.0),
              child: Transform.scale(
                scale: flash < 0.4 ? 0.4 + 0.6 * (flash / 0.4) : 1 + 0.4 * ((flash - 0.4) / 0.6),
                child: Container(
                  width: 200, height: 200,
                  decoration: const BoxDecoration(shape: BoxShape.circle,
                      gradient: RadialGradient(colors: [Color(0x8C10B981), Color(0x2610B981), Colors.transparent], stops: [0, 0.4, 0.7])),
                ),
              ),
            ),
            // bubbles
            for (final d in const [0.0, 150.0, 300.0])
              Builder(builder: (_) {
                final k = Curves.easeOutCubic.transform(_seg(ms, d, 1400 - d * 0.5));
                return Opacity(
                  opacity: (k < 0.1 ? k * 8 : 1 - k).clamp(0.0, 0.8),
                  child: Transform.scale(
                    scale: 0.2 + 3.4 * k,
                    child: Container(width: 40, height: 40,
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: _green, width: 2))),
                  ),
                );
              }),
            // confetti splash
            for (final c in _confetti)
              Builder(builder: (_) {
                final k = _seg(ms, c.delay * 1000, 1300);
                if (k <= 0) return const SizedBox.shrink();
                final e = Curves.easeOutCubic.transform(k);
                final pos = k < 0.2 ? c.to * (0.3 * (k / 0.2)) : c.to * (0.3 + 0.7 * ((e - 0.2) / 0.8).clamp(0.0, 1.0));
                final sc = k < 0.2 ? 0.4 + 0.8 * (k / 0.2) : 1.2 - 0.6 * ((k - 0.2) / 0.8);
                return Transform.translate(
                  offset: pos,
                  child: Opacity(
                    opacity: k < 0.2 ? 1 : (1 - (k - 0.2) / 0.8).clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale: sc,
                      child: Container(
                        width: c.size, height: c.size,
                        decoration: BoxDecoration(
                          color: c.color,
                          borderRadius: c.shape == 0
                              ? BorderRadius.circular(2)
                              : c.shape == 1
                                  ? BorderRadius.only(topLeft: Radius.circular(c.size), bottomRight: Radius.circular(c.size))
                                  : BorderRadius.circular(c.size),
                          boxShadow: [BoxShadow(color: c.color.withOpacity(0.8), blurRadius: 12)],
                        ),
                      ),
                    ),
                  ),
                );
              }),
            // vault + drawn check (popIn: scale 0 → 1.25 → 0.95 → 1, rotate -180° → 12° → -4° → 0)
            Builder(builder: (_) {
              double sc, rot;
              if (pop < 0.5) { final q = Curves.easeOut.transform(pop / 0.5); sc = 1.25 * q; rot = -180 + 192 * q; }
              else if (pop < 0.75) { final q = (pop - 0.5) / 0.25; sc = 1.25 - 0.3 * q; rot = 12 - 16 * q; }
              else { final q = (pop - 0.75) / 0.25; sc = 0.95 + 0.05 * q; rot = -4 + 4 * q; }
              return Transform.rotate(
                angle: rot * math.pi / 180,
                child: Transform.scale(
                  scale: sc,
                  child: Container(
                    width: 68, height: 68,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                          colors: [Color(0xFF34D399), _green, Color(0xFF059669)], stops: [0, 0.55, 1]),
                      boxShadow: [
                        BoxShadow(color: _green.withOpacity(0.18), spreadRadius: 8),
                        BoxShadow(color: _green.withOpacity(0.35), blurRadius: 50),
                      ],
                    ),
                    child: CustomPaint(painter: _CheckPainter(draw)),
                  ),
                ),
              );
            }),
            // badge
            Positioned(
              bottom: 6,
              child: Opacity(
                opacity: badge,
                child: Transform.translate(
                  offset: Offset(0, 14 * (1 - Curves.easeOutBack.transform(badge))),
                  child: Transform.scale(
                    scale: 0.8 + 0.2 * Curves.easeOutBack.transform(badge),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(color: _green.withOpacity(0.15), borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: _green.withOpacity(0.35))),
                      child: const Text('تم التحقق', style: TextStyle(color: _green, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ),
            ),
          ]),
        );
      },
    );
  }
}

const _confettiColors = [
  Color(0xFF10B981), Color(0xFF34D399), Color(0xFF6EE7B7), Color(0xFF6366F1),
  Color(0xFFA78BFA), Color(0xFFFBBF24), Color(0xFFF472B6), Color(0xFF22D3EE),
];

class _Confetti {
  final Offset to;
  final Color color;
  final double size;
  final int shape;
  final double delay; // seconds
  const _Confetti(this.to, this.color, this.size, this.shape, this.delay);
}

/// The check mark drawn progressively (polyline 20,6 → 9,17 → 4,12 on a 24×24 grid).
class _CheckPainter extends CustomPainter {
  final double progress;
  _CheckPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final s = size.width / 24 * 0.6, o = Offset(size.width * 0.2, size.height * 0.2);
    Offset p(double x, double y) => o + Offset(x * s, y * s);
    final path = Path()..moveTo(p(4, 12).dx, p(4, 12).dy)..lineTo(p(9, 17).dx, p(9, 17).dy)..lineTo(p(20, 6).dx, p(20, 6).dy);
    final metric = path.computeMetrics().first;
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(metric.extractPath(0, metric.length * progress), paint);
  }

  @override
  bool shouldRepaint(covariant _CheckPainter old) => old.progress != progress;
}

/// Step 3: choose the new password (same glass look).
class NewPasswordPage extends StatefulWidget {
  final String resetToken;
  const NewPasswordPage({super.key, required this.resetToken});

  @override
  State<NewPasswordPage> createState() => _NewPasswordPageState();
}

class _NewPasswordPageState extends State<NewPasswordPage> {
  final _pw = TextEditingController();
  final _confirm = TextEditingController();
  bool _hide = true;
  bool _loading = false;
  String? _err;

  Future<void> _save() async {
    if (_pw.text.length < 8) { setState(() => _err = 'كلمة المرور لازم 8 حروف على الأقل وفيها حرف ورقم'); return; }
    if (_pw.text != _confirm.text) { setState(() => _err = 'كلمتين المرور مش زي بعض'); return; }
    setState(() { _loading = true; _err = null; });
    final r = await ApiService.post({'action': 'reset_password', 'resetToken': widget.resetToken, 'newPassword': _pw.text});
    if (!mounted) return;
    setState(() => _loading = false);
    if (r['success'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${r['message']}'), backgroundColor: Colors.green));
      Navigator.of(context).pop(true);
    } else {
      setState(() => _err = '${r['message'] ?? ''}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<AppController>(context).isDark;
    final accent = isDark ? AppColors.primaryLight : AppColors.primary;
    InputDecoration dec(String l) => InputDecoration(
          labelText: l,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          suffixIcon: IconButton(icon: Icon(_hide ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _hide = !_hide)),
        );
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: GlassCard(
              radius: 26,
              padding: const EdgeInsets.fromLTRB(24, 36, 24, 28),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Icon(Icons.lock_reset_rounded, size: 48, color: accent),
                const SizedBox(height: 12),
                const Text('كلمة مرور جديدة', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                const SizedBox(height: 20),
                TextField(controller: _pw, obscureText: _hide, decoration: dec('كلمة المرور الجديدة')),
                const SizedBox(height: 12),
                TextField(controller: _confirm, obscureText: _hide, decoration: dec('تأكيد كلمة المرور')),
                if (_err != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_err!, style: const TextStyle(color: Color(0xFFF43F5E)))),
                const SizedBox(height: 20),
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: accent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                    onPressed: _loading ? null : _save,
                    child: _loading
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Text('حفظ', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
                  ),
                ),
              ]),
            ),
            ),
          ),
        ),
      ),
    );
  }
}
