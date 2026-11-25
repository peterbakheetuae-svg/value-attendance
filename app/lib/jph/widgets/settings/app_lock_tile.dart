import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_lock.dart';
import '../glass_ui.dart';
import '../../services/app_controller.dart';

/// الإعدادات → «قفل التطبيق بالبصمة»: on / off. Shown only where the device has a fingerprint / face or a screen lock
/// (never on the web). Turning it on or off asks the device first.
class AppLockTile extends StatefulWidget {
  final AppLock? lock;
  const AppLockTile({super.key, this.lock});

  @override
  State<AppLockTile> createState() => _AppLockTileState();
}

class _AppLockTileState extends State<AppLockTile> {
  late final AppLock lock = widget.lock ?? AppLock.instance;
  bool? _available;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    lock.available().then((v) { if (mounted) setState(() => _available = v); });
  }

  Future<void> _toggle(bool on) async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await lock.setEnabled(on);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('ماتمش التأكيد — الإعداد زي ما هو')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_available != true) return const SizedBox.shrink();
    final isDark = Provider.of<AppController>(context).isDark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: Glass.panel(isDark, r: 18),
        child: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: Ar.grey.withOpacity(0.2), borderRadius: BorderRadius.circular(10)),
            child: Icon(Icons.fingerprint_rounded, color: isDark ? Colors.white : Ar.amber[700]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('قفل التطبيق بالبصمة', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: isDark ? Colors.white : Colors.black)),
              const SizedBox(height: 2),
              Text('بصمة / وش، أو قفل الموبايل (PIN أو النمط) — وانت فاضل مسجل دخول',
                  style: TextStyle(fontSize: 12, color: Ar.grey[600])),
            ]),
          ),
          Switch(
            key: const ValueKey('app-lock-switch'),
            value: lock.enabled,
            onChanged: _busy ? null : _toggle,
            activeColor: Theme.of(context).primaryColor,
          ),
        ]),
      ),
    );
  }
}
