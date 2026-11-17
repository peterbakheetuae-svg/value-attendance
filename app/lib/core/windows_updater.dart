import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:crypto/crypto.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pinenacl/ed25519.dart' as nacl;
import 'package:shared_preferences/shared_preferences.dart';

import '../jph/theme/app_colors.dart';
import '../jph/widgets/glass_dialog.dart';
import 'platform_info.dart';
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';

/// Automatic updates for the Windows app (VALUNIVO.exe). Android keeps its own updater (AppUpdater).
///
/// 1. On start and every few hours: `<base>latest.json` — a manifest signed with the release key (Ed25519).
///    The signature is checked against the public key compiled into this build BEFORE anything in it is used.
/// 2. A newer build is downloaded quietly in the background (small status chip); size + SHA-256 must match the
///    signed manifest, otherwise the file is thrown away.
/// 3. When it is ready: restart now (asked) — or automatically when nobody is signed in and the app is idle —
///    or on the next close. VALUNIVO closes first; the bundled helper (VALUNIVO-Updater.exe) checks the installer
///    again, backs up the app, installs, reopens VALUNIVO and waits for it to report healthy. If anything fails it
///    restores the backup and reopens the previous version.
/// Never downgrades unless the signed manifest itself says it is a rollback release. Settings, the sign-in
/// (DPAPI-protected token) and the device id live in AppData and are never touched by an update.
class WindowsUpdater {
  WindowsUpdater._();
  static final WindowsUpdater instance = WindowsUpdater._();

  // HTTPS only. Overridable at build time for the CI update test (a local HTTPS server); production uses the default.
  static const String baseUrl = String.fromEnvironment('UPDATE_BASE_URL', defaultValue: 'https://jaurea.com/valunivo/windows/');
  // Raw Ed25519 public key(s) the app trusts (base64, comma-separated), compiled in by the release build from the
  // pinned list in tool/release/windows_update_public_keys.txt. Two keys = a planned key rotation.
  static const String publicKeyB64 = String.fromEnvironment('UPDATE_PUBLIC_KEY');
  static List<List<int>> get trustedKeys => publicKeyB64
      .split(',')
      .map((k) => k.trim())
      .where((k) => k.isNotEmpty)
      .map((k) {
        try {
          return base64Decode(k);
        } catch (_) {
          return const <int>[];
        }
      })
      .where((k) => k.length == 32)
      .toList();
  static const Duration _every = Duration(hours: 4);
  static const Duration _idleForAutoRestart = Duration(seconds: 60);

  final ValueNotifier<WinUpdateState> state = ValueNotifier(const WinUpdateState.idle());
  GlobalKey<NavigatorState>? _nav;
  bool Function() _signedIn = () => true;
  Timer? _timer, _safeTimer;
  bool _busy = false, _asked = false, _applying = false;
  DateTime _lastInput = DateTime.now();
  int _mine = 0;
  _Ready? _ready;
  AppLifecycleListener? _exitListener;

  bool get enabled => PlatformInfo.isWindows && baseUrl.startsWith('https://') && trustedKeys.isNotEmpty;

  static Directory get stateDir {
    final local = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    return Directory('$local\\VALUNIVO\\updates');
  }

  void start(GlobalKey<NavigatorState> nav, {required bool Function() signedIn}) {
    if (!PlatformInfo.isWindows) return;
    _nav = nav;
    _signedIn = signedIn;
    unawaited(_afterStart());
    if (!enabled) {
      _log('updater disabled (no https base url or no release public key in this build)');
      return;
    }
    // remember when the person last used mouse / keyboard (an automatic restart only happens when idle)
    GestureBinding.instance.pointerRouter.addGlobalRoute((_) => _lastInput = DateTime.now());
    HardwareKeyboard.instance.addHandler((_) {
      _lastInput = DateTime.now();
      return false;
    });
    _exitListener = AppLifecycleListener(onExitRequested: _onExitRequested);
    Future.delayed(const Duration(seconds: 6), () => check());
    _timer = Timer.periodic(_every, (_) => check());
  }

