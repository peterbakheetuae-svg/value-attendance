import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Android only. On the first start after install the app asks, one after the other, for:
///   • the location (required — attendance and the in-shift follow-up need it),
///   • «الظهور فوق التطبيقات» (the ringing alerts over other apps),
///   • «بطارية غير مقيدة» (so Android doesn't stop the alerts / follow-up in the background).
/// The app never opens without the location permission: if it is turned off later from the phone's settings,
/// this screen comes back (checked again every time the app returns to the front).
class PermissionsGate extends StatefulWidget {
  final Widget child;
  const PermissionsGate({super.key, required this.child});

  @override
  State<PermissionsGate> createState() => _PermissionsGateState();
}

class _PermissionsGateState extends State<PermissionsGate> with WidgetsBindingObserver {
  static const _seenKey = 'permissions_gate_v1';
  static bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  PermissionStatus? _loc, _overlay, _battery;
  bool _firstRun = false, _busy = false;

  @override
  void initState() {
    super.initState();
    if (!_android) return;
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    if (_android) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) _refresh();
  }

  Future<void> _start() async {
    try {
      final p = await SharedPreferences.getInstance();
      _firstRun = p.getBool(_seenKey) != true;
    } catch (_) {}
    await _refresh();
    if (_firstRun) await _askAll();
  }

  Future<void> _refresh() async {
    try {
      final r = await Future.wait([Permission.location.status, Permission.systemAlertWindow.status, Permission.ignoreBatteryOptimizations.status]);
      if (mounted) {
        setState(() {
          _loc = r[0];
          _overlay = r[1];
          _battery = r[2];
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loc = PermissionStatus.granted);   // the plugin failed: never lock the app because of it
    }
  }

  Future<void> _ask(Permission p) async {
    setState(() => _busy = true);
    try {
      final s = await p.status;
      if (s.isPermanentlyDenied && p == Permission.location) {
        await openAppSettings();
      } else if (!s.isGranted) {
        await p.request();
      }
    } catch (_) {}
    _busy = false;
    await _refresh();
  }

  Future<void> _askAll() async {
    await _ask(Permission.location);
    await _ask(Permission.systemAlertWindow);
    await _ask(Permission.ignoreBatteryOptimizations);
  }

  Future<void> _done() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_seenKey, true);
    } catch (_) {}
    setState(() => _firstRun = false);
  }

  bool get _locOk => _loc?.isGranted == true || _loc?.isLimited == true;

  @override
  Widget build(BuildContext context) {
    if (!_android) return widget.child;
    if (_loc == null) {
      return const ColoredBox(color: Color(0xFF1B1B1A), child: Center(child: CircularProgressIndicator()));
    }
    if (_locOk && !_firstRun) return widget.child;
    final ar = Localizations.maybeLocaleOf(context)?.languageCode != 'en';
    String t(String a, String e) => ar ? a : e;
    Widget row(IconData icon, String title, String sub, PermissionStatus? s, Permission p, {bool required = false}) {
      final ok = s?.isGranted == true || s?.isLimited == true;
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.07),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: ok ? const Color(0xFF4FCF73) : (required ? const Color(0xFFFF6A3D) : Colors.white24)),
        ),
        child: Row(children: [
          Icon(icon, color: ok ? const Color(0xFF4FCF73) : const Color(0xFFFF6A3D), size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.w900)),
              const SizedBox(height: 2),
              Text(sub, style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
            ]),
          ),
          const SizedBox(width: 8),
          ok
              ? const Icon(Icons.check_circle_rounded, color: Color(0xFF4FCF73), size: 28)
              : FilledButton(
                  onPressed: _busy ? null : () => _ask(p),
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF6A3D)),
                  child: Text(t('سماح', 'Allow'), style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
        ]),
      );
    }

    return Material(
      color: const Color(0xFF1B1B1A),
      child: Directionality(
        textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
        child: SafeArea(
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 30, 20, 20), children: [
            const Icon(Icons.verified_user_rounded, color: Color(0xFFFF6A3D), size: 64),
            const SizedBox(height: 12),
            Text(t('أذونات التطبيق', 'App permissions'), textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Text(
              _locOk
                  ? t('اسمح بالباقي عشان التنبيهات توصلك في وقتها حتى والتطبيق مقفول.', 'Allow the rest so alerts reach you on time even when the app is closed.')
                  : t('التطبيق مش هيفتح من غير إذن الموقع — الحضور والانصراف ومتابعة الشيفت محتاجينه.',
                      'The app won\'t open without the location permission — attendance and shift follow-up need it.'),
              textAlign: TextAlign.center,
              style: TextStyle(color: _locOk ? Colors.white70 : const Color(0xFFFF8A65), fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 22),
            row(Icons.location_on_rounded, t('الموقع (مطلوب)', 'Location (required)'),
                t('لتسجيل الحضور والانصراف ومتابعة الشيفت', 'For check-in / check-out and shift follow-up'), _loc, Permission.location, required: true),
            row(Icons.layers_rounded, t('الظهور فوق التطبيقات', 'Display over other apps'),
                t('عشان التنبيهات المهمة تظهر فوق أي تطبيق', 'So important alerts show over any app'), _overlay, Permission.systemAlertWindow),
            row(Icons.battery_charging_full_rounded, t('بطارية غير مقيدة', 'Unrestricted battery'),
                t('عشان أندرويد ميقفلش التنبيهات في الخلفية', 'So Android doesn\'t stop alerts in the background'), _battery, Permission.ignoreBatteryOptimizations),
            const SizedBox(height: 10),
            if (_loc?.isPermanentlyDenied == true)
              TextButton.icon(
                onPressed: openAppSettings,
                icon: const Icon(Icons.settings_rounded, color: Colors.white70),
                label: Text(t('افتح إعدادات التطبيق ← الأذونات ← الموقع', 'Open app settings → Permissions → Location'),
                    style: const TextStyle(color: Colors.white70)),
              ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _locOk && !_busy ? _done : null,
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF6A3D), minimumSize: const Size.fromHeight(52)),
              child: Text(t('يلا نبدأ', 'Continue'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
            ),
          ]),
        ),
      ),
    );
  }
}
