import 'package:flutter/material.dart';

import 'app_lock.dart';

/// Covers the whole app while [AppLock] is locked. The system prompt opens by itself; if the person cancels, a button
/// asks again, and «تسجيل الدخول من جديد» signs out (the only way past the lock without the phone's owner).
class AppLockGate extends StatefulWidget {
  final AppLock lock;
  final Widget child;
  final Future<void> Function() onSignOut;
  const AppLockGate({super.key, required this.lock, required this.child, required this.onSignOut});

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> {
  bool _asked = false;

  @override
  void initState() {
    super.initState();
    widget.lock.addListener(_changed);
    _askSoon();
  }

  @override
  void dispose() {
    widget.lock.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (!widget.lock.locked) _asked = false;
    setState(() {});
    _askSoon();
  }

  void _askSoon() {
    if (!widget.lock.locked || _asked) return;
    _asked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.lock.locked) widget.lock.unlock();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.lock.locked) return widget.child;
    return Stack(children: [
      // the app stays built underneath (nothing is reloaded), but nothing of it is visible or reachable
      Offstage(child: widget.child),
      Positioned.fill(
        child: Material(
          key: const ValueKey('app-lock-screen'),
          color: const Color(0xFF1B1B1A),
          child: SafeArea(
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.lock_outline_rounded, size: 64, color: Colors.white70),
                    const SizedBox(height: 18),
                    const Text('فاليو نيفو مقفول', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    const Text('افتح ببصمتك أو بقفل الموبايل (PIN / النمط / كلمة السر)',
                        textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 14)),
                    const SizedBox(height: 26),
                    FilledButton.icon(
                      key: const ValueKey('app-lock-unlock'),
                      onPressed: () => widget.lock.unlock(),
                      icon: const Icon(Icons.fingerprint_rounded),
                      label: const Text('افتح'),
                    ),
                    const SizedBox(height: 10),
                    TextButton(
                      key: const ValueKey('app-lock-sign-out'),
                      onPressed: () async {
                        await widget.onSignOut();
                        widget.lock.reset();
                      },
                      child: const Text('تسجيل الدخول من جديد', style: TextStyle(color: Colors.white70)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}