  /// "التحقق من التحديثات" in settings.
  Future<void> checkNow(BuildContext context) async {
    if (!enabled) {
      _say(context, 'التحديث التلقائي مش مفعّل في النسخة دي.');
      return;
    }
    final before = state.value;
    await check(manual: true);
    if (!context.mounted) return;
    final s = state.value;
    if (s.kind == WinUpdateKind.ready) {
      _askRestart();
    } else if (s.kind == WinUpdateKind.downloading) {
      _say(context, 'فيه تحديث جديد بيتحمّل دلوقتي — هيبلغك أول ما يجهز.');
    } else if (s.kind == WinUpdateKind.failed) {
      _say(context, 'مش قادر أتحقق من التحديث دلوقتي — اتأكد من النت وجرب تاني.');
    } else if (before.kind == WinUpdateKind.idle) {
      final info = await PackageInfo.fromPlatform();
      if (context.mounted) _say(context, 'إنت على أحدث نسخة ✅ (${info.version}+${info.buildNumber})');
    }
  }

  // ---------------------------------------------------------------- check + download

  Future<void> check({bool manual = false}) async {
    if (!enabled || _busy || _applying) return;
    if (_ready != null) {
      _onReady();
      return;
    }
    _busy = true;
    try {
      final info = await PackageInfo.fromPlatform();
      _mine = int.tryParse(info.buildNumber) ?? 0;
      final r = await http.get(Uri.parse('${baseUrl}latest.json?t=${DateTime.now().millisecondsSinceEpoch}'))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) throw _Reject('manifest http ${r.statusCode}');
      final m = UpdateManifest.verify(r.body, trustedKeys);
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getInt('win_update_issued') ?? 0;
      if (m.issued < seen) throw _Reject('replayed older manifest (issued ${m.issued} < $seen)');
      if (m.issued > seen) await prefs.setInt('win_update_issued', m.issued);
      if (m.build == _mine) {
        _log('up to date (build $_mine)');
        state.value = const WinUpdateState.idle();
        return;
      }
      if (m.build < _mine && !m.rollback) {
        _log('manifest build ${m.build} is older than installed $_mine — ignored (no downgrade)');
        return;
      }
      if (_failedBuilds().contains(m.build)) {
        _log('skipping build ${m.build}: it failed to install here before (rolled back)');
        return;
      }
      _log('update available: ${m.version} (build ${m.build}) — installed build $_mine${m.rollback ? ' [signed rollback]' : ''}');
      final file = await _download(m);
      _ready = _Ready(m, file);
      state.value = WinUpdateState.ready(m.version);
      _log('downloaded and verified ${file.path}');
      _onReady();
    } on _Reject catch (e) {
      _log('rejected: ${e.reason}');
      state.value = manual ? const WinUpdateState.failed() : const WinUpdateState.idle();
    } catch (e) {
      _log('check failed: $e');
      state.value = manual ? const WinUpdateState.failed() : const WinUpdateState.idle();
    } finally {
      _busy = false;
    }
  }

  Future<File> _download(UpdateManifest m) async {
    final dir = stateDir..createSync(recursive: true);
    final file = File('${dir.path}\\${m.installer}');
    if (file.existsSync() && file.lengthSync() == m.size && await _sha256(file) == m.sha256) return file;
    final part = File('${file.path}.part');
    final client = http.Client();
    try {
      state.value = WinUpdateState.downloading(m.version, 0);
      final res = await client.send(http.Request('GET', Uri.parse('$baseUrl${m.installer}'))).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw _Reject('download http ${res.statusCode}');
      if (res.contentLength != null && res.contentLength != m.size) {
        throw _Reject('size mismatch (server ${res.contentLength}, signed ${m.size})');
      }
      final sink = part.openWrite();
      final digest = _DigestSink();
      final hasher = sha256.startChunkedConversion(digest);
      var got = 0;
      try {
        await for (final chunk in res.stream.timeout(const Duration(seconds: 60))) {
          got += chunk.length;
          if (got > m.size) throw _Reject('download larger than the signed size');
          sink.add(chunk);
          hasher.add(chunk);
          state.value = WinUpdateState.downloading(m.version, got / m.size);
        }
      } finally {
        await sink.close();
      }
      hasher.close();
      if (got != m.size) throw _Reject('incomplete download ($got of ${m.size} bytes)');
      if (digest.value.toString() != m.sha256) throw _Reject('SHA-256 mismatch — corrupted or altered package');
      if (file.existsSync()) file.deleteSync();
      part.renameSync(file.path);
      return file;
    } catch (_) {
      try {
        if (part.existsSync()) part.deleteSync();
      } catch (_) {}
      rethrow;
    } finally {
      client.close();
    }
  }

  // ---------------------------------------------------------------- applying

  void _onReady() {
    final r = _ready;
    if (r == null || _applying) return;
    // safe to restart on its own: nobody signed in and no mouse / keyboard for a minute
    _safeTimer ??= Timer.periodic(const Duration(seconds: 10), (_) {
      if (_ready != null && !_applying && !_signedIn() && DateTime.now().difference(_lastInput) >= _idleForAutoRestart) {
        _log('nobody signed in and idle — restarting to update automatically');
        unawaited(apply(relaunch: true));
      }
    });
    if (_signedIn()) _askRestart();
  }

  void _askRestart() {
    final ctx = _nav?.currentContext;
    final r = _ready;
    if (ctx == null || r == null || _asked) return;
    _asked = true;
    showDialog<bool>(
      context: ctx,
      builder: (c) => Directionality(
        textDirection: TextDirection.rtl,
        child: GlassAlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          icon: const Icon(Icons.system_update_rounded, size: 46, color: Color(0xFF4F46E5)),
          title: Text('تحديث جديد ${r.manifest.version}', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800)),
          content: const Text('التحديث نزل وجاهز. البرنامج هيقفل ويفتح تاني لوحده خلال ثواني — شغلك المحفوظ ودخولك زي ما هم.',
              textAlign: TextAlign.center),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('بعدين')),
            FilledButton.icon(
              onPressed: () => Navigator.pop(c, true),
              icon: const Icon(Icons.restart_alt_rounded),
              label: const Text('أعد التشغيل الآن'),
            ),
          ],
        ),
      ),
    ).then((now) {
      if (now == true) unawaited(apply(relaunch: true));
    });
  }

  /// Hands the verified installer to the helper and closes VALUNIVO (the helper waits for it to be closed).
  Future<bool> apply({required bool relaunch}) async {
    final r = _ready;
    if (r == null || _applying) return false;
    _applying = true;
    try {
      // the file must still be exactly the verified one
      if (!r.file.existsSync() || r.file.lengthSync() != r.manifest.size || await _sha256(r.file) != r.manifest.sha256) {
        throw _Reject('installer changed after download');
      }
      final appDir = File(Platform.resolvedExecutable).parent.path;
      final bundled = File('$appDir\\VALUNIVO-Updater.exe');
      if (!bundled.existsSync()) throw _Reject('VALUNIVO-Updater.exe missing next to the app');
      // run a copy: the installer replaces the bundled helper
      final helper = File('${stateDir.path}\\VALUNIVO-Updater-run.exe');
      bundled.copySync(helper.path);
      final args = [
        '--pid', '$pid',
        '--installer', r.file.path,
        '--sha256', r.manifest.sha256,
        '--size', '${r.manifest.size}',
        '--from-build', '$_mine',
        '--to-build', '${r.manifest.build}',
        '--app-dir', appDir,
        '--state-dir', stateDir.path,
        '--relaunch', relaunch ? '1' : '0',
        if (r.manifest.rollback) ...['--allow-downgrade', '1'],
      ];
      _log('starting helper (relaunch=$relaunch): ${r.manifest.version}');
      await Process.start(helper.path, args, mode: ProcessStartMode.detached, workingDirectory: stateDir.path);
      if (relaunch) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        exit(0);
      }
      return true;
    } catch (e) {
      _log('apply failed: $e');
      _ready = null;
      _applying = false;
      state.value = const WinUpdateState.idle();
      return false;
    }
  }

  Future<AppExitResponse> _onExitRequested() async {
    // closing VALUNIVO with an update waiting: install it now, quietly, without reopening
    if (_ready != null && !_applying) await apply(relaunch: false);
    return AppExitResponse.exit;
  }

  // ---------------------------------------------------------------- after start: health + last result

  Future<void> _afterStart() async {
    try {
      final dir = stateDir..createSync(recursive: true);
      final info = await PackageInfo.fromPlatform();
      final build = int.tryParse(info.buildNumber) ?? 0;
      // the helper waits for this file to know the new version really starts
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(seconds: 4), () {
          try {
            File('${dir.path}\\healthy-$build').writeAsStringSync(DateTime.now().toIso8601String());
          } catch (_) {}
        });
      });
      try {
        final run = File('${dir.path}\\VALUNIVO-Updater-run.exe');
        if (run.existsSync()) run.deleteSync();
      } catch (_) {}
      final res = File('${dir.path}\\result.json');
      if (!res.existsSync()) return;
      final j = jsonDecode(res.readAsStringSync()) as Map<String, dynamic>;
      res.renameSync('${dir.path}\\result-seen.json');
      _log('last update: $j');
      if (j['result'] == 'rolled_back') {
        Future.delayed(const Duration(seconds: 3), () {
          final ctx = _nav?.currentContext;
          if (ctx != null && ctx.mounted) {
            _say(ctx, 'التحديث ماتثبتش صح، فرجعنا للنسخة اللي كانت شغالة — مفيش حاجة اتغيرت عندك.');
          }
        });
      }
    } catch (_) {}
  }

  Set<int> _failedBuilds() {
    try {
      final f = File('${stateDir.path}\\failed-builds.txt');
      if (!f.existsSync()) return {};
      return f.readAsLinesSync().map((l) => int.tryParse(l.trim())).whereType<int>().toSet();
    } catch (_) {
      return {};
    }
  }

  static Future<String> _sha256(File f) async => (await sha256.bind(f.openRead()).first).toString();

  static void _log(String msg) {
    try {
      final d = stateDir..createSync(recursive: true);
      File('${d.path}\\updater-app.log')
          .writeAsStringSync('${DateTime.now().toIso8601String()} $msg\r\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  void _say(BuildContext context, String msg) {
    showDialog<void>(
      context: context,
      builder: (c) => Directionality(
        textDirection: TextDirection.rtl,
        child: GlassAlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          title: const Text('التحديثات', textAlign: TextAlign.center),
          content: Text(msg, textAlign: TextAlign.center),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('تمام'))],
        ),
      ),
    );
  }

  /// The chip's «أعد التشغيل» (asks again even after «بعدين»).
  void askRestart() {
    _asked = false;
    _askRestart();
  }

  void dispose() {
    _timer?.cancel();
    _safeTimer?.cancel();
    _exitListener?.dispose();
  }
}

