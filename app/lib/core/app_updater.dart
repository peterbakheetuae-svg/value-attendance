import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../jph/widgets/glass_dialog.dart';
import 'platform_info.dart';

/// App update (Android): every Android build is published on the app's own site —
/// https://jaurea.com/valunivo/android/latest.json names the newest version and its APK next to it.
///  - On start / when the app comes back, and when "التحقق من التحديثات" is pressed, a newer build is looked up.
///  - The APK is downloaded ONCE and kept; pressing again never downloads it a second time — it just offers "تثبيت".
///  - Only one download at a time. Old APK files are removed once the app is on a newer build.
/// Android always asks the person to tap "Install" — no app can skip that.
///
/// Windows app: the same, from https://jaurea.com/valunivo/windows/latest.json and its installer next to it
/// ({"version","build","installer":"VALUNIVO-Setup-1.0.N.exe","size","sha256"}). The installer is checked
/// against its SHA-256 before it runs, then it updates the installed app in place and opens it again.
class AppUpdater with WidgetsBindingObserver {
  AppUpdater._();
  static final AppUpdater instance = AppUpdater._();

  static String get _base => PlatformInfo.isWindows ? 'https://jaurea.com/valunivo/windows/' : 'https://jaurea.com/valunivo/android/';
  static String get _ext => PlatformInfo.isWindows ? 'exe' : 'apk';
  String? _sha256; // expected hash of the installer being offered (Windows)

  GlobalKey<NavigatorState>? _nav;
  DateTime? _lastCheck;
  Future<File?>? _download; // the one download in progress
  final ValueNotifier<double> _progress = ValueNotifier(0);
  bool _dialogOpen = false;

  static bool get supported => (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) || PlatformInfo.isWindows;

  void start(GlobalKey<NavigatorState> nav) {
    if (!supported) return; // the web version is always current
    _nav = nav;
    WidgetsBinding.instance.addObserver(this);
    Future.delayed(const Duration(seconds: 4), () => check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) check();
  }

