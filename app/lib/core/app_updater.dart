import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Automatic app update (Android): every build is published as the latest GitHub release
/// ("v1.0.<build>" with value-attendance.apk). On start and when the app comes back to the
/// front, a newer build is downloaded by itself and the Android installer opens.
/// Android always asks the person to tap "Install" once — no app can skip that.
class AppUpdater with WidgetsBindingObserver {
  AppUpdater._();
  static final AppUpdater instance = AppUpdater._();

  static const _latest = 'https://api.github.com/repos/peterbakheetuae-svg/value-attendance/releases/latest';

  GlobalKey<NavigatorState>? _nav;
  bool _busy = false;
  DateTime? _lastCheck;

  void start(GlobalKey<NavigatorState> nav) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return; // the web version is always current
    _nav = nav;
    WidgetsBinding.instance.addObserver(this);
    Future.delayed(const Duration(seconds: 4), check);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) check();
  }

  Future<void> check() async {
    if (_busy) return;
    final now = DateTime.now();
    if (_lastCheck != null && now.difference(_lastCheck!) < const Duration(minutes: 30)) return;
    _lastCheck = now;
    try {
      final info = await PackageInfo.fromPlatform();
      final mine = int.tryParse(info.buildNumber) ?? 0;
      final r = await http.get(Uri.parse(_latest), headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final tag = '${j['tag_name'] ?? ''}'; // v1.0.<build>
      final build = int.tryParse(tag.split('.').last) ?? 0;
      if (build <= mine) return;
      final asset = ((j['assets'] as List?) ?? const [])
          .whereType<Map>()
          .firstWhere((a) => '${a['name']}'.endsWith('.apk'), orElse: () => const {});
      final url = '${asset['browser_download_url'] ?? ''}';
      if (url.isEmpty) return;
      await _install(url, tag.replaceFirst('v', ''));
    } catch (_) {
      // no internet / GitHub unreachable: try again next time
    }
  }

  Future<void> _install(String url, String version) async {
    final ctx = _nav?.currentContext;
    if (ctx == null) return;
    _busy = true;
    final progress = ValueNotifier<String>('0');
    final status = ValueNotifier<String>('جاري تحميل التحديث...');
    StreamSubscription<OtaEvent>? sub;
    showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (c) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          icon: const Icon(Icons.system_update_rounded, size: 46, color: Color(0xFF4F46E5)),
          title: Text('تحديث جديد $version', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800)),
          content: ValueListenableBuilder<String>(
            valueListenable: status,
            builder: (_, s, __) => ValueListenableBuilder<String>(
              valueListenable: progress,
              builder: (_, p, __) => Column(mainAxisSize: MainAxisSize.min, children: [
                Text(s, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: (double.tryParse(p) ?? 0) / 100, minHeight: 8, borderRadius: BorderRadius.circular(8)),
                const SizedBox(height: 6),
                Text('$p%'),
              ]),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                sub?.cancel();
                _busy = false;
                Navigator.pop(c);
              },
              child: const Text('بعدين'),
            ),
          ],
        ),
      ),
    );
    try {
      sub = OtaUpdate().execute(url, destinationFilename: 'value-attendance-$version.apk').listen((e) {
        switch (e.status) {
          case OtaStatus.DOWNLOADING:
            progress.value = e.value ?? '0';
            break;
          case OtaStatus.INSTALLING:
            status.value = 'دوس "تثبيت" عشان التحديث يكمل';
            progress.value = '100';
            _busy = false;
            break;
          default:
            status.value = 'التحديث ماكملش — هيتجرب تاني بعدين';
            _busy = false;
            _lastCheck = null;
        }
      }, onError: (_) {
        status.value = 'التحديث ماكملش — هيتجرب تاني بعدين';
        _busy = false;
        _lastCheck = null;
      });
    } catch (_) {
      _busy = false;
    }
  }
}