// ------------------------------------------------------------------ manifest

/// `latest.json` = {"format":1,"manifest":"<JSON text>","sig":"<base64 Ed25519 signature of that exact text>"}
/// The manifest text: {"app":"VALUNIVO","platform":"windows-x64","channel":"stable","version":"1.0.N","build":N,
/// "installer":"VALUNIVO-Setup-1.0.N.exe","size":…,"sha256":"…","issued":<unix seconds>,"rollback":false}
class UpdateManifest {
  final String version, installer, sha256;
  final int build, size, issued;
  final bool rollback;
  const UpdateManifest._(this.version, this.build, this.installer, this.size, this.sha256, this.issued, this.rollback);

  /// Checks the signature against [trustedKeys] (any one of them) before anything in the manifest is used.
  static UpdateManifest verify(String body, List<List<int>> trustedKeys) {
    if (trustedKeys.isEmpty || trustedKeys.any((k) => k.length != 32)) throw _Reject('bad public key');
    final Map<String, dynamic> env;
    try {
      env = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw _Reject('manifest is not JSON');
    }
    final text = env['manifest'], sigB64 = env['sig'];
    if (env['format'] != 1 || text is! String || sigB64 is! String) throw _Reject('not a signed manifest');
    List<int> sig;
    try {
      sig = base64Decode(sigB64);
    } catch (_) {
      throw _Reject('bad signature encoding');
    }
    var ok = false;
    for (final key in trustedKeys) {
      if (ok || sig.length != 64) break;
      try {
        ok = nacl.VerifyKey(nacl.Uint8List.fromList(key))
            .verify(signature: nacl.Signature(nacl.Uint8List.fromList(sig)), message: nacl.Uint8List.fromList(utf8.encode(text)));
      } catch (_) {
        ok = false;
      }
    }
    if (!ok) throw _Reject('signature invalid — manifest not from the VALUNIVO release key');
    final m = jsonDecode(text) as Map<String, dynamic>;
    if (m['app'] != 'VALUNIVO' || m['platform'] != 'windows-x64' || m['channel'] != 'stable') {
      throw _Reject('manifest for another app / platform / channel');
    }
    final version = '${m['version']}', installer = '${m['installer']}', hash = '${m['sha256']}'.toLowerCase();
    final build = m['build'], size = m['size'], issued = m['issued'];
    if (build is! int || build <= 0 || size is! int || issued is! int) throw _Reject('manifest fields missing');
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) throw _Reject('bad version');
    if (!RegExp(r'^VALUNIVO-Setup-\d+\.\d+\.\d+\.exe$').hasMatch(installer)) throw _Reject('bad installer name');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) throw _Reject('bad sha256');
    if (size < 1000000 || size > 400000000) throw _Reject('implausible size');
    return UpdateManifest._(version, build, installer, size, hash, issued, m['rollback'] == true);
  }
}

