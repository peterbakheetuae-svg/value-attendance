import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/async_view.dart';
import '../core/i18n.dart';
import '../core/session.dart';
import '../design/glass.dart';
import '../design/glass_page.dart';
import '../design/primary_button.dart';

class ChangePasswordPage extends StatefulWidget {
  final bool forced;
  const ChangePasswordPage({super.key, this.forced = false});
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
    } else if (n.length < 8 || !RegExp(r'\d').hasMatch(n) || !RegExp(r'[A-Za-z؀-ۿ]').hasMatch(n)) {
      err = t('password_policy');
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
      if (!widget.forced) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _err = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassPage(
      title: t('change_password'),
      actions: [
        if (widget.forced) TextButton(onPressed: () => context.read<Session>().logout(), child: Text(t('logout'))),
      ],
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (widget.forced) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(t('must_change_password'), style: TextStyle(color: Colors.orange[700], fontWeight: FontWeight.w700))),
        GlassCard(
          radius: 20,
          child: Material(
            type: MaterialType.transparency,
            child: Column(children: [
              TextField(controller: _cur, obscureText: true, decoration: glassInput(context, t('current_password'))),
              const SizedBox(height: 14),
              TextField(controller: _new, obscureText: true, decoration: glassInput(context, t('new_password'), hint: t('password_policy'))),
              const SizedBox(height: 14),
              TextField(controller: _again, obscureText: true, decoration: glassInput(context, t('confirm_password')), onSubmitted: (_) => _save()),
              if (_err != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_err!, style: const TextStyle(color: Colors.red))),
              const SizedBox(height: 20),
              PrimaryButton(label: t('save'), loading: _busy, onTap: _save),
            ]),
          ),
        ),
      ]),
    );
  }
}
