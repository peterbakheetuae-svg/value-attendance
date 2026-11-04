// Run once after `flutter create --platforms=android,web .`:
//   dart run tool/patch_android.dart
// Adds the Android permissions the app needs and the app label. Idempotent.
import 'dart:io';

void main() {
  final f = File('android/app/src/main/AndroidManifest.xml');
  if (!f.existsSync()) {
    stderr.writeln('android/ not found — run: flutter create --platforms=android,web --org com.jph.realestatehr .');
    exit(1);
  }
  var xml = f.readAsStringSync();
  const perms = [
    'android.permission.INTERNET',
    'android.permission.ACCESS_FINE_LOCATION',
    'android.permission.ACCESS_COARSE_LOCATION',
    'android.permission.CAMERA',
    // in-shift location follow-up (foreground service with a visible notification)
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_LOCATION',
    'android.permission.POST_NOTIFICATIONS',
    'android.permission.WAKE_LOCK',
  ];
  for (final p in perms) {
    if (!xml.contains('"$p"')) {
      xml = xml.replaceFirst('<application', '<uses-permission android:name="$p"/>\n    <application');
    }
  }
  // Local/LAN development API is plain http; production must use https.
  if (!xml.contains('usesCleartextTraffic')) {
    xml = xml.replaceFirst('<application', '<application\n        android:usesCleartextTraffic="true"');
  }
  xml = xml.replaceFirst(RegExp(r'android:label="[^"]*"'), 'android:label="Value Attendance"');
  f.writeAsStringSync(xml);
  stdout.writeln('AndroidManifest.xml patched: ${perms.length} permissions, label, cleartext (dev).');

  // flutter_local_notifications needs core library desugaring
  for (final path in ['android/app/build.gradle.kts', 'android/app/build.gradle']) {
    final g = File(path);
    if (!g.existsSync()) continue;
    var t = g.readAsStringSync();
    final kts = path.endsWith('.kts');
    if (!t.contains('CoreLibraryDesugaringEnabled')) {
      t = t.replaceFirst(RegExp(r'compileOptions\s*\{'),
          kts ? 'compileOptions {\n        isCoreLibraryDesugaringEnabled = true' : 'compileOptions {\n        coreLibraryDesugaringEnabled true');
    }
    if (!t.contains('desugar_jdk_libs')) {
      final dep = kts ? 'coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")' : "coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'";
      if (RegExp(r'^dependencies\s*\{', multiLine: true).hasMatch(t)) {
        t = t.replaceFirst(RegExp(r'^dependencies\s*\{', multiLine: true), 'dependencies {\n    $dep');
      } else {
        t += '\ndependencies {\n    $dep\n}\n';
      }
    }
    // app id registered in Firebase (push notifications)
    t = t.replaceFirst(RegExp(r'applicationId\s*=?\s*"[^"]*"'), kts ? 'applicationId = "com.jph.valueattendance"' : 'applicationId "com.jph.valueattendance"');
    g.writeAsStringSync(t);
    stdout.writeln('$path patched: core library desugaring, applicationId.');
  }

  // sound used by system notifications (RawResourceAndroidNotificationSound('notification'))
  final snd = File('assets/sounds/notification.WAV');
  if (snd.existsSync()) {
    Directory('android/app/src/main/res/raw').createSync(recursive: true);
    snd.copySync('android/app/src/main/res/raw/notification.wav');
    stdout.writeln('notification sound copied to res/raw.');
  }

  final web = File('web/index.html');
  if (web.existsSync()) {
    var h = web.readAsStringSync();
    h = h.replaceFirst(RegExp(r'<title>[^<]*</title>'), '<title>Value Attendance</title>');
    if (!h.contains('dir="rtl"')) h = h.replaceFirst('<html>', '<html lang="ar" dir="rtl">');
    web.writeAsStringSync(h);
    stdout.writeln('web/index.html patched: title, lang, dir.');
  }
}