class _Reject implements Exception {
  final String reason;
  _Reject(this.reason);
  @override
  String toString() => reason;
}

class _Ready {
  final UpdateManifest manifest;
  final File file;
  _Ready(this.manifest, this.file);
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

enum WinUpdateKind { idle, downloading, ready, failed }

class WinUpdateState {
  final WinUpdateKind kind;
  final String version;
  final double progress;
  const WinUpdateState.idle() : kind = WinUpdateKind.idle, version = '', progress = 0;
  const WinUpdateState.failed() : kind = WinUpdateKind.failed, version = '', progress = 0;
  const WinUpdateState.downloading(this.version, this.progress) : kind = WinUpdateKind.downloading;
  const WinUpdateState.ready(this.version) : kind = WinUpdateKind.ready, progress = 1;
}

/// Small status chip (bottom corner) while an update downloads / waits — Windows only, otherwise just [child].
class WindowsUpdateOverlay extends StatelessWidget {
  final Widget child;
  const WindowsUpdateOverlay({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!PlatformInfo.isWindows) return child;
    final u = WindowsUpdater.instance;
    return Stack(children: [
      child,
      PositionedDirectional(
        bottom: 14,
        start: 14,
        child: ValueListenableBuilder<WinUpdateState>(
          valueListenable: u.state,
          builder: (context, s, _) {
            if (s.kind != WinUpdateKind.downloading && s.kind != WinUpdateKind.ready) return const SizedBox.shrink();
            final dark = Theme.of(context).brightness == Brightness.dark;
            final ready = s.kind == WinUpdateKind.ready;
            return Material(
              color: (dark ? const Color(0xFF1B1B1A) : Colors.white).withValues(alpha: 0.88),
              elevation: 6,
              shadowColor: Colors.black26,
              shape: StadiumBorder(side: BorderSide(color: AppColors.primary.withValues(alpha: 0.45))),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: ready ? u.askRestart : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (ready)
                      const Icon(Icons.restart_alt_rounded, size: 18, color: Color(0xFFE8551C))
                    else
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2.4, value: s.progress > 0 ? s.progress : null,
                            color: AppColors.primary),
                      ),
                    const SizedBox(width: 8),
                    Text(
                      ready ? 'تحديث ${s.version} جاهز — أعد التشغيل' : 'تنزيل التحديث ${(s.progress * 100).round()}%',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: dark ? Colors.white : const Color(0xFF1B1B1A)),
                    ),
                  ]),
                ),
              ),
            );
          },
        ),
      ),
    ]);
  }
}
