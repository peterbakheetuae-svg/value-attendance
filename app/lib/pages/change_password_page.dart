import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/async_view.dart';
import '../core/i18n.dart';
import '../core/session.dart';
import '../jph/services/app_controller.dart';
import '../jph/widgets/app_background.dart';
import '../jph/widgets/glass_ui.dart' show Ar;
import '../jph/widgets/jph_form_ui.dart';
import '../design/glass_page.dart' show showSnack;

class ChangePasswordPage extends StatefulWidget {
  final bool forced;
  final VoidCallback? onDone;
  const ChangePasswordPage({super.key, this.forced = false, this.onDone});
  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final _cur = TextEditingController(), _new = TextEditingController(), _again = TextEditingController();
  bool _busy = false;
  String? _err;

  @override
  void dispose() { _cur.dispose(); _new.dispose(); _again.dispose(); super.dispose(); }

  Future<void> _save() async {
    final n = _new.text;
    String? err;
    if (_cur.text.isEmpty || n.isEmpty) {
      err = t('field_required');
    } else if (!(context.read<Session>().canUsePin && RegExp(r'^\d{4,8}$').hasMatch(n)) &&
        (n.length < 8 || !RegExp(r'\d').hasMatch(n) || !RegExp(r'[A-Za-z؀-ۿ]').hasMatch(n))) {
      err = context.read<Session>().canUsePin ? t('password_or_pin_policy') : t('password_policy');
    } else if (n != _again.text) {
      err = t('passwords_mismatch');
    }
    setState(() => _err = err);
    if (err != null) return;
    setState(() => _busy = true);
    try {
      await context.read<Session>().changePassword(_cur.text, n);
      if (!mounted) return;
      showSnack(context, t('password_changed'));
      if (widget.onDone != null) {
        widget.onDone!();
      } else if (!widget.forced) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) setState(() => _err = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // the app's theme (AppBackground, the glass boxes, the light / dark colours) — like every other page
    final isDark = context.watch<AppController>().isDark;
    final pin = context.read<Session>().canUsePin;
    return AppBackground(
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Column(children: [
              if (widget.forced)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Row(children: [
                    const SizedBox(width: 46),
                    Expanded(
                      child: Text(t('change_password'), textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                    ),
                    TextButton(onPressed: () => context.read<Session>().logout(), child: Text(t('logout'))),
                  ]),
                )
              else
                JphUi.header(context, isDark: isDark, isRTL: true, title: t('change_password')),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 30), children: [
                      Center(
                        child: Container(
                          width: 84,
                          height: 84,
                          decoration: BoxDecoration(color: JphUi.primary(isDark).withOpacity(0.15), shape: BoxShape.circle),
                          child: Icon(Icons.lock_reset_rounded, size: 42, color: JphUi.primary(isDark)),
                        ),
                      ),
                      const SizedBox(height: 14),
                      if (widget.forced)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Text(t('must_change_password'), textAlign: TextAlign.center,
                              style: const TextStyle(color: Ar.amber, fontWeight: FontWeight.w800)),
                        ),
                      JphUi.input(isDark: isDark, label: t('current_password'), controller: _cur, obscure: true, icon: Icons.lock_outline_rounded, big: false),
                      const SizedBox(height: 12),
                      JphUi.input(isDark: isDark, label: t('new_password'), controller: _new, obscure: true, icon: Icons.lock_rounded, big: false,
                          hint: pin ? t('password_or_pin_policy') : t('password_policy')),
                      const SizedBox(height: 12),
                      JphUi.input(isDark: isDark, label: t('confirm_password'), controller: _again, obscure: true, icon: Icons.lock_rounded, big: false,
                          onSubmitted: (_) => _save()),
                      if (_err != null)
                        Padding(padding: const EdgeInsets.only(top: 12), child: Text(_err!, style: const TextStyle(color: Ar.red, fontWeight: FontWeight.w700))),
                      const SizedBox(height: 20),
                      SizedBox(
                        height: 54,
                        child: FilledButton(
                          onPressed: _busy ? null : _save,
                          style: FilledButton.styleFrom(
                            backgroundColor: JphUi.primary(isDark),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          child: _busy
                              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : Text(t('save'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Colors.white)),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
