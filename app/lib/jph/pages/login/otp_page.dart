import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';

/// OTP verification — the "Secure Vault Access" design (glass card, digit pills, orbit → loading ring →
/// success check with bubbles, shake on error, resend countdown), in the app's colors and background.
class OtpPage extends StatefulWidget {
  final String identifier;
  const OtpPage({super.key, required this.identifier});

  @override
  State<OtpPage> createState() => _OtpPageState();
}

enum _Stage { input, loading, success }

class _OtpPageState extends State<OtpPage> with TickerProviderStateMixin {
  static const _len = 6;
  final _ctrls = List.generate(_len, (_) => TextEditingController());
  final _nodes = List.generate(_len, (_) => FocusNode());
  _Stage _stage = _Stage.input;
  bool _error = false;
  String? _errorText;
  int _resendIn = 60;
  Timer? _timer;
  late final AnimationController _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();
  late final AnimationController _success = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  late final AnimationController _enter = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..forward();

  @override
  void initState() {
    super.initState();
    _startTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) => _nodes.first.requestFocus());
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
    for (final c in _ctrls) c.dispose();
    for (final n in _nodes) n.dispose();
    _shake.dispose();
    _spin.dispose();
    _success.dispose();
    _enter.dispose();
    super.dispose();
  }

  String get _code => _ctrls.map((c) => c.text).join();

  void _onChanged(int i, String v) {
    if (_error) setState(() { _error = false; _errorText = null; });
    final digits = v.replaceAll(RegExp(r'\D'), '');
    if (digits.length > 1) {
      // pasted code: spread it across the boxes
      for (var k = 0; k < _len; k++) {
        _ctrls[k].text = k < digits.length ? digits[k] : '';
      }
      _nodes[math.min(digits.length, _len) - 1].requestFocus();
    } else {
      _ctrls[i].text = digits;
      if (digits.isNotEmpty && i < _len - 1) _nodes[i + 1].requestFocus();
    }
    setState(() {});
    if (_code.length == _len) _verify();
  }

  Future<void> _verify() async {
    FocusScope.of(context).unfocus();
    setState(() => _stage = _Stage.loading);
    final started = DateTime.now();
    final r = await ApiService.post({'action': 'verify_otp', 'identifier': widget.identifier, 'code': _code});
    final wait = const Duration(milliseconds: 900) - DateTime.now().difference(started);
    if (wait > Duration.zero) await Future<void>.delayed(wait); // let the loading ring show
    if (!mounted) return;
    if (r['success'] == true) {
      HapticFeedback.mediumImpact();
      setState(() => _stage = _Stage.success);
      await _success.forward(from: 0);
      if (!mounted) return;
      final done = await Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) => NewPasswordPage(resetToken: '${r['resetToken']}')));
      if (done == true && mounted) Navigator.of(context).pop(true);
    } else {
      HapticFeedback.heavyImpact();
      setState(() { _stage = _Stage.input; _error = true; _errorText = '${r['message'] ?? 'الكود غلط'}'; });
      _shake.forward(from: 0);
      for (final c in _ctrls) c.clear();
      _nodes.first.requestFocus();
    }
  }

  Future<void> _resend() async {
    final r = await ApiService.post({'action': 'forgot_password', 'identifier': widget.identifier});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${r['message'] ?? ''}'),
      backgroundColor: r['success'] == true ? Colors.green : Colors.red,
    ));
    if (r['success'] == true) _startTimer();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<AppController>(context).isDark;
    final accent = isDark ? AppColors.primaryLight : AppColors.primary;
    final cardBg = isDark ? const Color(0xD918181B) : Colors.white.withOpacity(0.85);
    final textMain = isDark ? Colors.white : const Color(0xFF1E1B4B);
    final muted = isDark ? Colors.white60 : const Color(0xFF64748B);

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
                final t = _shake.value;
                final dx = t == 0 || t == 1 ? 0.0 : math.sin(t * math.pi * 8) * 6 * (1 - t);
                final e = Curves.easeOutCubic.transform(_enter.value);
                return Opacity(
                  opacity: e,
                  child: Transform.translate(offset: Offset(dx, 20 * (1 - e)), child: Transform.scale(scale: 0.98 + 0.02 * e, child: child)),
                );
              },
              child: Container(
                constraints: const BoxConstraints(maxWidth: 420),
                padding: const EdgeInsets.fromLTRB(24, 40, 24, 32),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: isDark ? Colors.white.withOpacity(0.06) : Colors.white.withOpacity(0.5)),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(isDark ? 0.5 : 0.06), blurRadius: 40, offset: const Offset(0, 20))],
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('اكتب كود التحقق', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: textMain)),
                  const SizedBox(height: 8),
                  Text('لو الحساب ليه إيميل مسجّل، اتبعتله كود من 6 أرقام صالح 10 دقايق.',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 14, height: 1.5, color: muted)),
                  const SizedBox(height: 28),
                  SizedBox(
                    height: 170,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 350),
                      transitionBuilder: (c, a) => ScaleTransition(scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack), child: FadeTransition(opacity: a, child: c)),
                      child: switch (_stage) {
                        _Stage.input => _pills(accent, textMain, isDark),
                        _Stage.loading => _loading(accent, isDark),
                        _Stage.success => _successView(),
                      },
                    ),
                  ),
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 250),
                    opacity: _error ? 1 : 0,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(_errorText ?? ' ', textAlign: TextAlign.center,
                          style: const TextStyle(color: Color(0xFFF43F5E), fontWeight: FontWeight.w600)),
                    ),
                  ),
                  TextButton(
                    onPressed: _resendIn > 0 || _stage != _Stage.input ? null : _resend,
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
    );
  }

  Widget _pills(Color accent, Color textMain, bool isDark) {
    const errorColor = Color(0xFFF43F5E);
    return Directionality(
      key: const ValueKey('pills'),
      textDirection: TextDirection.ltr,
      child: Center(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < _len; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            SizedBox(
              width: 46,
              height: 60,
              child: AnimatedBuilder(
                animation: _nodes[i],
                builder: (_, __) {
                  final focused = _nodes[i].hasFocus, filled = _ctrls[i].text.isNotEmpty;
                  final border = _error ? errorColor : (focused || filled) ? accent : (isDark ? Colors.white24 : Colors.black12);
                  return Container(
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF09090B) : const Color(0xFFFAFAFA),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: border, width: 1.5),
                      boxShadow: [
                        if (focused && !_error) BoxShadow(color: accent.withOpacity(0.25), spreadRadius: 3),
                        if (_error) BoxShadow(color: errorColor.withOpacity(0.2), spreadRadius: 3),
                      ],
                    ),
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
                      onTap: () => _ctrls[i].selection = TextSelection(baseOffset: 0, extentOffset: _ctrls[i].text.length),
                    ),
                  );
                },
              ),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _loading(Color accent, bool isDark) {
    return Center(
      key: const ValueKey('loading'),
      child: SizedBox(
        width: 100,
        height: 100,
        child: Stack(alignment: Alignment.center, children: [
          // pulse
          AnimatedBuilder(
            animation: _spin,
            builder: (_, __) {
              final t = (_spin.lastElapsedDuration?.inMilliseconds ?? 0) % 1600 / 1600;
              return Transform.scale(
                scale: 0.85 + 0.5 * t,
                child: Container(
                  width: 72, height: 72,
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: accent.withOpacity(0.55 * (1 - t)))),
                ),
              );
            },
          ),
          // spinning gradient ring
          RotationTransition(
            turns: _spin,
            child: Container(
              width: 72, height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(colors: [Colors.transparent, accent, Colors.transparent], stops: const [0, 0.7, 1]),
              ),
            ),
          ),
          Container(
            width: 60, height: 60,
            decoration: BoxDecoration(shape: BoxShape.circle, color: isDark ? const Color(0xFF18181B) : Colors.white),
          ),
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: accent.withOpacity(0.25), width: 1.5),
              boxShadow: [BoxShadow(color: accent.withOpacity(0.15), blurRadius: 12)],
            ),
            child: Icon(Icons.lock_outline_rounded, color: accent, size: 22),
          ),
        ]),
      ),
    );
  }

  Widget _successView() {
    const green = Color(0xFF10B981);
    return Center(
      key: const ValueKey('success'),
      child: AnimatedBuilder(
        animation: _success,
        builder: (_, __) {
          final t = Curves.easeOutCubic.transform(_success.value);
          return SizedBox(
            width: 240,
            height: 170,
            child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
              // flash
              Opacity(
                opacity: (t < 0.35 ? t / 0.35 : (1 - t) / 0.65).clamp(0, 1).toDouble(),
                child: Transform.scale(
                  scale: 0.4 + t,
                  child: Container(
                    width: 200, height: 200,
                    decoration: const BoxDecoration(shape: BoxShape.circle,
                        gradient: RadialGradient(colors: [Color(0x8C10B981), Color(0x2610B981), Colors.transparent], stops: [0, 0.4, 0.7])),
                  ),
                ),
              ),
              // bubbles
              for (final d in const [0.0, 0.15, 0.3])
                Builder(builder: (_) {
                  final k = ((t - d) / (1 - d)).clamp(0, 1).toDouble();
                  return Opacity(
                    opacity: (1 - k),
                    child: Transform.scale(
                      scale: 0.2 + 3.4 * k,
                      child: Container(width: 40, height: 40, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: green, width: 2))),
                    ),
                  );
                }),
              // vault + check
              Transform.scale(
                scale: Curves.elasticOut.transform(_success.value.clamp(0.0, 1.0).toDouble()),
                child: Container(
                  width: 72, height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle, color: green,
                    boxShadow: [BoxShadow(color: green.withOpacity(0.35), blurRadius: 24, spreadRadius: 2)],
                  ),
                  child: const Icon(Icons.check_rounded, color: Colors.white, size: 40),
                ),
              ),
              Positioned(
                bottom: 0,
                child: Opacity(
                  opacity: t,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(color: green.withOpacity(0.12), borderRadius: BorderRadius.circular(999)),
                    child: const Text('تم التحقق', style: TextStyle(color: green, fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
            ]),
          );
        },
      ),
    );
  }
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
            child: Container(
              constraints: const BoxConstraints(maxWidth: 420),
              padding: const EdgeInsets.fromLTRB(24, 36, 24, 28),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xD918181B) : Colors.white.withOpacity(0.85),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(isDark ? 0.5 : 0.06), blurRadius: 40, offset: const Offset(0, 20))],
              ),
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
    );
  }
}