  Future<Directory> _dir() async {
    final d = Directory('${(await getApplicationSupportDirectory()).path}/updates');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Future<File> _fileFor(String version) async => File('${(await _dir()).path}/value-attendance-$version.$_ext');

  /// Looks for a newer build. [manual] = the person pressed the button: always answers (up to date / failed).
  Future<void> check({BuildContext? context, bool manual = false}) async {
    if (!supported) {
      if (manual && context != null) _say(context, 'نسخة الويب بتتحدث لوحدها — اعمل تحديث للصفحة لو لسه شايف القديمة.');
      return;
    }
    final now = DateTime.now();
    if (!manual && _lastCheck != null && now.difference(_lastCheck!) < const Duration(minutes: 30)) return;
    _lastCheck = now;
    try {
      final info = await PackageInfo.fromPlatform();
      final mine = int.tryParse(info.buildNumber) ?? 0;
      // {"version":"1.0.N","build":N,"apk":"value-attendance-1.0.N.apk","size":…,"sha256":…}
      final r = await http.get(Uri.parse('${_base}latest.json?t=${now.millisecondsSinceEpoch}'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw Exception('update info ${r.statusCode}');
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final build = (j['build'] as num?)?.toInt() ?? 0;
      final version = '${j['version'] ?? ''}';
      await _cleanup(mine);
      if (build <= mine) {
        if (manual && context != null && context.mounted) _say(context, 'إنت على أحدث نسخة ✅ (${info.version}+${info.buildNumber})');
        return;
      }
      final apk = '${j[PlatformInfo.isWindows ? 'installer' : 'apk'] ?? ''}';
      if (!RegExp('^[\\w.-]+\\.$_ext\$').hasMatch(apk)) throw Exception('no $_ext');
      _sha256 = '${j['sha256'] ?? ''}'.toLowerCase();
      // Windows runs the downloaded file: never without a hash to check it against
      if (PlatformInfo.isWindows && !RegExp(r'^[0-9a-f]{64}$').hasMatch(_sha256!)) throw Exception('no sha256');
      final url = '$_base$apk';
      final size = (j['size'] as num?)?.toInt() ?? 0;
      await _offer(url, version, size);
    } catch (_) {
      _lastCheck = null; // try again next time
      if (manual && context != null && context.mounted) _say(context, 'مش قادر أتحقق من التحديث دلوقتي — اتأكد من النت وجرب تاني.');
    }
  }

  /// Old builds' APK files are not needed once the app is newer.
  Future<void> _cleanup(int mine) async {
    try {
      for (final f in (await _dir()).listSync().whereType<File>()) {
        final b = int.tryParse(RegExp(r'(\d+)\.(apk|exe)(\.part)?$').firstMatch(f.path)?.group(1) ?? '');
        if (b != null && b <= mine) f.deleteSync();
      }
    } catch (_) {}
  }

  /// Downloads (only if not already downloaded / downloading) and offers "تثبيت".
  Future<void> _offer(String url, String version, int size) async {
    final file = await _fileFor(version);
    final ready = file.existsSync() && (size == 0 || file.lengthSync() == size);
    if (!ready) _download ??= _fetch(url, file, size).whenComplete(() => _download = null);
    _showDialog(version, file, ready);
  }

  Future<File?> _fetch(String url, File file, int size) async {
    final part = File('${file.path}.part');
    final client = http.Client();
    try {
      _progress.value = 0;
      final res = await client.send(http.Request('GET', Uri.parse(url))).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw Exception('download ${res.statusCode}');
      final total = res.contentLength ?? size;
      final sink = part.openWrite();
      var got = 0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) _progress.value = got / total;
      }
      await sink.close();
      if (total > 0 && part.lengthSync() != total) throw Exception('incomplete');
      if (file.existsSync()) file.deleteSync();
      part.renameSync(file.path);
      _progress.value = 1;
      return file;
    } catch (_) {
      try { if (part.existsSync()) part.deleteSync(); } catch (_) {}
      _lastCheck = null;
      return null;
    } finally {
      client.close();
    }
  }

  Future<void> _install(File file) async {
    if (PlatformInfo.isWindows) {
      // the installer must be exactly the published one
      final want = _sha256 ?? '';
      final got = sha256.convert(await file.readAsBytes()).toString();
      if (want.isEmpty || got != want) {
        try { file.deleteSync(); } catch (_) {}
        final ctx = _nav?.currentContext;
        if (ctx != null && ctx.mounted) _say(ctx, 'ملف التحديث مش سليم واتمسح — جرب تاني بعدين.');
        return;
      }
      // updates the installed app in place (same settings and sign-in), then opens it again
      await Process.start(file.path, const ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'],
          mode: ProcessStartMode.detached);
      exit(0);
    }
    await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
  }

  void _showDialog(String version, File file, bool ready) {
    final ctx = _nav?.currentContext;
    if (ctx == null || _dialogOpen) return;
    _dialogOpen = true;
    final pending = _download;
    showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (c) => Directionality(
        textDirection: TextDirection.rtl,
        child: GlassAlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          icon: const Icon(Icons.system_update_rounded, size: 46, color: Color(0xFF4F46E5)),
          title: Text('تحديث جديد $version', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800)),
          content: ready || pending == null
              ? const Text('التحديث نزل وجاهز — دوس "تثبيت".', textAlign: TextAlign.center)
              : FutureBuilder<File?>(
                  future: pending,
                  builder: (_, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return ValueListenableBuilder<double>(
                        valueListenable: _progress,
                        builder: (_, p, __) => Column(mainAxisSize: MainAxisSize.min, children: [
                          const Text('جاري تحميل التحديث...', textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          LinearProgressIndicator(value: p, minHeight: 8, borderRadius: BorderRadius.circular(8)),
                          const SizedBox(height: 6),
                          Text('${(p * 100).round()}%'),
                        ]),
                      );
                    }
                    return Text(snap.data == null ? 'التحميل ماكملش — جرب تاني بعدين.' : 'التحديث نزل وجاهز — دوس "تثبيت".',
                        textAlign: TextAlign.center);
                  },
                ),
          actions: [
            TextButton(
              onPressed: () {
                _dialogOpen = false;
                Navigator.pop(c); // the download (if any) keeps going; pressing again will not download twice
              },
              child: const Text('بعدين'),
            ),
            FutureBuilder<File?>(
              future: ready ? Future.value(file) : (pending ?? Future.value(file.existsSync() ? file : null)),
              builder: (_, snap) {
                final f = snap.data;
                final can = snap.connectionState == ConnectionState.done && f != null;
                return FilledButton.icon(
                  onPressed: can
                      ? () {
                          _dialogOpen = false;
                          Navigator.pop(c);
                          _install(f);
                        }
                      : null,
                  icon: const Icon(Icons.install_mobile_rounded),
                  label: const Text('تثبيت'),
                );
              },
            ),
          ],
        ),
      ),
    ).whenComplete(() => _dialogOpen = false);
  }

  void _say(BuildContext context, String msg) {
    showDialog<void>(
      context: context,
      builder: (c) => Directionality(
        textDirection: TextDirection.rtl,
        child: GlassAlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          title: const Text('التحقق من التحديثات', textAlign: TextAlign.center),
          content: Text(msg, textAlign: TextAlign.center),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('تمام'))],
        ),
      ),
    );
  }
}
